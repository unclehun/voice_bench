import Foundation
import VoiceBenchCore

var checks = 0
func check(_ value: @autoclosure () -> Bool, _ name: String) {
    checks += 1
    if !value() { fputs("FAIL: \(name)\n", stderr); exit(1) }
}
let errors = Evaluation.cer(reference: "你好世界", hypothesis: "你号世")
check(errors.substitutions == 1 && errors.deletions == 1 && errors.insertions == 0, "edit types")
check(errors.rate == 0.5, "CER ratio")
check(Evaluation.cer(reference: "你好，ABC！", hypothesis: "你 好 abc").rate == 0, "punctuation and Latin case")
check(Evaluation.cer(reference: "台湾", hypothesis: "臺灣").rate != 0, "preserve traditional forms")
check(Evaluation.cer(reference: "一百", hypothesis: "100").rate != 0, "preserve number formats")
check(Evaluation.cer(reference: "", hypothesis: "你好").rate == nil, "empty reference")
check(Evaluation.cer(reference: "，", hypothesis: "你").insertions == 1, "punctuation-only reference")
check(Evaluation.cer(reference: "你好", hypothesis: "").rate == 1, "silent hypothesis")
check(Evaluation.cer(reference: "🙂", hypothesis: "🙂").referenceCount == 1, "Unicode scalars")
check(Evaluation.cer(reference: "你", hypothesis: "你好啊").rate == 2, "CER may exceed 100 percent")
let long = String(repeating: "你好🙂。", count: 400)
let chunks = Evaluation.chunks(long, size: 19)
check(chunks.joined() == long && chunks.allSatisfy { $0.count <= 19 }, "chunk coverage")
check(!Evaluation.correctionCanApply(original: "不是十月", proposed: "是十一月"), "protect negation and numbers")
check(!Evaluation.correctionCanApply(original: "你好", proposed: ""), "reject empty correction")
check(Evaluation.correctionCanApply(original: "你好世界", proposed: "你好，世界。"), "allow punctuation")
var recording = Recording(name: "测试", fileName: "test.wav", sha256: "not-a-real-audio-hash", duration: 10, sampleRate: 16000, channels: 1)
recording.reference = "你好"
var run = Run(engine: .apple)
run.rawText = "你"
run.correction.status = "running"
recording.runs = [run]
recording.recoverInterruptedRuns()
check(recording.runs[0].status == .interrupted, "interrupted ASR recovery")
check(recording.runs[0].correction.status == "interrupted", "interrupted correction recovery")
var report = Report(recording: recording, environment: ["test": "synthetic fixture, not an ASR result"])
check(report.evaluation[0].rawCER == nil && report.evaluation[0].rtf == nil, "exclude incomplete metrics")
recording.runs[0].status = .completed
recording.runs[0].transcriptionMS = 2000
report = Report(recording: recording, environment: ["test": "synthetic fixture, not an ASR result"])
check(report.evaluation[0].rtf == 0.2, "RTF")
check(report.evaluation[0].rawCER?.rate == 0.5, "report CER")
check(report.evaluation[0].correctedCER == nil, "unavailable correction is not a copy")
let data = try report.json()
let jsonObject = try JSONSerialization.jsonObject(with: data)
check(jsonObject is [String: Any], "JSON export parses")
if CommandLine.arguments.count > 1 { try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1])) }
check(report.markdown().contains("0.5000"), "Markdown report")
let flag = CancellationFlag()
try flag.check(); flag.cancel()
do { try flag.check(); check(false, "cancel should throw") } catch is CancellationError { check(true, "cancellation") }

