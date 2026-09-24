#!/usr/bin/env python3
"""Package the complete device .app, preserving permissions and embedded Swift libraries."""
import plistlib
from pathlib import Path
import subprocess
import sys
import tempfile
import shutil

app = Path(sys.argv[1]).resolve()
output = Path(sys.argv[2]).resolve()
with (app / "Info.plist").open("rb") as stream:
    info = plistlib.load(stream)
assert info["CFBundleSupportedPlatforms"] == ["iPhoneOS"], "Refusing simulator app"
assert info["MinimumOSVersion"] == "26.0", "Unexpected deployment target"
assert (app / info["CFBundleExecutable"]).is_file(), "Missing executable"
output.parent.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory() as temp:
    payload = Path(temp) / "Payload"
    payload.mkdir()
    shutil.copytree(app, payload / app.name, symlinks=True)
    subprocess.run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(payload), str(output)], check=True)
print(output)
