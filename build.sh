#!/bin/bash
# ============================================================================
# FM Towns CD Menu — Build Script
#
# Repo layout:
#   /
#   ├── CDSWMENU.ASM                ← our code (repo root)
#   ├── make_fdimagem.py            ← build helper (repo root)
#   ├── make_hdimagem.py            ← build helper (repo root)
#   ├── build.sh                    ← this script (repo root)
#   ├── deps/
#   │   └── captainys-FM/           ← git submodule (github.com/captainys/FM)
#   └── dist/
#       ├── FDIMAGEM.BIN            ← output
#       ├── HDIMAGEM.BIN            ← output
#       └── LOADER.BIN              ← output
#
# Prerequisites:
#   - JWASM in PATH (or set JWASM=/path/to/jwasm)
#   - Python 3
#   - git submodule init'd: git submodule update --init
#
# Usage:
#   ./build.sh              # full build
#   ./build.sh clean        # remove build artifacts
# ============================================================================

set -e

# Root of the repo = where this script lives
ROOT="$(cd "$(dirname "$0")" && pwd)"
JWASM="${JWASM:-jwasm}"

# Directories
CAPTAINYS_DIR="$ROOT/deps/captainys-FM/TOWNS"
BUILD_DIR="$ROOT/build"
DIST_DIR="$ROOT/dist"

# Clean
if [ "$1" = "clean" ]; then
    rm -rf "$BUILD_DIR"
    echo "Cleaned build directory."
    exit 0
fi

# Check prerequisites
if ! command -v "$JWASM" &>/dev/null; then
    echo "ERROR: JWASM not found. Set JWASM=/path/to/jwasm or add to PATH."
    echo "Build JWASM: git clone https://github.com/Baron-von-Riedesel/JWasm.git"
    echo "             cd JWasm && make -f GccUnix.mak && cd build/GccUnixR && gcc *.o -o jwasm"
    exit 1
fi

if [ ! -d "$CAPTAINYS_DIR/IPL" ]; then
    echo "ERROR: CaptainYS sources not found at $CAPTAINYS_DIR"
    echo "Run:  git submodule update --init"
    exit 1
fi

if [ ! -f "$ROOT/CDSWMENU.ASM" ]; then
    echo "ERROR: CDSWMENU.ASM not found at repo root ($ROOT)"
    exit 1
fi

echo "=== FM Towns CD Menu Build ==="
echo "  Repo root  : $ROOT"
echo "  CaptainYS  : $CAPTAINYS_DIR"
echo "  JWASM      : $(which $JWASM)"
echo "  Build dir  : $BUILD_DIR"
echo "  Output dir : $DIST_DIR"
echo ""

# ── Step 1: Stage CaptainYS sources into build dir ──────────────────────────
echo "--- Step 1: Staging CaptainYS sources ---"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR/IPL"
mkdir -p "$DIST_DIR"

