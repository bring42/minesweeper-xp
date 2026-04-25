#!/usr/bin/env bash
# scripts/prepare.sh
#
# Downloads Boxedwine (Wine-in-browser) and prepares all assets for deployment.
# Chunks boxedwine.zip (37 MB) into 20 MB pieces for Cloudflare Pages (25 MB/file limit).
# Bundles winmine.exe into winmine.zip for the app payload.
#
# Usage:
#   bash scripts/prepare.sh
#
# Requirements: curl, python3, zip
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DEST="$REPO_DIR/public"
ASSET_DIR="$REPO_DIR/minesweeperxp"

mkdir -p "$DEST" "$DEST/chunks"

BOXEDWINE_URL="https://github.com/danoon2/Boxedwine/releases/download/26R1.0/Boxedwine26R1Web.zip"
CHUNK_SIZE=$((20 * 1024 * 1024))   # 20 MB — safely under CF Pages' 25 MB/file limit

# ── Download Boxedwine web release ────────────────────────────────────────
echo "==> Downloading Boxedwine 26R1 web release (~117 MB)…"
TMP_DIR="$(mktemp -d)"
TMP_ZIP="$TMP_DIR/boxedwine_web.zip"
curl -fsSL --retry 3 -L "$BOXEDWINE_URL" -o "$TMP_ZIP"
echo "    Downloaded: $(du -sh "$TMP_ZIP" | cut -f1)"

# ── Extract JS/WASM/CSS files ─────────────────────────────────────────────
echo "==> Extracting Boxedwine runtime files…"
for f in boxedwine.js boxedwine.wasm boxedwine-shell.js boxedwine.css; do
  unzip -j -o "$TMP_ZIP" "MultiThreaded/$f" -d "$DEST"
  echo "    $(ls -sh "$DEST/$f" | awk '{print $1}')  $f"
done

# Extract Wine filesystem zip to temp for chunking
unzip -j -o "$TMP_ZIP" "MultiThreaded/boxedwine.zip" -d "$TMP_DIR"
echo "    $(du -sh "$TMP_DIR/boxedwine.zip" | cut -f1)  boxedwine.zip (Wine filesystem)"

# ── Patch shell.js to auto-run winmine.exe ────────────────────────────────
echo "==> Patching boxedwine-shell.js to auto-run winmine.exe…"
python3 - "$DEST/boxedwine-shell.js" <<'PYEOF'
import sys
path = sys.argv[1]
with open(path) as f:
    c = f.read()
c = c.replace(
    'Config.urlParams = "";',
    'Config.urlParams = "app=winmine&p=winmine.exe";',
    1
)
assert 'app=winmine' in c, "Patch failed — Config.urlParams not found"
with open(path, 'w') as f:
    f.write(c)
print("    Patched: Config.urlParams = \"app=winmine&p=winmine.exe\"")
PYEOF

# ── Chunk boxedwine.zip into 20 MB pieces ────────────────────────────────
echo "==> Chunking boxedwine.zip (20 MB pieces)…"
python3 - "$TMP_DIR/boxedwine.zip" "$DEST/chunks" "$CHUNK_SIZE" <<'PYEOF'
import sys, os, math, json
src, dest, chunk_size = sys.argv[1], sys.argv[2], int(sys.argv[3])
with open(src, 'rb') as f:
    data = f.read()
total = len(data)
count = math.ceil(total / chunk_size)
for i in range(count):
    chunk = data[i * chunk_size:(i + 1) * chunk_size]
    out = os.path.join(dest, f'boxedwine.zip.{i:04d}')
    with open(out, 'wb') as cf:
        cf.write(chunk)
    print(f"    chunk {i:04d}: {len(chunk) / 1024 / 1024:.1f} MB")
meta = {"filename": "boxedwine.zip", "totalSize": total, "chunkSize": chunk_size, "count": count}
with open(os.path.join(dest, 'meta.json'), 'w') as mf:
    json.dump(meta, mf, indent=2)
print(f"    total: {total / 1024 / 1024:.1f} MB in {count} chunks → meta.json written")
PYEOF

# ── Bundle winmine.exe as an app zip ─────────────────────────────────────
echo "==> Creating winmine.zip…"
(cd "$ASSET_DIR" && zip -j "$DEST/winmine.zip" "winmine.exe")
echo "    $(ls -sh "$DEST/winmine.zip" | awk '{print $1}')  winmine.zip"

# ── Cleanup ───────────────────────────────────────────────────────────────
rm -rf "$TMP_DIR"

echo ""
echo "==> Done! public/ summary:"
ls -lh "$DEST/boxedwine.js" "$DEST/boxedwine.wasm" "$DEST/winmine.zip"
echo "    chunks/:"
ls -lh "$DEST/chunks/"
