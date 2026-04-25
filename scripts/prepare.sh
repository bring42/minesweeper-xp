#!/usr/bin/env bash
# scripts/prepare.sh
#
# Downloads v86 emulator binaries and BIOS files into public/.
# Also creates public/chunks/meta.json for stub disk mode (no real disk image needed).
#
# Usage:
#   bash scripts/prepare.sh
#
# Requirements: curl
set -euo pipefail

DEST="$(cd "$(dirname "$0")/.." && pwd)/public"
mkdir -p "$DEST" "$DEST/chunks"

# Official v86 release assets (libv86.js is the embeddable build)
V86_RELEASE="https://github.com/copy/v86/releases/download/latest"
V86_BIOS="https://github.com/copy/v86/raw/master/bios"

# Windows 98 virtual disk size (must match what v86 expects for the state)
WIN98_DISK_SIZE=314572800

download() {
  local url="$1" out="$2"
  if [[ -f "$out" ]]; then
    echo "  (exists) $out"
    return
  fi
  echo "  Downloading $(basename "$out") …"
  curl -fsSL --retry 3 -L "$url" -o "$out"
}

echo "==> Downloading v86 emulator (from GitHub releases)"
download "${V86_RELEASE}/libv86.js"  "$DEST/libv86.js"
download "${V86_RELEASE}/v86.wasm"   "$DEST/v86.wasm"

echo "==> Downloading BIOS files"
download "${V86_BIOS}/seabios.bin" "$DEST/seabios.bin"
download "${V86_BIOS}/vgabios.bin" "$DEST/vgabios.bin"

echo "==> Writing stub disk metadata (no real disk image needed)"
cat > "$DEST/chunks/meta.json" <<JSON
{
  "totalSize": ${WIN98_DISK_SIZE},
  "stub": true,
  "note": "Disk reads are served as zeros; all needed sectors are in the state file"
}
JSON
echo "  Written: $DEST/chunks/meta.json"

echo ""
echo "Done! Files in $DEST:"
ls -lh "$DEST/libv86.js" "$DEST/v86.wasm" "$DEST/seabios.bin" "$DEST/vgabios.bin"
echo ""
echo "Stub meta.json written — no disk image build required."
echo "The Windows 98 state is loaded from https://i.copy.sh/ at runtime."
echo ""
echo "To use your OWN disk image instead:"
echo "  1. Build or obtain a disk.img"
echo "  2. Run: python3 scripts/chunk.py disk.img"
echo "     (this overwrites chunks/meta.json with real chunk mode)"
