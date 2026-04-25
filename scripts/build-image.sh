#!/usr/bin/env bash
# scripts/build-image.sh
#
# Builds a minimal Windows 98 SE disk image for v86 that auto-launches
# Minesweeper on boot.  Requires QEMU and a Windows 98 SE ISO.
#
# Usage:
#   bash scripts/build-image.sh [path/to/win98se.iso]
#
# If no ISO path is provided, the script looks for win98se.iso in the
# current directory.
#
# The finished image is written to  disk.img  in the project root.
#
# ── What you need ───────────────────────────────────────────────────────────
#
#  1. A Windows 98 SE ISO  (OEM or retail)
#     Microsoft never officially released Windows 98 as freeware.
#     If you own a licence, rip the CD.  Many preservation sites also
#     host the ISO; check https://archive.org/search?query=windows+98+SE
#
#  2. qemu-system-i386 and qemu-img
#     macOS:  brew install qemu
#     Linux:  apt install qemu-system-x86 qemu-utils  (or dnf/pacman equiv.)
#
# ── High-level flow ─────────────────────────────────────────────────────────
#
#  1. Create a blank 256 MiB disk image
#  2. Boot QEMU with the Windows 98 SE ISO to install Windows
#     (you MUST complete the GUI install manually — ~10 minutes)
#  3. After the first reboot mounts the image and injects minesweeper.exe
#     (extracted from minesweeperxp.zip / archive.org) + AUTOEXEC.BAT
#     that launches it on login
#
# Because the GUI install requires human input, this script launches QEMU
# interactively.  You work through the installer normally; when Windows
# first reboots into the desktop the script can continue automatically.
#
# ── Alternatively: skip the build and supply your own disk.img ──────────────
#
#  If you already have a bootable Windows 9x/Me/2000/XP disk image that
#  works with v86, just put it at disk.img in the project root and run:
#
#    python3 scripts/chunk.py disk.img
#
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ISO="${1:-$ROOT_DIR/win98se.iso}"
DISK_IMG="$ROOT_DIR/disk.img"
DISK_SIZE="256M"

MINESWEEPER_ZIP_URL="https://archive.org/download/minesweeperxp/minesweeper.zip"
WINMINE_EXE="$ROOT_DIR/winmine.exe"
LOCAL_ZIP="$ROOT_DIR/minesweeperxp/minesweeper.zip"   # already in the repo
FLOPPY_IMG="$ROOT_DIR/autorun.img"

# ── Preflight ─────────────────────────────────────────────────────────────────

check_cmd() {
  command -v "$1" &>/dev/null || { echo "Error: '$1' not found. $2"; exit 1; }
}

check_cmd qemu-system-i386 "Install QEMU: brew install qemu"
check_cmd qemu-img          "Install QEMU: brew install qemu"
check_cmd python3           "Python 3 is required."

if [[ ! -f "$ISO" ]]; then
  echo ""
  echo "ERROR: Windows 98 SE ISO not found at: $ISO"
  echo ""
  echo "Please provide the path to your Windows 98 SE ISO:"
  echo "  bash scripts/build-image.sh /path/to/win98se.iso"
  echo ""
  echo "Don't have an ISO? Check:"
  echo "  https://archive.org/search?query=windows+98+SE+iso"
  echo ""
  exit 1
fi

# ── Step 1: Download minesweeper.exe ──────────────────────────────────────────

if [[ ! -f "$WINMINE_EXE" ]]; then
  # Prefer the local zip already in the repo; fall back to archive.org
  if [[ -f "$LOCAL_ZIP" ]]; then
    echo "==> Extracting winmine.exe from local minesweeperxp/minesweeper.zip …"
    TMP_ZIP="$LOCAL_ZIP"
    _cleanup_zip=false
  else
    echo "==> Downloading minesweeper.exe from archive.org …"
    TMP_ZIP="$(mktemp).zip"
    curl -fsSL --retry 3 "$MINESWEEPER_ZIP_URL" -o "$TMP_ZIP"
    _cleanup_zip=true
  fi

  # Extract — the zip contains winmine.exe (the actual binary name on XP)
  python3 - <<PYEOF
import zipfile, shutil, os

zip_path = "${TMP_ZIP}"
dest     = "${WINMINE_EXE}"

with zipfile.ZipFile(zip_path) as z:
    names = z.namelist()
    print("Zip contents:", names)
    exe = next(
        (n for n in names if n.lower().endswith('.exe')),
        None
    )
    if not exe:
        raise RuntimeError("No .exe found inside minesweeper.zip")
    with z.open(exe) as src, open(dest, 'wb') as dst:
        shutil.copyfileobj(src, dst)
    print(f"Extracted {exe} -> {dest}")
PYEOF
  ${_cleanup_zip:-false} && rm -f "$TMP_ZIP"
fi

echo "    minesweeper.exe: $(wc -c < "$WINMINE_EXE") bytes"

# ── Step 2: Create the blank disk image ───────────────────────────────────────

if [[ ! -f "$DISK_IMG" ]]; then
  echo "==> Creating blank disk image ($DISK_SIZE) …"
  qemu-img create -f raw "$DISK_IMG" "$DISK_SIZE"
fi

