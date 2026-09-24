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
print("PASS: scripts, plists, JSON and deployment invariants. iOS SDK compilation still required.")