// Exhaustive short-string cross-check against an independent full-matrix edit distance.
func distance(_ a: [Character], _ b: [Character]) -> Int {
    var matrix = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
    for i in 0...a.count { matrix[i][0] = i }
    for j in 0...b.count { matrix[0][j] = j }
    if !a.isEmpty && !b.isEmpty {
        for i in 1...a.count { for j in 1...b.count {
            matrix[i][j] = min(matrix[i-1][j] + 1, matrix[i][j-1] + 1, matrix[i-1][j-1] + (a[i-1] == b[j-1] ? 0 : 1))
        } }
    }
    return matrix[a.count][b.count]
}
var inputs = [""]
for length in 1...5 {
    for mask in 0..<(1 << length) { inputs.append(String((0..<length).map { (mask & (1 << $0)) == 0 ? Character("你") : Character("好") })) }
}
for a in inputs { for b in inputs {
    let result = Evaluation.cer(reference: a, hypothesis: b)
    check(result.substitutions + result.deletions + result.insertions == distance(Array(a), Array(b)), "distance cross-check")
    let diff = TextDiff.edits(from: a, to: b)
    check(diff.filter { $0.kind != .added }.map(\.text).joined() == a, "diff reconstructs original")
    check(diff.filter { $0.kind != .removed }.map(\.text).joined() == b, "diff reconstructs revision")
} }
// Routing fixtures describe labels, not measured ASR/language-ID accuracy.
func span(_ lo: Double, _ hi: Double, _ languages: [(Double, Double, String?)]) -> DetectedSpeechSpan {
    DetectedSpeechSpan(startSeconds: lo, endSeconds: hi, windows: languages.map {
        LanguageWindow(startSeconds: $0.0, endSeconds: $0.1, language: $0.2)
    })
}
let english = span(0, 8, [(0, 5, "en"), (5, 8, "en")])
let chinese = span(9, 12, [(9, 12, "zh")])
let alternating = LanguageDetection(preparationMS: 12, detectionMS: 34, durationSeconds: 20,
                                   spans: [english, chinese, span(14, 19, [(14, 19, "en")])])
check(alternating.languages == ["en", "zh"] && alternating.regions.count == 3, "detect later language changes, not just the start")
check(alternating.regions.map(\.language) == ["en", "zh", "en"], "routing order")
check(alternating.regions[0].startSeconds == 0 && alternating.regions.last!.endSeconds <= 20, "padding clamps to audio")
for (a, b) in zip(alternating.regions, alternating.regions.dropFirst()) {
    check(a.endSeconds <= b.startSeconds, "regions must not duplicate audio")
}
let mixed = LanguageRouting.regions(spans: [span(0, 10, [(0, 5, "en"), (5, 10, "zh")])], duration: 10)
check(mixed.count == 1 && mixed[0].decision == "mixed_dominant" && mixed[0].language == "en", "do not pretend window votes are word-level alignment")
let contextualTie = LanguageRouting.regions(spans: [chinese, span(14, 24, [(14, 19, "en"), (19, 24, "zh")])], duration: 24)
check(contextualTie.last?.language == "zh", "tie prefers preceding language")
let immediateSwitch = LanguageRouting.regions(spans: [span(0, 5, [(0, 5, "en")]), span(5, 10, [(5, 10, "zh")])], duration: 10)
check(immediateSwitch.count == 2 && immediateSwitch[0].endSeconds == 5 && immediateSwitch[1].startSeconds == 5,
      "padding must not assign the next language's opening syllable to the previous region")