cp "$CAPTAINYS_DIR"/IPL/*.ASM "$BUILD_DIR/IPL/" 2>/dev/null || true
cp "$CAPTAINYS_DIR"/IPL/*.BIN "$BUILD_DIR/IPL/" 2>/dev/null || true

for dir in SCSILIB RS232C MISCLIB RESOURCE YSSCSICD; do
    if [ -d "$CAPTAINYS_DIR/$dir" ]; then
        cp -r "$CAPTAINYS_DIR/$dir" "$BUILD_DIR/"
    fi
done
echo "  OK"

# ── Step 2: Inject CD Menu code ─────────────────────────────────────────────
echo "--- Step 2: Injecting CD Menu ---"

cp "$ROOT/CDSWMENU.ASM" "$BUILD_DIR/IPL/"
echo "  Copied CDSWMENU.ASM"

cd "$BUILD_DIR/IPL"

# Patch LOADER.ASM: splash text
sed -i.bak 's/DB	"FM TOWNS RESCUE BOOT LOADER BY CAPTAINYS",0/DB	"FMTOWNS RESCUE + CD MENU BY CAPTAINYS AND TUGS",0/' LOADER.ASM

# Patch LOADER.ASM: add INCLUDE CDSWMENU.ASM after MAINMENU.ASM
sed -i.bak 's/INCLUDE		MAINMENU.ASM/INCLUDE		MAINMENU.ASM\
						INCLUDE		CDSWMENU.ASM/' LOADER.ASM
echo "  Patched LOADER.ASM"

# Patch MAINMENU.ASM: add 6th entry
sed -i.bak 's/NUM_MAINMENU_OPTIONS	EQU		5/NUM_MAINMENU_OPTIONS	EQU		6/' MAINMENU.ASM

sed -i.bak 's/DB		"IPL DEBUG (DUMP B0000 to B00FF)",0/DB		"IPL DEBUG (DUMP B0000 to B00FF)",0\
						DB		"CD MENU - SWITCH CD",0/' MAINMENU.ASM

sed -i.bak 's/DW		OFFSET IPLDEBUG$/DW		OFFSET IPLDEBUG\
						DW		OFFSET CDSWMENU/' MAINMENU.ASM

# Replace CALL BOOTMENU with CALL CDSWMENU → boot directly into CD Menu
sed -i.bak 's/CALL	BOOTMENU	; Go to BOOT MENU first/CALL	CDSWMENU	; Boot directly into CD Menu/' MAINMENU.ASM
echo "  Patched MAINMENU.ASM"

# ── Step 3: JWASM compatibility fixes ────────────────────────────────────────
echo "--- Step 3: JWASM compatibility fixes ---"

sed -i.bak 's/REP		CMPSB/REPE	CMPSB/g' SCSIUTIL.ASM
sed -i.bak 's/MOV		SI,BLUESCSI_VENDORID/MOV		SI,OFFSET BLUESCSI_VENDORID/' SCSIUTIL.ASM
sed -i.bak 's/MOV		SI,ZULUSCSI_VENDORID/MOV		SI,OFFSET ZULUSCSI_VENDORID/' SCSIUTIL.ASM
sed -i.bak 's/MOV		SI,SCSI2SD_VENDORID/MOV		SI,OFFSET SCSI2SD_VENDORID/' SCSIUTIL.ASM
sed -i.bak 's/^CRTC_31K:/CRTC_31K /' PATCH.ASM
sed -i.bak 's/^CRTC_24K:/CRTC_24K /' PATCH.ASM
rm -f *.bak
echo "  OK"

# ── Step 4: Assemble ─────────────────────────────────────────────────────────
echo "--- Step 4: Assembling ---"

"$JWASM" -Zm -bin -Fo=LOADER.BIN LOADER.ASM 2>&1 | tail -1
echo "  LOADER.BIN   : $(wc -c < LOADER.BIN | tr -d ' ') bytes"

"$JWASM" -Zm -bin -Fo=FD_IPLM.BIN FD_IPLM.ASM 2>&1 | tail -1
echo "  FD_IPLM.BIN  : $(wc -c < FD_IPLM.BIN | tr -d ' ') bytes"

"$JWASM" -Zm -bin -Fo=HD_IPL0.BIN HD_IPL0.ASM 2>&1 | tail -1
"$JWASM" -Zm -bin -Fo=HD_IPL.BIN HD_IPL.ASM 2>&1 | tail -1
echo "  HD_IPL0/1.BIN: OK"

# ── Step 5: Build disk images ────────────────────────────────────────────────
echo "--- Step 5: Building disk images ---"

cp "$ROOT/make_fdimagem.py" .
cp "$ROOT/make_hdimagem.py" .
python3 make_fdimagem.py
python3 make_hdimagem.py

# ── Step 6: Copy to dist ─────────────────────────────────────────────────────
echo "--- Step 6: Delivering to dist/ ---"
cp FDIMAGEM.BIN HDIMAGEM.BIN LOADER.BIN "$DIST_DIR/"

echo ""
echo "=== Build complete ==="
echo "  dist/FDIMAGEM.BIN : $(wc -c < "$DIST_DIR/FDIMAGEM.BIN" | tr -d ' ') bytes  (floppy 2HD 1232KB)"
echo "  dist/HDIMAGEM.BIN : $(wc -c < "$DIST_DIR/HDIMAGEM.BIN" | tr -d ' ') bytes  (SCSI HD 1025KB)"
echo "  dist/LOADER.BIN   : $(wc -c < "$DIST_DIR/LOADER.BIN" | tr -d ' ') bytes"
