import Foundation
import FoundationModels
import CryptoKit
import VoiceBenchCore

@Generable
struct SemanticProofreadEdit {
    @Guide(description: "Exact nonempty source text in target, one local problem.") var original: String
    @Guide(description: "Minimal replacement in the original language.") var replacement: String
    @Guide(description: "Exact unique excerpt of target containing original exactly once.") var anchor: String
    @Guide(description: "lexical, english_spelling, proper_name, pronoun, format, number, amount, date, time, unit, negation, relationship, rewrite, disfluency, uncertain") var kind: String
    @Guide(description: "Exact short quote from document or background supporting the suggestion.") var evidence: String
    @Guide(description: "transcript or background") var evidence_source: String
    @Guide(description: "clear, ambiguous, or knowledge_only") var support: String
    @Guide(description: "One short Chinese sentence explaining the contextual evidence.") var reason: String
}

@Generable
struct SemanticProofreadResponse {
    @Guide(description: "Copy input segment_id exactly.") var segment_id: Int
    @Guide(description: "Overview mode: at most 120 Chinese characters of context notes. Correct mode: empty string.") var overview: String
    @Guide(description: "Independent local edits; empty in overview mode or when no reliable edits exist.", .maximumCount(8))
    var edits: [SemanticProofreadEdit]
    @Guide(description: "True only if more corrections remain beyond the eight-edit limit.") var has_more: Bool
}

actor AppleTextCorrector {
    static let instructions = SemanticCorrection.instructions

    func availability() -> String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            guard SystemLanguageModel.default.supportsLocale(Locale(identifier: "zh-CN")) else { return "系统文字模型不支持中文。" }
            return nil
        case .unavailable(let reason): return String(describing: reason)
        }
    }

    /// No reference transcript or other engine's output is accepted by this interface.
    func correct(original: String, context: String, cancellation: CancellationFlag,
                 progress: @escaping @Sendable (Correction) async -> Void) async -> Correction {
        var initial = Correction()
        initial.context = context
        initial.model = "Apple Foundation Models/system-managed"
        initial.promptVersion = SemanticCorrection.promptVersion
        initial.policyVersion = SemanticCorrection.policyVersion
        initial.promptHash = SHA256.hash(data: Data(Self.instructions.utf8)).map { String(format: "%02x", $0) }.joined()
        if original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { initial.status = "skipped_empty"; return initial }
        if let reason = availability() { initial.status = "skipped_unavailable"; initial.error = reason; return initial }
        return await CorrectionWorkflow.run(original: original, context: context, initial: initial,
            documentLimit: 900, cancellation: cancellation,
            respond: { input in try await self.respond(input) },
            message: { error in
                if let error = error as? BenchError { return error.message }
                return "Apple 文字模型未完成此片段：\(error.localizedDescription)"
            }, stopAfterError: { _ in false }, progress: progress)
    }

    private func respond(_ input: SemanticCorrection.Input) async throws -> SemanticCorrection.Response {
        // Fresh sessions avoid retaining prior edits as evidence and bound the 4096-token context.
        let session = LanguageModelSession(model: SystemLanguageModel.default, instructions: Self.instructions)
        let response = try await session.respond(to: input.json(), generating: SemanticProofreadResponse.self,
                                                options: GenerationOptions(sampling: .greedy))
        let result = response.content
        let edits = result.edits.map { item in
            CorrectionProposal(original: item.original, replacement: item.replacement, anchor: item.anchor, kind: item.kind,
                evidence: item.evidence, evidenceSource: item.evidence_source, support: item.support, reason: item.reason)
        }
        return SemanticCorrection.Response(segmentID: result.segment_id, overview: result.overview, edits: edits, hasMore: result.has_more)
    }
}
