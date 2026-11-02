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
}
