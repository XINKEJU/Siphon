#!/usr/bin/env python3
"""Generate deterministic fixtures for the Stage 2 tests (packages + zip)."""
import json
import os
import struct
import zipfile

ROOT = os.path.dirname(os.path.abspath(__file__))
PKG = os.path.join(ROOT, "packages")
ZIP = os.path.join(ROOT, "zip")
os.makedirs(PKG, exist_ok=True)
os.makedirs(ZIP, exist_ok=True)

INDEX_HTML = """<!DOCTYPE html>
<html><head><title>Index of /pub/files</title></head>
<body>
<h1>Index of /pub/files</h1>
<pre>
<a href="?C=N;O=D">Name</a>
<a href="?C=M;O=A">Last modified</a>
<a href="../">Parent Directory</a>
<a href="releases/">releases/</a>                              -
<a href="manual.zip">manual.zip</a>                       1.2M
<a href="notes.pdf">notes.pdf</a>                         340K
<a href="archive.tar.gz">archive.tar.gz</a>                    2.5 GB
<a href="https://cdn.example.net/extra.bin">extra.bin</a>          12 MB
<a href="javascript:void(0)">bad link</a>
</pre>
</body></html>
"""

GITHUB = {
    "tag_name": "v1.4.0",
    "name": "Release 1.4.0",
    "assets": [
        {"name": "Siphon-1.4.0.dmg", "size": 12345678,
         "browser_download_url": "https://github.com/acme/siphon/releases/download/v1.4.0/Siphon-1.4.0.dmg"},
        {"name": "Siphon-1.4.0.zip", "size": 9876543,
         "browser_download_url": "https://github.com/acme/siphon/releases/download/v1.4.0/Siphon-1.4.0.zip"},
    ],
}

HF_TREE = [
    {"type": "directory", "path": "configs", "size": 0},
    {"type": "file", "path": "configs/config.json", "size": 512},
    {"type": "file", "path": "model.safetensors", "size": 4096,
     "lfs": {"oid": "abc123", "size": 4096}},
    {"type": "file", "path": "README.md", "size": 128},
]

with open(os.path.join(PKG, "index_of.html"), "w", encoding="utf-8") as f:
    f.write(INDEX_HTML)
with open(os.path.join(PKG, "github_release.json"), "w", encoding="utf-8") as f:
    json.dump(GITHUB, f, indent=2)
with open(os.path.join(PKG, "hf_tree.json"), "w", encoding="utf-8") as f:
    json.dump(HF_TREE, f, indent=2)

# Deterministic zip: one STORED entry, one DEFLATE entry.
sample = os.path.join(ZIP, "sample.zip")
with zipfile.ZipFile(sample, "w") as zf:
    zi = zipfile.ZipInfo("hello.txt", date_time=(2024, 1, 1, 0, 0, 0))
    zi.compress_type = zipfile.ZIP_STORED
    zf.writestr(zi, b"hello world")
    zi2 = zipfile.ZipInfo("folder/note.txt", date_time=(2024, 1, 1, 0, 0, 0))
    zi2.compress_type = zipfile.ZIP_DEFLATED
    zf.writestr(zi2, b"the quick brown fox jumps over the lazy dog" * 4)

# Corrupt variant: flip one byte inside the first entry's stored data so the
# CRC check must fail while the archive structure stays valid.
data = bytearray(open(sample, "rb").read())
# Local file header signature 0x04034b50
sig = b"PK\x03\x04"
offset = data.find(sig)
name_len = struct.unpack_from("<H", data, offset + 26)[0]
extra_len = struct.unpack_from("<H", data, offset + 28)[0]
data_start = offset + 30 + name_len + extra_len
data[data_start] ^= 0xFF
with open(os.path.join(ZIP, "corrupt.zip"), "wb") as f:
    f.write(data)

print("fixtures written")