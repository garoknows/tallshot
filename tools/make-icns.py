#!/usr/bin/env python3
"""Packs an .iconset folder of PNGs into an .icns file (used when iconutil is unavailable)."""
import os
import struct
import sys

src, out = sys.argv[1], sys.argv[2]
types = [("icp4", "icon_16x16.png"), ("icp5", "icon_32x32.png"), ("ic07", "icon_128x128.png"),
         ("ic08", "icon_256x256.png"), ("ic09", "icon_512x512.png"), ("ic10", "icon_512x512@2x.png"),
         ("ic11", "icon_16x16@2x.png"), ("ic12", "icon_32x32@2x.png"), ("ic13", "icon_128x128@2x.png"),
         ("ic14", "icon_256x256@2x.png")]
body = b""
for t, name in types:
    with open(os.path.join(src, name), "rb") as f:
        data = f.read()
    body += t.encode() + struct.pack(">I", len(data) + 8) + data
with open(out, "wb") as f:
    f.write(b"icns" + struct.pack(">I", len(body) + 8) + body)
print("wrote", out, len(body) + 8, "bytes")
