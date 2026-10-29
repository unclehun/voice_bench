VoiceBench iPhone evaluation, 2026-10-29

report/report.html: full offline comparison, model filter, 40 original outputs and normalized character diffs.
report/report.pdf: 14-page Chinese report with overall ranking, methods, failure/correction analysis and ten cases.
report/report.md: full text report including all original outputs.
report/per-recording-metrics.csv: 40 rows. CER/WER/MER rates are fractions (0.058 = 5.8%). Failure is an empty transcript in end-to-end metrics; timing is absent for failure.
data/acquisition.json: read-only USB acquisition manifest; hashes refer to the raw JSON bytes.
data/references.json: exact user-provided reference text; title, body and source notes were confirmed spoken.
data/raw/: original recording metadata; no audio or API-key settings were collected.
data/analysis.json: full scores, primary run selection, history and correction data.
data/analyze.py: reproduce scoring offline with Python 3 (standard library only). Run from any directory: python3 data/analyze.py
                 Writes scores to data/ and verifies the source hashes against acquisition.json.
data/VerifyMetrics.swift: independent verification against the project's VoiceBenchCore Evaluation.cer.
data/create_report.py: report source (requires ReportLab, project layout and macOS Arial Unicode font).

App read at acquisition: 0.5.3 build 11; recorded ASR run versions include 0.4.1 build 10 and 0.5.3 build 11.
No phone data was modified. No model was rerun and no remote inference request was made.
No runtime App source code was changed during this analysis.