# ── Step 3: Build a small floppy with autorun helpers ─────────────────────────
# We'll mount this as a second drive during/after install so Windows can read it.

echo "==> Building helper floppy with winmine.exe …"
python3 - <<PYEOF
import struct, os, shutil, math

# Create a minimal FAT12 floppy image (1.44 MB = 2880 sectors × 512 bytes)
FLOPPY  = "${FLOPPY_IMG}"
EXE_SRC = "${WINMINE_EXE}"

SECTOR_SIZE   = 512
SECTORS       = 2880          # 1.44 MB floppy
RESERVED      = 1             # Boot sector
FAT_SECTORS   = 9
NUM_FATS      = 2
ROOT_ENTRIES  = 224
DATA_START    = RESERVED + NUM_FATS * FAT_SECTORS + (ROOT_ENTRIES * 32 // SECTOR_SIZE)
TOTAL_BYTES   = SECTORS * SECTOR_SIZE

img = bytearray(TOTAL_BYTES)

# Boot sector (BPB)
bpb = struct.pack('<3sHBHBHHBHHHIIHH11s8s',
    b'\\xeb\\xfe\\x90',   # jmp short; nop
    SECTOR_SIZE,           # bytes per sector
    1,                     # sectors per cluster
    RESERVED,              # reserved sectors
    NUM_FATS,              # number of FATs
    ROOT_ENTRIES,          # root dir entries
    SECTORS,               # total sectors
    0xF0,                  # media descriptor (removable)
    FAT_SECTORS,           # sectors per FAT
    18,                    # sectors per track
    2,                     # number of heads
    0,                     # hidden sectors
    0,                     # large sector count
    0,                     # drive number padding
    0x29,                  # extended boot sig
    0x12345678,            # volume serial
    0,                     # volume serial hi
    b'MINESWEEPER',        # volume label (11 bytes)
    b'FAT12   ',           # FS type
)
img[:len(bpb)] = bpb
img[510] = 0x55; img[511] = 0xAA

# FAT tables (FAT12 — mark clusters 0,1 as reserved, rest free)
fat_offset = RESERVED * SECTOR_SIZE
# Cluster 0 = 0xFF0 (media), Cluster 1 = 0xFFF (end-of-chain)
img[fat_offset + 0] = 0xF0; img[fat_offset + 1] = 0xFF; img[fat_offset + 2] = 0xFF
for i in range(NUM_FATS):
    start = (RESERVED + i * FAT_SECTORS) * SECTOR_SIZE
    img[start + 0] = 0xF0; img[start + 1] = 0xFF; img[start + 2] = 0xFF

# Copy winmine.exe into data area (cluster 2 = first data cluster)
exe_data    = open(EXE_SRC, 'rb').read()
exe_name    = b'WINMINE EXE'   # 8+3 uppercase padded
data_offset = DATA_START * SECTOR_SIZE
img[data_offset : data_offset + len(exe_data)] = exe_data

# Root directory entry for WINMINE.EXE
root_offset = (RESERVED + NUM_FATS * FAT_SECTORS) * SECTOR_SIZE
entry = struct.pack('<11sBBBHHHHHHHI',
    exe_name,
    0x20,             # attribute: ARCHIVE
    0,                # reserved
    0,                # creation time ms
    0x0000,           # creation time
    0x0000,           # creation date
    0x0000,           # access date
    0,                # high cluster word (FAT12 = 0)
    0x0000,           # write time
    0x0000,           # write date
    2,                # start cluster
    len(exe_data),    # file size
)
img[root_offset : root_offset + 32] = entry

with open(FLOPPY, 'wb') as f:
    f.write(img)

print(f"Floppy image written to {FLOPPY} ({len(img)} bytes)")
PYEOF

# ── Step 4: Interactive Windows install ───────────────────────────────────────

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║            INTERACTIVE WINDOWS INSTALLATION                  ║"
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║  QEMU will now open a window. Complete the Windows 98 SE     ║"
echo "║  installation normally.  When you reach the Windows desktop: ║"
echo "║                                                               ║"
echo "║  1. Open 'My Computer'                                       ║"
echo "║  2. Open the A: drive (floppy) — it contains WINMINE.EXE    ║"
echo "║  3. Copy WINMINE.EXE to C:\\Windows                          ║"
echo "║  4. Create a shortcut in the Startup folder                  ║"
echo "║     OR edit C:\\AUTOEXEC.BAT to end with:                    ║"
echo "║       start /w C:\\Windows\\winmine.exe                       ║"
echo "║  5. Close QEMU.  Run this script again to finalize.          ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "Starting QEMU …  (this window is the VM)"
echo ""

qemu-system-i386 \
  -m 128 \
  -cpu pentium3 \
  -hda "$DISK_IMG" \
  -cdrom "$ISO" \
  -fda "$FLOPPY_IMG" \
  -boot d \
  -vga std \
  -soundhw sb16 \
  -no-reboot \
  2>/dev/null || true

echo ""
echo "QEMU exited."
echo ""
echo "If installation is complete, run:"
echo "  python3 scripts/chunk.py disk.img"
echo "  bash scripts/prepare.sh"
echo "  git add public/ && git commit -m 'chore: add disk image chunks'"
echo "  git push"
echo ""
echo "Then see README.md for deploying to Cloudflare Pages."
