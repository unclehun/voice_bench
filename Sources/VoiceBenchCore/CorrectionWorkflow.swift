import Foundation

public enum CorrectionWorkflow {
    public struct Unit: Sendable {
        public let offset: Int
        public let text: String
    }

    /// Sentence boundaries are preferred; concatenating the targets always reproduces the source exactly.
    public static func units(_ text: String, limit: Int = 220) -> [Unit] {
        guard limit > 0 else { return [] }
        let chars = Array(text), breaks = Set<Character>("。！？.!?；;\n ")
        var start = 0, result: [Unit] = []
        while start < chars.count {
            var end = min(start + limit, chars.count)
            if end < chars.count, let boundary = (start..<end).last(where: { breaks.contains(chars[$0]) }), boundary >= start + limit/3 {
                end = boundary + 1
            }
            result.append(Unit(offset: start, text: String(chars[start..<end])))
            start = end
        }
        return result
    }

    public static func run(original: String, context: String, initial: Correction, documentLimit: Int,
                           cancellation: CancellationFlag,
                           respond: @escaping @Sendable (SemanticCorrection.Input) async throws -> SemanticCorrection.Response,
                           message: @escaping @Sendable (Error) -> String,
                           stopAfterError: @escaping @Sendable (Error) -> Bool,
                           progress: @escaping @Sendable (Correction) async -> Void) async -> Correction {
        var output = initial
        output.context = context; output.policyVersion = SemanticCorrection.policyVersion
        guard !original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            output.status = "skipped_empty"; return output
        }
        guard context.count <= 1000 else {
            output.status = "failed"; output.error = "背景和词条请控制在 1000 字以内。"; return output
        }
        let start = ProcessInfo.processInfo.systemUptime
        // Preserve all user background; reduce the local transcript window when it is long.
        let budget = max(240, documentLimit - context.count)
        let targets = units(original, limit: min(220, budget))
        let source = Array(original)
        output.blocks = targets.enumerated().map { index, unit in
            var block = CorrectionBlock(id: index, original: unit.text, proposed: nil, applied: unit.text, note: "")
            block.changes = []; block.state = "queued"; return block
        }
        output.status = "running"
        await progress(output)
        var warnings: [String] = [], failures = 0, contextIncomplete = false
        do {
            // For long documents, read every section before editing. Summaries are read-only context,
            // never evidence: the policy still checks each quoted source against the original transcript.
            var overview = ""
            if original.count > budget {
                output.phase = "overview"
                await progress(output)
                for (index, section) in units(original, limit: budget).enumerated() {
                    try cancellation.check(); try Task.checkCancellation()
                    let input = SemanticCorrection.Input(mode: "overview", segment_id: index, target: "",
                        document: section.text, overview: "", background: context)
                    do {
                        let response = try await respond(input)
                        try cancellation.check(); try Task.checkCancellation()
                        guard response.segment_id == index, response.edits.isEmpty, !response.has_more,
                              !response.overview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                              response.overview.count <= 200 else { throw BenchError("长文语义摘要格式不完整。") }
                        overview += "[\(index+1)]" + response.overview + "\n"
                        // Hierarchical reduction reads every note; it does not drop the middle of a document.
                        let overviewLimit = min(300, budget)
                        while overview.count > overviewLimit {
                            let notes = units(overview, limit: overviewLimit)
                            var reduced = ""
                            for note in notes {
                                let summaryInput = SemanticCorrection.Input(mode: "overview", segment_id: index, target: "",
                                    document: note.text, overview: "", background: "")
                                try cancellation.check(); try Task.checkCancellation()
                                let summary = try await respond(summaryInput)
                                try cancellation.check(); try Task.checkCancellation()
                                guard summary.segment_id == index, summary.edits.isEmpty, !summary.has_more,
                                      !summary.overview.isEmpty, summary.overview.count <= 200 else {
                                    throw BenchError("长文语义摘要压缩失败。")
                                }
                                reduced += summary.overview + "\n"
                            }
                            guard reduced.count < overview.count else { throw BenchError("长文摘要未能压缩到上下文限制。") }
                            overview = reduced
                        }
                        output.semanticOverview = overview
                        await progress(output)
                    } catch {
                        try cancellation.check(); try Task.checkCancellation()
                        if stopAfterError(error) { throw error }
                        contextIncomplete = true
                        overview = output.semanticOverview ?? ""
                        warnings.append("长文部分语义摘要未完成：" + message(error))
                    }
                }
            }
            output.phase = "correct"
            for index in targets.indices {
                try cancellation.check(); try Task.checkCancellation()
                output.blocks[index].state = "running"
                await progress(output)
                let target = targets[index]
                let extra = max(0, budget - target.text.count)
                let windowStart = max(0, min(target.offset - extra/2, source.count - budget))
                let windowEnd = min(source.count, max(windowStart + budget, target.offset + target.text.count))
                let document = String(source[windowStart..<windowEnd])
                let input = SemanticCorrection.Input(mode: "correct", segment_id: index, target: target.text,
                    document: document, overview: overview, background: context)
                do {
                    let response = try await respond(input)
                    try cancellation.check(); try Task.checkCancellation()
                    guard response.segment_id == index, response.overview.isEmpty else {
                        throw BenchError("纠错返回了错误的片段 ID 或输出模式，此片段保留原文。")
                    }
                    var suggestions = response.edits
                    if contextIncomplete {
                        for i in suggestions.indices where ["proper_name", "pronoun"].contains(suggestions[i].kind) {
                            suggestions[i].support = "ambiguous"
                        }
                    }
                    output.blocks[index] = try SemanticCorrection.block(id: index, original: target.text,
                        document: original, background: context, suggestions: suggestions)
                    if response.has_more {
                        warnings.append("片段 \(index+1) 的建议超过单次输出上限，未返回的建议未应用。")
                        output.blocks[index].note = "还有未返回的建议；未涉及的位置保留原文。"
                    }
                } catch {
                    try cancellation.check(); try Task.checkCancellation()
                    failures += 1
                    output.blocks[index].state = "failed"
                    output.blocks[index].note = message(error)
                    if stopAfterError(error) { throw error }
                }
                output.refreshText()
                output.elapsedMS = (ProcessInfo.processInfo.systemUptime - start) * 1000
                await progress(output)
            }
            output.status = output.completedBlockCount == 0 ? "failed" : failures > 0 || !warnings.isEmpty ? "partial" : "completed"
        } catch {
            if cancellation.isCancelled || Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                output.status = "cancelled"
            } else {
                output.status = output.completedBlockCount > 0 ? "partial" : "failed"
                warnings.append(message(error))
            }
            for index in output.blocks.indices where ["queued", "running"].contains(output.blocks[index].state ?? "") {
                output.blocks[index].state = "unprocessed"
                output.blocks[index].note = "处理提前结束，此片段保留原文。"
            }
        }
        if failures > 0 { warnings.append("\(failures) 个片段失败并保留原文；详情可查看具体原因。") }
        output.error = warnings.isEmpty ? nil : Array(Set(warnings)).sorted().joined(separator: " ")
        output.refreshText()
        output.phase = nil
        output.elapsedMS = (ProcessInfo.processInfo.systemUptime - start) * 1000
        return output
    }
}
