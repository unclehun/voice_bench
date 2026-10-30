import Foundation

/// Normalize native recognizer language labels, without running language detection.
public enum LanguageCode {
    public static func normalized(_ code: String?) -> String? {
        guard let value = code?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              (2...3).contains(value.count), value.utf8.allSatisfy({ (97...122).contains($0) }) else { return nil }
        return value == "und" || value == "unk" ? nil : value
    }
}
