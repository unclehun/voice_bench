#!/usr/bin/env python3
"""Generate a simple code-drawn waveform icon; no imaging dependencies."""
import json
from pathlib import Path
import struct
import zlib

root = Path(__file__).resolve().parents[1] / "VoiceBench/Assets.xcassets"
folder = root / "AppIcon.appiconset"
folder.mkdir(parents=True, exist_ok=True)
(root / "Contents.json").write_text(json.dumps({"info": {"author": "xcode", "version": 1}}))
(folder / "Contents.json").write_text(json.dumps({"images": [{"filename": "AppIcon.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"}], "info": {"author": "xcode", "version": 1}}, indent=2))
size = 1024
bars = [(282, 355, 42), (397, 245, 42), (512, 170, 42), (627, 295, 42), (742, 385, 42)]
data = bytearray()
for y in range(size):
    data.append(0)
    for x in range(size):
        white = False
        for center, top, radius in bars:
            middle = min(max(y, top + radius), size - top - radius)
            if (x - center) ** 2 + (y - middle) ** 2 <= radius ** 2:
                white = True
                break
        data.extend((255, 255, 255) if white else (26, 80, 155))


def chunk(kind, payload):
    return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", zlib.crc32(kind + payload) & 0xffffffff)


png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0))
png += chunk(b"IDAT", zlib.compress(data, 9)) + chunk(b"IEND", b"")
(folder / "AppIcon.png").write_bytes(png)
print(folder / "AppIcon.png")
