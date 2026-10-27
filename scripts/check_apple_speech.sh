#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/check_local.sh
swiftc -parse-as-library -module-cache-path .build-local/module-cache \
  -I .build-local -L .build-local -lVoiceBenchCore \
  -Xlinker -rpath -Xlinker "$PWD/.build-local" \
  VoiceBench/Audio/AudioFiles.swift VoiceBench/Audio/PCMFileReader.swift \
  VoiceBench/Engines/AppleSpeechDiagnostics.swift scripts/AppleSpeechChecks.swift \
  -o .build-local/apple-speech-checks
.build-local/apple-speech-checks
