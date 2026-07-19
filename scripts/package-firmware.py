#!/usr/bin/env python3
"""Package an ESP-IDF build into a firmware bundle for the Mac app.

    package-firmware.py <build-dir> <board> <version> <out-dir>

Reads build/flasher_args.json (authoritative offsets — never hand-write them),
copies the referenced .bin files flat into <out-dir>, and writes manifest.json:

  {"board":"ws175","chip":"esp32s3","version":"0.2.0",
   "flashMode":"dio","flashFreq":"80m","flashSize":"16MB",
   "parts":[{"offset":"0x0","file":"bootloader.bin","sha256":"..."}, ...]}

The Mac app downloads the zip of <out-dir>, verifies each part's sha256, and
feeds offsets/files to its bundled esptool.
"""
import hashlib
import json
import os
import shutil
import sys


def main() -> int:
    if len(sys.argv) != 5:
        print(__doc__, file=sys.stderr)
        return 2
    build_dir, board, version, out_dir = sys.argv[1:5]

    with open(os.path.join(build_dir, "flasher_args.json")) as f:
        fa = json.load(f)

    os.makedirs(out_dir, exist_ok=True)
    parts = []
    for offset, rel in sorted(fa["flash_files"].items(), key=lambda kv: int(kv[0], 0)):
        src = os.path.join(build_dir, rel)
        name = os.path.basename(rel)
        dst = os.path.join(out_dir, name)
        shutil.copyfile(src, dst)
        digest = hashlib.sha256(open(dst, "rb").read()).hexdigest()
        parts.append({"offset": offset, "file": name, "sha256": digest})

    settings = fa.get("flash_settings", {})
    manifest = {
        "board": board,
        "chip": fa.get("extra_esptool_args", {}).get("chip", "esp32s3"),
        "version": version,
        "flashMode": settings.get("flash_mode", "dio"),
        "flashFreq": settings.get("flash_freq", "80m"),
        "flashSize": settings.get("flash_size", "16MB"),
        "parts": parts,
    }
    with open(os.path.join(out_dir, "manifest.json"), "w") as f:
        json.dump(manifest, f, indent=2)
        f.write("\n")
    print(json.dumps(manifest, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
