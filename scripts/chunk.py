#!/usr/bin/env python3
"""
scripts/chunk.py

Splits a disk image into fixed-size chunks suitable for Cloudflare Pages
(each chunk stays well below the 25 MiB per-file limit) and writes a
metadata file that sw.js reads to reassemble Range requests.

Usage:
    python3 scripts/chunk.py <disk.img> [chunk_size_mb]

    disk.img        - path to the raw disk image
    chunk_size_mb   - optional, default 10 (MiB)

Output:
    public/chunks/disk.img.0000
    public/chunks/disk.img.0001
    ...
    public/chunks/meta.json
"""

import sys
import json
import os

CHUNK_DIR = os.path.join(os.path.dirname(__file__), "..", "public", "chunks")

def chunk(disk_path: str, chunk_size_mb: int = 10) -> None:
    chunk_size = chunk_size_mb * 1024 * 1024
    os.makedirs(CHUNK_DIR, exist_ok=True)

    total_size = os.path.getsize(disk_path)
    count = 0

    print(f"==> Chunking {disk_path}")
    print(f"    Total size : {total_size / 1024 / 1024:.1f} MiB")
    print(f"    Chunk size : {chunk_size_mb} MiB")

    with open(disk_path, "rb") as f:
        while True:
            data = f.read(chunk_size)
            if not data:
                break
            out_path = os.path.join(CHUNK_DIR, f"disk.img.{count:04d}")
            with open(out_path, "wb") as out:
                out.write(data)
            print(f"    Wrote chunk {count:04d} ({len(data) / 1024 / 1024:.1f} MiB)")
            count += 1

    meta = {
        "totalSize": total_size,
        "chunkSize": chunk_size,
        "count": count,
    }
    meta_path = os.path.join(CHUNK_DIR, "meta.json")
    with open(meta_path, "w") as mf:
        json.dump(meta, mf, indent=2)

    print(f"\n==> Done: {count} chunks → {CHUNK_DIR}")
    print(f"    meta.json written to {meta_path}")
    total_mb = sum(
        os.path.getsize(os.path.join(CHUNK_DIR, f))
        for f in os.listdir(CHUNK_DIR)
        if f.startswith("disk.img.")
    ) / 1024 / 1024
    print(f"    Total chunk data: {total_mb:.1f} MiB")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)

    img  = sys.argv[1]
    size = int(sys.argv[2]) if len(sys.argv) > 2 else 10

    if not os.path.isfile(img):
        print(f"Error: '{img}' not found.", file=sys.stderr)
        sys.exit(1)

    if size < 1 or size > 20:
        print("Error: chunk_size_mb must be between 1 and 20.", file=sys.stderr)
        sys.exit(1)

    chunk(img, size)
