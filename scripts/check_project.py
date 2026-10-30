#!/usr/bin/env python3
"""Static checks only. Does not pretend to compile or run an iOS app."""
import ast
import json
import plistlib
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[1]
for path in root.glob("scripts/*.py"):
    ast.parse(path.read_text(), filename=str(path))
for path in root.glob("scripts/*.sh"):
    subprocess.run(["bash", "-n", str(path)], check=True)
for path in root.glob("VoiceBench/**/*.plist"):
    with path.open("rb") as stream:
        plistlib.load(stream)
for path in [*root.glob("config/*.json"), *root.glob("VoiceBench/**/*.json")]:
    json.loads(path.read_text())
spec = (root / "project.yml").read_text()
assert 'IPHONEOS_DEPLOYMENT_TARGET: "26.0"' in spec
assert "AppleLegacyEngine" not in spec
assert "FoundationModels.framework" in spec
assert "Speech.framework" in spec
assert "workflow_dispatch:" in (root / ".github/workflows/ios.yml").read_text()
assert "NSSpeechRecognitionUsageDescription" not in (root / "VoiceBench/Info.plist").read_text(), "Only on-device SpeechTranscriber is used"
info = (root / "VoiceBench/Info.plist").read_text()
assert "<key>UIFileSharingEnabled</key><true/>" in info
assert "<key>LSSupportsOpeningDocumentsInPlace</key><true/>" in info
qwen4_manifest = root / "config/qwen-weight-only-model-manifest.json"
qwen4_files = json.loads(qwen4_manifest.read_text())
qwen_files = json.loads((root / "config/qwen-model-manifest.json").read_text())
assert set(qwen4_files) == (set(qwen_files) - {"decoder.int8.onnx"}) | {"decoder.weight4.onnx"}
assert all(qwen4_files[name] == digest for name, digest in qwen_files.items() if name != "decoder.int8.onnx")
assert "config/qwen-weight-only-model-manifest.json" in spec
assert "qwen-weight-only-model-manifest.json in Resources" in (root / "VoiceBench.xcodeproj/project.pbxproj").read_text(), "4-bit model checksum manifest must be bundled in the app"
print("PASS: scripts, plists, JSON and deployment invariants. iOS SDK compilation still required.")
