import Foundation

public struct CER: Codable, Equatable, Sendable {
    public var substitutions: Int
    public var deletions: Int
    public var insertions: Int
    public var referenceCount: Int
    public var hypothesisCount: Int
    public var rate: Double? {
        referenceCount > 0 ? Double(substitutions + deletions + insertions) / Double(referenceCount) : nil
    }
}

public enum Evaluation {
    public static let normalizationVersion = "unicode-scalars-punctuation-whitespace-latin-case-v1"
    public static func normalize(_ text: String) -> [Unicode.Scalar] {
        let ignored = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        // Fold ASCII Latin only. Preserve digits, traditional/simplified forms and symbols.
        return text.unicodeScalars.filter { !ignored.contains($0) }.map { scalar in
            (65...90).contains(scalar.value) ? Unicode.Scalar(scalar.value + 32)! : scalar
        }
    }
    public static func cer(reference: String, hypothesis: String) -> CER {
        let a = normalize(reference), b = normalize(hypothesis)
        struct Cell {
            var s = 0, d = 0, i = 0
            var cost: Int { s + d + i }
        }
        // O(hypothesis length) memory, deterministic tie-breaking (substitute/delete/insert).
        var previous = (0...b.count).map { Cell(i: $0) }
        for (row, char) in a.enumerated() {
            var current = [Cell](repeating: Cell(), count: b.count + 1)
            current[0] = Cell(d: row + 1)
            for (column, other) in b.enumerated() {
                if char == other { current[column + 1] = previous[column]; continue }
                var substitute = previous[column]; substitute.s += 1
                var delete = previous[column + 1]; delete.d += 1
                var insert = current[column]; insert.i += 1
                var best = substitute
                if delete.cost < best.cost { best = delete }
                if insert.cost < best.cost { best = insert }
                current[column + 1] = best
            }
            previous = current
        }
        let last = previous[b.count]
        return CER(substitutions: last.s, deletions: last.d, insertions: last.i,
                   referenceCount: a.count, hypothesisCount: b.count)
    }
    public static func chunks(_ text: String, size: Int = 400) -> [String] {
        guard size > 0 else { return [] }
        let chars = Array(text)
        return stride(from: 0, to: chars.count, by: size).map { String(chars[$0..<min($0 + size, chars.count)]) }
    }
    /// Conservative gate: every changed chunk containing sensitive facts needs manual review.
    public static func correctionCanApply(original: String, proposed: String) -> Bool {
        if original == proposed { return true }
        guard !proposed.isEmpty, proposed.count <= max(original.count * 2, original.count + 20) else { return false }
        let risky = CharacterSet(charactersIn: "0123456789零〇一二三四五六七八九十百千万亿两不没未无非别勿父母爸妈哥姐弟妹夫妻年月日岁元百分")
        if (original + proposed).unicodeScalars.contains(where: { risky.contains($0) }) { return false }
        let metric = cer(reference: original, hypothesis: proposed)
        return (metric.rate ?? 0) <= 0.25
    }
}
