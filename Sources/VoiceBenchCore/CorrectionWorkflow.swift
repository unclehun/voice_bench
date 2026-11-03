import Foundation

/// A successful pass reads the entire immutable transcript in one model request.
/// Retries repeat that same full document; no slicing, summaries or per-segment calls exist here.
public enum CorrectionWorkflow {
    public static func run(original: String, context: String, initial: Correction,
                           cancellation: CancellationFlag,
                           respond: @escaping @Sendable (SemanticCorrection.Input) async throws -> SemanticCorrection.Response,
                           message: @escaping @Sendable (Error) -> String,
                           retryable: @escaping @Sendable (Error) -> Bool,
                           progress: @escaping @Sendable (Correction) async -> Void) async -> Correction {
        var output = initial
        output.context = context
        output.policyVersion = SemanticCorrection.policyVersion
        output.blocks = []; output.semanticOverview = nil
        output.document = CorrectionDocument(original: original)
        output.refreshText()
        guard !original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            output.status = "skipped_empty"; return output
        }
        guard context.count <= 1000 else {
            output.status = "failed"; output.error = "背景和词条请控制在 1000 字以内。"; return output
        }
        let start = ProcessInfo.processInfo.systemUptime
        let input = SemanticCorrection.Input(document: original, background: context)
        output.status = "running"
        for attempt in 1...2 {
            output.attemptCount = attempt
            output.phase = attempt == 1 ? "document" : "retrying"
            await progress(output)
            do {
                try cancellation.check(); try Task.checkCancellation()
                let response = try await respond(input)
                try cancellation.check(); try Task.checkCancellation()
                output.phase = "validating"
                await progress(output)
                let changes = try SemanticCorrection.changes(original: original, background: context, suggestions: response.edits)
                try cancellation.check(); try Task.checkCancellation()
                output.document = CorrectionDocument(original: original, changes: changes, isComplete: !response.has_more)
                output.status = response.has_more ? "partial" : "completed"
                output.error = response.has_more ? "模型未能返回全文所有建议；以下为已返回并校验的修改，其余原文保留。可重新进行全文纠错。" : nil
                output.refreshText()
                break
            } catch {
                if cancellation.isCancelled || Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                    output.status = "cancelled"
                    output.error = "全文纠错已停止，原始文字保留。"
                    break
                }
                if attempt < 2 && retryable(error) { continue }
                output.status = "failed"
                output.error = message(error)
                break
            }
        }
        output.phase = nil
        output.elapsedMS = (ProcessInfo.processInfo.systemUptime - start) * 1000
        return output
    }
}
