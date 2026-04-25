#!/usr/bin/env bash
# scripts/prepare.sh
#
# Downloads v86 emulator binaries and BIOS files into public/.
# Run this once before your first deploy (or let CI run it).
#
# Usage:
#   bash scripts/prepare.sh
#
# Requirements: curl
set -euo pipefail

DEST="$(cd "$(dirname "$0")/.." && pwd)/public"
mkdir -p "$DEST"

V86_BASE="https://copy.sh/v86"

download() {
  local url="$1" out="$2"
  if [[ -f "$out" ]]; then
    echo "  (exists) $out"
    return
  fi
  echo "  Downloading $(basename "$out") …"
  curl -fsSL --retry 3 "$url" -o "$out"
}

echo "==> Downloading v86 emulator"
download "${V86_BASE}/build/v86.js"   "$DEST/v86.js"
download "${V86_BASE}/build/v86.wasm" "$DEST/v86.wasm"

echo "==> Downloading BIOS files"
download "${V86_BASE}/bios/seabios.bin" "$DEST/seabios.bin"
download "${V86_BASE}/bios/vgabios.bin" "$DEST/vgabios.bin"

echo ""
echo "Done! Files in $DEST:"
ls -lh "$DEST/v86.js" "$DEST/v86.wasm" "$DEST/seabios.bin" "$DEST/vgabios.bin"
echo ""
echo "Next step: provide a disk.img and run  bash scripts/chunk.sh <path/to/disk.img>"
