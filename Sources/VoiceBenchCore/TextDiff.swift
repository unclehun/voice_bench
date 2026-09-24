import Foundation

public struct TextEdit: Equatable, Sendable {
    public enum Kind: String, Sendable { case unchanged, removed, added }
    public var kind: Kind
    public var text: String
}

public enum TextDiff {
    /// Character-level display diff. Inputs are correction chunks, not entire long recordings.
    public static func edits(from original: String, to revised: String) -> [TextEdit] {
        let old = Array(original), new = Array(revised)
        let difference = new.difference(from: old)
        var removed = Set<Int>(), added = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): added.insert(offset)
            }
        }
        var output: [TextEdit] = []
        func append(_ kind: TextEdit.Kind, _ character: Character) {
            if output.last?.kind == kind { output[output.count - 1].text.append(character) }
            else { output.append(TextEdit(kind: kind, text: String(character))) }
        }
        var i = 0, j = 0
        while i < old.count || j < new.count {
            if i < old.count, removed.contains(i) { append(.removed, old[i]); i += 1 }
            else if j < new.count, added.contains(j) { append(.added, new[j]); j += 1 }
            else if i < old.count, j < new.count { append(.unchanged, old[i]); i += 1; j += 1 }
            else if i < old.count { append(.removed, old[i]); i += 1 }
            else { append(.added, new[j]); j += 1 }
        }
        return output
    }
}
