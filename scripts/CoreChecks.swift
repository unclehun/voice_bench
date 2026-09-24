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
print("PASS: \(checks) core checks. These are logic tests, not device/ASR accuracy tests.")
