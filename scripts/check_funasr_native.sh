#!/bin/bash
# Optional macOS inference audit. Does not download dependencies or change iOS linking.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $# -lt 3 || $# -gt 4 ]]; then
  echo 'Usage: bash scripts/check_funasr_native.sh MODEL_FOLDER AUDIO_FILE REPORT_FILE [--require-retry]' >&2
  exit 2
fi
framework_dir="${FUNASR_MAC_FRAMEWORK_DIR:-$PWD/.build-local/macos-frameworks/sherpa-onnx.xcframework/macos-arm64_x86_64}"
runtime_dir="${FUNASR_MAC_ORT_DIR:-$PWD/.build-local/funasr-audit-python/sherpa_onnx/lib}"
if [[ ! -d "$framework_dir/SherpaOnnxC.framework" || ! -f "$runtime_dir/libonnxruntime.dylib" ]]; then
  echo 'Prepare matching sherpa-onnx 1.13.8 / ONNX Runtime 1.28.2 macOS libraries; see docs/FUNASR_MLT.md.' >&2
  exit 2
fi
bash scripts/check_local.sh
swiftc -parse-as-library -strict-concurrency=targeted \
  -module-cache-path .build-local/module-cache \
  -I .build-local -L .build-local -lVoiceBenchCore \
  -Xlinker -rpath -Xlinker "$PWD/.build-local" \
  -F "$framework_dir" -L "$runtime_dir" \
  -Xlinker -rpath -Xlinker "$runtime_dir" \
  VoiceBench/Audio/AudioFiles.swift VoiceBench/Storage/AppTemporaryFiles.swift \
  VoiceBench/Engines/SenseVoiceEngine.swift VoiceBench/Engines/FunASRAudioReader.swift \
  VoiceBench/Engines/FunASRSpeechEngine.swift scripts/FunASRSmoke.swift \
  -framework SherpaOnnxC -lonnxruntime -framework Accelerate -lc++ \
  -o .build-local/funasr-smoke
.build-local/funasr-smoke "$@"
