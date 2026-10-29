import Foundation

/// Apple requires a locale even when the complete recording is submitted without external language detection.
public struct AppleSpeechSettings: Equatable, Sendable {
    public static let defaultLocaleIdentifier = "zh-CN"
    public var localeIdentifier: String

    public init() { localeIdentifier = Self.defaultLocaleIdentifier }

    public init(localeIdentifier: String) throws {
        let identifier = localeIdentifier.replacingOccurrences(of: "_", with: "-")
        guard identifier.range(of: #"\A[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8})*\z"#, options: .regularExpression) != nil else {
            throw BenchError("请选择有效的 Apple Speech 默认语言。")
        }
        self.localeIdentifier = identifier
    }

    public static func displayName(_ identifier: String) -> String {
        Locale(identifier: "zh-CN").localizedString(forIdentifier: identifier) ?? identifier
    }

    public var runConfiguration: [String: String] {
        ["requested_locale": localeIdentifier,
         "apple_language_strategy": "configured_locale_full_recording_v1",
         "apple_input_pipeline": "pcm_full_recording_v3",
         "apple_external_language_detection": "false",
         "apple_audio_scope": "full_recording",
         "offline": "true"]
    }
}
