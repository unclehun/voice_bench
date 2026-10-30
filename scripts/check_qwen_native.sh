#!/bin/bash
# Optional macOS inference checks; uses the shared app engine and separately prepared libraries.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $# -lt 3 || $# -gt 5 ]]; then
  echo 'Usage: bash scripts/check_qwen_native.sh MODEL_FOLDER AUDIO REPORT [--weight-only4] [--check-lifecycle]' >&2
  exit 2
fi
framework_dir="${QWEN_MAC_FRAMEWORK_DIR:-$PWD/.build-local/macos-frameworks/sherpa-onnx.xcframework/macos-arm64_x86_64}"
runtime_dir="${QWEN_MAC_ORT_DIR:-$PWD/.build-local/funasr-audit-python/sherpa_onnx/lib}"
mkdir -p .build-local/module-cache
swiftc -emit-library -emit-module -module-name VoiceBenchCore \
  -module-cache-path .build-local/module-cache Sources/VoiceBenchCore/*.swift \
  -o .build-local/libVoiceBenchCore.dylib -emit-module-path .build-local/VoiceBenchCore.swiftmodule
swiftc -parse-as-library -strict-concurrency=targeted -module-cache-path .build-local/module-cache \
  -I .build-local -L .build-local -lVoiceBenchCore -Xlinker -rpath -Xlinker "$PWD/.build-local" \
  -F "$framework_dir" -L "$runtime_dir" -Xlinker -rpath -Xlinker "$runtime_dir" \
  VoiceBench/Audio/AudioFiles.swift VoiceBench/Storage/AppTemporaryFiles.swift \
  VoiceBench/Engines/SenseVoiceEngine.swift VoiceBench/Engines/QwenSpeechEngine.swift scripts/QwenSmoke.swift \
  -framework SherpaOnnxC -lonnxruntime -framework Accelerate -lc++ -o .build-local/qwen-smoke
.build-local/qwen-smoke "$@"
