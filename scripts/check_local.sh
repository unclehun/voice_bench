#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build-local/module-cache
swiftc -emit-library -emit-module -module-name VoiceBenchCore \
  -module-cache-path .build-local/module-cache Sources/VoiceBenchCore/*.swift \
  -o .build-local/libVoiceBenchCore.dylib -emit-module-path .build-local/VoiceBenchCore.swiftmodule
swiftc -module-cache-path .build-local/module-cache -I .build-local -L .build-local \
  -lVoiceBenchCore -Xlinker -rpath -Xlinker "$PWD/.build-local" \
  scripts/CoreChecks.swift -o .build-local/core-checks
.build-local/core-checks
python3 scripts/check_project.py