let same = LanguageRouting.regions(spans: [english, span(9, 12, [(9, 12, "en")])], duration: 12)
check(same.count == 1 && same[0].endSeconds == 12, "merge nearby same-language spans")
let longRegions = LanguageRouting.regions(spans: [span(0, 100, [(0, 100, "en")]), span(101, 150, [(101, 150, "en")])], duration: 150)
check(longRegions.count == 2, "bound merged Apple sessions")
let unknown = LanguageRouting.regions(spans: [span(0, 1, [(0, 1, nil)])], duration: 1)
check(unknown[0].language == nil && unknown[0].decision == "undetermined", "unknown must not force Chinese")
let outside = LanguageRouting.regions(spans: [span(0, 1, [(2, 3, "en")])], duration: 1)
check(outside[0].language == nil, "non-overlapping vote is not language evidence")
check(LanguageRouting.regions(spans: [], duration: 10).isEmpty, "silence has no forced language")
check(LanguageRouting.regions(spans: [english], duration: .infinity).isEmpty, "reject nonfinite audio duration")
check(LanguageRouting.normalized(" EN ") == "en" && LanguageRouting.normalized("und") == nil, "normalize model labels")
let short = LanguageRouting.regions(spans: [span(0, 0.3, [(0, 0.3, "en")])], duration: 1)
check(short[0].decision == "short_input", "flag unreliable short utterance")
let decodedPlan = try JSONDecoder().decode(LanguageDetection.self, from: JSONEncoder().encode(alternating))
check(decodedPlan.regions.count == 3 && decodedPlan.spans.count == 3, "language window and route export round-trip")
var languageRun = Run(engine: .apple); languageRun.languageDetection = alternating
languageRun.segments = [Segment(id: 0, startSeconds: 0, endSeconds: 8, text: "synthetic", language: "en")]
recording.runs = [languageRun]
let languageReport = Report(recording: recording, environment: [:])
check(languageReport.markdown().contains("mixed") == false && languageReport.markdown().contains("whisper-tiny"), "Markdown reports detector")
var oldRun = try JSONSerialization.jsonObject(with: JSONEncoder().encode(languageRun)) as! [String: Any]
oldRun.removeValue(forKey: "languageDetection")
var oldSegments = oldRun["segments"] as! [[String: Any]]; oldSegments[0].removeValue(forKey: "language"); oldRun["segments"] = oldSegments
let backward = try JSONDecoder().decode(Run.self, from: JSONSerialization.data(withJSONObject: oldRun))
check(backward.languageDetection == nil && backward.segments[0].language == nil, "old installed recordings still decode")
// A card presents one comparison; queueing a second comparison cannot recycle old text/correction.
var card = Recording(name: "card fixture", fileName: "fixture.wav", sha256: "fixture", duration: 5, sampleRate: 16000, channels: 1)
var previousSense = Run(engine: .senseVoice); previousSense.status = .completed; previousSense.rawText = "旧结果"
var previousApple = Run(engine: .apple); previousApple.status = .completed; previousApple.rawText = "old result"
previousApple.correction.status = "completed"; previousApple.correction.text = "old corrected"
card.runs = [previousSense, previousApple]
check(card.latestComparisonRuns.count == 2 && card.hasCorrectionResults, "legacy card finds both engine results")
let comparisonID = UUID()
var nextSense = Run(engine: .senseVoice); nextSense.batchID = comparisonID
var nextApple = Run(engine: .apple); nextApple.batchID = comparisonID
card.runs += [nextSense, nextApple]
check(card.latestComparisonRuns.map(\.id) == [nextSense.id, nextApple.id], "new card uses one queued comparison")
check(!card.hasCorrectionResults && card.correctionCandidates.isEmpty, "new comparison hides old corrections and cannot correct pending text")
nextSense.status = .completed; nextSense.rawText = "新结果"
nextApple.status = .failed; nextApple.error = "fixture failure"
card.runs = [previousSense, previousApple, nextSense, nextApple]
check(card.correctionCandidates.map(\.id) == [nextSense.id], "correct only completed text in current comparison")
nextSense.correction.status = "running"; nextSense.correction.text = "partial fixture"
card.runs[2] = nextSense
check(!card.hasCorrectionResults, "running correction cannot show a finished-result triangle")
nextSense.correction.status = "partial"; card.runs[2] = nextSense
check(card.hasCorrectionResults, "completed partial correction can be inspected")
nextSense.correction.status = "failed"; nextSense.correction.text = nil; card.runs[2] = nextSense
check(!card.hasCorrectionResults, "failed correction does not fabricate a result")
let restoredCard = try JSONDecoder().decode(Recording.self, from: JSONEncoder().encode(card))
check(restoredCard.latestComparisonRuns.map(\.id) == [nextSense.id, nextApple.id], "comparison membership persists across restart")
var legacyObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(previousSense)) as! [String: Any]
legacyObject.removeValue(forKey: "batchID")
let legacyRun = try JSONDecoder().decode(Run.self, from: JSONSerialization.data(withJSONObject: legacyObject))
check(legacyRun.batchID == nil, "recordings predating card UI remain readable")
var qwenRun = Run(engine: .qwen); qwenRun.batchID = comparisonID
qwenRun.status = .completed; qwenRun.rawText = "混合 English 文字"
card.runs.append(qwenRun)
check(card.latestComparisonRuns.map(\.id) == [nextSense.id, nextApple.id, qwenRun.id], "third engine joins the current batch")
check(card.correctionCandidates.map(\.id) == [nextSense.id, qwenRun.id], "three-engine corrections exclude failed Apple result")
let threeEngineCard = try JSONDecoder().decode(Recording.self, from: JSONEncoder().encode(card))
check(threeEngineCard.runs.last?.engine == .qwen && threeEngineCard.runs.last?.modelVersion == QwenASRModel.version, "Qwen result persists with pinned identity")
check(qwenRun.languageDetection == nil, "Qwen does not acquire a Whisper language plan")
check(Report(recording: card, environment: [:]).markdown().contains("Qwen3-ASR"), "third model included in report")
check(Run(engine: .senseVoice).modelVersion == previousSense.modelVersion && Run(engine: .apple).modelVersion == previousApple.modelVersion, "existing model versions remain unchanged")
var newerApple = Run(engine: .apple); newerApple.batchID = UUID(); card.runs.append(newerApple)
check(card.latestComparisonRuns.map(\.id) == [newerApple.id], "single-engine debug does not mix in an old Qwen result")
print("PASS: \(checks) core checks. These are logic tests, not device/ASR accuracy tests.")
