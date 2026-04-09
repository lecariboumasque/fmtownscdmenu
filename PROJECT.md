# FM Towns CD Menu — Project Summary

A direct CD selector integrated into CaptainYS' Rescue IPL boot loader, letting
FM Towns users switch between CD images on a BlueSCSI v2 without ever touching
the SD card. Pick a game from a menu, press a key, and either return to the
boot menu or boot straight into it.

---

## 1. BlueSCSI Concepts Used

### The `/CD3/` directory convention

BlueSCSI v2 uses a per-SCSI-ID directory on the SD card: everything relevant to
the CD drive assigned to **SCSI ID 3** lives under `/CD3/`. Every CD image is a
`.cue` + `.bin` pair stored directly in this directory (no subfolders):

```
/CD3/
  01_RAINBOW_ISLAND.cue
  01_RAINBOW_ISLAND.bin
  02_RAIDEN.cue
  02_RAIDEN.bin
  03_AFTER_BURNER_3.cue
  03_AFTER_BURNER_3.bin
  ...
```

BlueSCSI prefers the `.cue` file when both a `.bin` and `.cue` exist, so the
`.cue` is the "active" entry from BlueSCSI's point of view. The BlueSCSI
Toolbox `LIST_CDS` command however returns the `.bin` names; the firmware
internally maps back to the `.cue` when opening a selection.

Up to **100 CD images** per directory are supported (the Toolbox caps out at
`MAX_FILE_LISTING_FILES = 100`).

On startup, BlueSCSI opens the first image it finds in the directory and
presents it as the mounted CD on SCSI ID 3. After that, the host is free to
swap images using Toolbox vendor commands.

### Toolbox vendor SCSI commands

BlueSCSI exposes three vendor-specific 10-byte SCSI CDBs that let a host
enumerate and swap CD images without touching the SD card:

| Opcode | Mnemonic      | Data direction | Description                                      |
|--------|---------------|----------------|--------------------------------------------------|
| `0xDA` | `COUNT_CDS`   | Device → Host  | Returns 1 byte: number of CDs in `/CD{ID}/`      |
| `0xD7` | `LIST_CDS`    | Device → Host  | Returns N × 40 byte entries (index, name, size)  |
| `0xD8` | `SET_NEXT_CD` | (no data)      | CDB[1] = file index. Switches the active image.  |

Each `LIST_CDS` entry is 40 bytes:

```
byte 0       : entry index (0..N-1)
byte 1       : isDir flag (always 0x01 for files)
bytes 2..34  : NUL-terminated filename (max 32 characters)
bytes 35..39 : file size in big-endian (40-bit)
```

These commands have high-order bits `110` which is not a standard SCSI CDB
length group, but in practice the FM Towns BIOS (`INT 93H AH=0FDH`) and direct
SCSI controller I/O both clock out exactly 10 bytes for them — verified by
debug logging on real hardware during development.

### Post-switch semantics

After `SET_NEXT_CD` succeeds, BlueSCSI sets the drive to "ejected +
reinsert pending" and raises a `New Media` CDROM event. The next
`TEST UNIT READY` (or the next host read) settles the drive onto the new
image. The CD Menu delegates this settling to CaptainYS'
`WAIT_SCSI_CD_READY` routine whenever it chain-loads into
`BOOT_FROM_SCSI_CD`, so no extra polling is required in our code.

---

## 2. CD Menu — Architecture and Functions

### File & placement

**`CDSWMENU.ASM`** is a new source file that defines a sub-menu added to
CaptainYS' Rescue IPL `LOADER.BIN`. It is `INCLUDE`d from `LOADER.ASM`
alongside the existing sub-menus (`CMOSMENU.ASM`, `DRVMENU.ASM`, etc.) and
added as the 6th entry in the main menu's jump table.

At runtime the sub-menu lives inside the same real-mode 16-bit segment as the
rest of the IPL (loaded at physical `0xB0000` by the FM Towns ROM / CaptainYS
IPL flow). It reuses every UI primitive from CaptainYS' code rather than
reimplementing any of the display layer:

| CaptainYS primitive    | Used for                                              |
|------------------------|-------------------------------------------------------|
| `DRAWMENU2`-style loop | drawing multiple menu items                           |
| `LOCATE` / `PRINT_TALL`| text rendering at arbitrary (X, Y) positions          |
| `TEXTLOCATION` macro   | compile-time position setup                           |
| `COLOR`                | switching the active palette colour                   |
| `CLEAR_FIVE_BELOW`     | clearing the menu area between frames                 |
| `READ_PADA`            | unified pad + keyboard input                          |
| `MOVE_ARROW_BY_PAD`    | up/down navigation                                    |
| `DRAWARROW`            | cursor/selection arrow drawing                        |
| `MENU_WAIT_PAD_RELEASE`| debouncing between menus                              |

### Low-level SCSI path

CD Menu does **not** go through `INT 93H`. It calls CaptainYS'
`SCSI_COMMAND` proc directly (from `../SCSILIB/SCSIIO.ASM`), which talks to
the SCSI controller hardware ports in polled mode. The command flow is:

```
  DS:SI  → 10-byte CDB (one of CMD_COUNT / CMD_LIST / CMD_SETNEXT)
  CL     = SCSI ID (read from CS:[SCSI_ID_CDROM])
  EDI    = physical address of the reply buffer
            = (CS << 4) + OFFSET CDSWMENU_REPLY_BUF
```

The reply buffer is 4000 bytes (100 × 40), inside the loader segment.

### Main functions

| Function                        | Purpose                                                              |
|---------------------------------|----------------------------------------------------------------------|
| `CDSWMENU`                      | Entry point; called from the main menu's jump table                  |
| `CDSWMENU_SEND_COUNT`           | Sends `COUNT_CDS` (0xDA), returns the count in the reply buffer      |
| `CDSWMENU_SEND_LIST`            | Sends `LIST_CDS` (0xD7), fills the reply buffer with N × 40 bytes    |
| `CDSWMENU_SEND_SETNEXT`         | Sends `SET_NEXT_CD` (0xD8) with the file index in CDB[1]             |
| `CDSWMENU_BUILD_PAGE_BUF`       | For the current page, cleans each filename and concatenates the     |
|                                 | results into `CDSWMENU_DISP_BUF` as NUL-terminated strings           |
| `CDSWMENU_CLEAN_NAME_FOR_INDEX` | Strips the `NN_` numeric prefix, drops the extension, replaces `_`   |
|                                 | with space, uppercases everything                                    |
| `CDSWMENU_DRAW_PAGE`            | Per-item draw loop; `BACK TO MAIN MENU` in white, each game in blue, |
|                                 | the currently-active CD in green                                     |
| `CDSWMENU_DRAW_PAGE_INDICATOR`  | `PAGE X / Y` top-right when there is more than one page              |
| `CDSWMENU_UPDATE_PAGE_COUNT`    | Computes the number of items visible on the current page            |
| `CDSWMENU_PAD_LR_ONLY`          | Pure left/right detection on pad bits 2 and 3 (excludes bits 4/5)   |
| `CDSWMENU_SKIP_CSTR`            | Walks a DS:SI pointer past a NUL terminator                          |
| `CDSWMENU_ITOA_SMALL`           | Decimal conversion for the page indicator                            |

### Interaction flow with BlueSCSI

```
┌──────────────────┐    COUNT_CDS (0xDA)    ┌──────────┐
│                  │ ─────────────────────> │          │
│                  │ <─ 1 byte: count ──── │          │
│                  │                        │          │
│   CDSWMENU on    │    LIST_CDS (0xD7)     │ BlueSCSI │
│   FM Towns IPL   │ ─────────────────────> │  v2      │
│  (real mode,     │ <─ N × 40 bytes ──── │          │
│   0xB0000)       │                        │          │
│                  │  SET_NEXT_CD (0xD8)    │          │
│                  │ ─ (CDB[1]=file_idx) ─> │          │
└──────────────────┘                        └──────────┘
         │
         │ (Enter) → return to MAIN MENU (v5.4 behaviour)
         │ (Space) → CALL BOOT_FROM_SCSI_CD  (direct boot)
         ▼
  ┌──────────────────┐
  │ IO.SYS loaded at │
  │   0x00000400     │  ← CaptainYS' CDBOOT.ASM logic
  │   then JMP       │
  └──────────────────┘
```

### Keyboard & pad mapping

`READ_PADA` merges pad and keyboard input:

| Input          | Effect on `AL`      | `AH` scan code |
|----------------|---------------------|----------------|
| Pad up         | bit 0 cleared       | 06h (port hi)  |
| Pad down       | bit 1 cleared       | 06h            |
| Pad left       | bit 2 cleared       | 06h            |
| Pad right      | bit 3 cleared       | 06h            |
| Pad button A   | bit 4 cleared       | 06h            |
| Pad button B   | bit 5 cleared       | 06h            |
| Keyboard ↑/↓/←/→ | bits 0..3 cleared | 4Dh/50h/4Fh/51h|
| Keyboard Enter | bit 4 cleared       | `1Dh`          |
| Keyboard Space | bit 4 cleared       | `35h`          |
| Keyboard Execute| bit 4 cleared      | `73h`          |

CD Menu differentiates Enter vs Space by inspecting `AH` (keyboard scan
code), since both keys clear the same pad bit. Pad B is exclusive to hardware
(no keyboard key maps to bit 5), so it is detected via pad state alone.

### Visual state

| Element                             | Colour        |
|-------------------------------------|---------------|
| Title ("FM TOWNS SCSI CD MENU")     | 14 — yellow   |
| Nav hints / PAGE indicator          | 11 — cyan     |
| `BACK TO MAIN MENU`                 | 15 — white    |
| Unselected CDs                      |  9 — blue     |
| Currently active CD                 | 10 — green    |
| Error messages                      | 12 — red      |

---

## 3. Modifications to CaptainYS' Original Source

The project keeps 100% of CaptainYS' Rescue IPL working and only additively
patches the sources. No functionality is removed; the existing sub-menus
(CMOS, BOOT, SERIAL, RESCAN, IPL DEBUG) still work exactly as before.

### Touched files

**`MAINMENU.ASM`** — two small edits:

1. Removed the automatic `CALL BOOTMENU` at the very top of the main loop so
   the boot sequence arrives on the main menu instead of forcing the user
   into the boot sub-menu first.

2. Added the new menu entry and jump table slot:

   ```masm
   NUM_MAINMENU_OPTIONS    EQU   6            ; was 5

   MAINMENU_ITEM_BUFFER    DB    "CMOS MENU",0
                           DB    "BOOT MENU",0
                           DB    "SERIAL (RS232C) MENU",0
                           DB    "RE-SCAN SCSI DEVICES",0
                           DB    "IPL DEBUG (DUMP B0000 to B00FF)",0
                           DB    "CD MENU - SWITCH CD",0       ; NEW

   MAINMENU_JUMPTABLE      DW    OFFSET CMOSMENU
                           DW    OFFSET BOOTMENU
                           DW    OFFSET RS232CMENU
                           DW    OFFSET RESCANSCSI
                           DW    OFFSET IPLDEBUG
                           DW    OFFSET CDSWMENU               ; NEW
   ```

**`LOADER.ASM`** — two small edits:

1. Splash text:

   ```masm
   ; was: DB "FM TOWNS RESCUE BOOT LOADER BY CAPTAINYS",0
   MESSAGE_LINE0   DB "FMTOWNS RESCUE + CD MENU BY CAPTAINYS AND TUGS",0
   ```

2. `INCLUDE` the new sub-menu source right after `MAINMENU.ASM`:

   ```masm
   INCLUDE   MAINMENU.ASM
   INCLUDE   CDSWMENU.ASM   ; NEW
   INCLUDE   RS232MNU.ASM
   ```

**`CDSWMENU.ASM`** — entirely new file (~700 lines of MASM-style assembly)
containing every function listed in section 2 above.

### JWASM-compatibility fixes (upstream sources)

CaptainYS' sources were originally built with MASM 5.1/6.x. JWASM (the
open-source Open Watcom assembler for macOS , yes sorry for that, but i'm an Apple lover :D) is MASM-compatible but
strict in a few places. These purely mechanical, backwards-compatible fixes
were applied:

- **`SCSIUTIL.ASM`**: `REP CMPSB` → `REPE CMPSB` (three occurrences).
  `REP CMPSB` is implicitly `REPE CMPSB` per Intel, but JWASM rejects the
  `REP` form. Same emitted opcode either way.
- **`SCSIUTIL.ASM`**: `MOV SI, BLUESCSI_VENDORID` → `MOV SI, OFFSET BLUESCSI_VENDORID`
  (three occurrences). JWASM requires an explicit `OFFSET` where MASM 5.1
  silently inferred it.
- **`PATCH.ASM`**: data labels `CRTC_31K:` and `CRTC_24K:` lost the trailing
  colon (`CRTC_31K` / `CRTC_24K`). MASM allowed colons on data labels, JWASM
  reserves them for code labels.

These changes are kept local to the build tree; they are not upstreamed and do
not alter behaviour on either assembler.

### Build-system replacement

CaptainYS' original Makefile targets are implemented on top of MASM / LINK /
EXE2BIN / `LAYOUT.EXP` (a custom Phar Lap utility). On macOS we replace them
with:

- **JWASM** (MASM-compatible) in place of MASM + LINK + EXE2BIN
  (JWASM can emit flat binaries directly via `-bin`)
- **`make_fdimagem.py`** — a ~50-line Python equivalent of `LAYOUT.EXP` that
  stamps the assembled binaries at the right offsets inside a 1232 KB blank
  image.

`YSSCBIN.ASM` (the pre-embedded YSSCSICD.SYS binary expressed as `DB`
statements) is kept unchanged from CaptainYS' repository — we reuse the
version that is already committed there.

---

## 4. Building `FDIMAGEM.BIN` From Source on macOS

### Prerequisites

- **macOS** (tested on Darwin 25.x) with the standard developer CLI tools.
- **`git`** for cloning repositories.
- **`gcc` / `clang`** for compiling JWASM.
- **`nasm`** is NOT needed for the IPL itself (JWASM handles everything)
  but is installed for the separate CDMENU.COM toolchain.
- **Python 3** (ships with macOS recent versions) for `make_fdimagem.py`.
- **HxCFloppyEmulator** (GUI app, free) for the final BIN → HFE step.

### Step 1 — Build JWASM from source

```sh
cd /tmp
git clone --depth 1 https://github.com/Baron-von-Riedesel/JWasm.git jwasm
cd jwasm

# macOS fix: malloc.h does not exist on BSD-style systems
# Edit src/H/memalloc.h and guard the <malloc.h> include for __APPLE__
# (the patch just adds !defined(__APPLE__) to the existing #ifndef __FreeBSD__)

make -f GccUnix.mak

# Manually link if the final linker step fails on clang
cd build/GccUnixR && gcc *.o -o jwasm
```

You should end up with a working `jwasm` binary at
`/gitclonetempdir/jwasm/build/GccUnixR/jwasm`. Sanity check:

```sh
/gitclonetempdir/jwasm/build/GccUnixR/jwasm -h | head -3
# JWasm v2.21, ..., Masm-compatible assembler.
```

### Step 2 — Clone CaptainYS' FM repository

```sh
cd /tmp
git clone https://github.com/captainys/FM.git captainys_FM

# Our build expects a flat "TOWNS_ROOT/IPL/" tree. Copy the IPL and its
# sibling libraries to a staging directory:
mkdir -p /gitclonetempdir/captainys_towns_root
cp -r /gitclonetempdir/captainys_FM/TOWNS/IPL       /gitclonetempdir/captainys_towns_root/IPL
cp -r /gitclonetempdir/captainys_FM/TOWNS/SCSILIB   /gitclonetempdir/captainys_towns_root/SCSILIB
cp -r /gitclonetempdir/captainys_FM/TOWNS/RS232C    /gitclonetempdir/captainys_towns_root/RS232C
cp -r /gitclonetempdir/captainys_FM/TOWNS/MISCLIB   /gitclonetempdir/captainys_towns_root/MISCLIB
cp -r /gitclonetempdir/captainys_FM/TOWNS/RESOURCE  /gitclonetempdir/captainys_towns_root/RESOURCE
cp -r /gitclonetempdir/captainys_FM/TOWNS/YSSCSICD  /gitclonetempdir/captainys_towns_root/YSSCSICD
```

### Step 3 — Apply the CD Menu modifications

From the delivered `dist/fmtowns_launcher_v5/` directory, copy the three
patched source files into the IPL directory:

```sh
cp CDSWMENU.ASM   /gitclonetempdir/captainys_towns_root/IPL/
cp MAINMENU.ASM   /gitclonetempdir/captainys_towns_root/IPL/   # overwrites CaptainYS' version
cp LOADER.ASM     /gitclonetempdir/captainys_towns_root/IPL/   # overwrites CaptainYS' version
cp make_fdimagem.py /gitclonetempdir/captainys_towns_root/IPL/
```

Then apply the JWASM-compatibility fixes listed in section 3 to
`SCSIUTIL.ASM` and `PATCH.ASM` (or copy those files from the delivery as
well if you have them).

### Step 4 — Assemble

```sh
cd /gitclonetempdir/captainys_towns_root/IPL

# Build the main loader
/gitclonetempdir/jwasm/build/GccUnixR/jwasm -Zm -bin -Fo=LOADER.BIN LOADER.ASM
# -Zm : MASM 5.1 compatibility (needed for code labels inside PROCs)
# -bin: flat binary output (no EXE header)
# Expected: "LOADER.ASM: 286 lines, 4 passes, N ms, 1 warnings, 0 errors"
# The "Warning A4130" about BUFFERS.ASM segment alignment is harmless.

# Build the floppy IPL boot sector
/gitclonetempdir/jwasm/build/GccUnixR/jwasm -Zm -bin -Fo=FD_IPLM.BIN FD_IPLM.ASM
```

You should now have `LOADER.BIN` (≈28 KB) and `FD_IPLM.BIN` (≈500 bytes).

### Step 5 — Assemble the disk image

```sh
python3 make_fdimagem.py
```

`make_fdimagem.py` produces a 1 261 568-byte `FDIMAGEM.BIN` by stamping the
freshly-built binaries at the offsets CaptainYS' layout uses:

| File          | Offset | Purpose                                   |
|---------------|--------|-------------------------------------------|
| `FD_IPLM.BIN` | `0`    | Floppy IPL boot sector (rescue loader)    |
| `FDFAT.BIN`   | `1024` | FAT table 1                               |
| `FDFAT.BIN`   | `3072` | FAT table 2                               |
| `FDDIR.BIN`   | `5120` | Root directory                            |
| `LOADER.BIN`  | `11264`| The main loader, containing the CD Menu   |

Background is filled with `0x00` bytes to match what CaptainYS' Makefile does.

### Step 6 — Verify

```sh
# Quick sanity checks on the produced binary
grep -ao "FM TOWNS SCSI CD MENU - BY TUGS" LOADER.BIN
grep -ao "CD MENU - SWITCH CD" LOADER.BIN
grep -ao "FMTOWNS RESCUE + CD MENU BY CAPTAINYS AND TUGS" LOADER.BIN
```

All three strings must appear at least once. `LOADER.BIN` is normally between
27 KB and 29 KB depending on the version.

---

## 5. Converting `FDIMAGEM.BIN` to HFE for Gotek / HxC2001

On my FM Towns UX, i used a Gotek as the second floppy drive, so i need to convert .BIN as .HFE format

The BIN is a raw 2HD sector image. The HFE format is what Gotek USB
emulators and HxC floppy emulators understand. Use
[**HxCFloppyEmulator**](http://hxc2001.free.fr/floppy_drive_emulator/) (free
GUI, Mac / Windows / Linux).

### Conversion parameters

```
Source format  : Raw sector image (.bin)
Target format  : HxC HFE File v1.1
RPM            : 360                 ← important on Mac HxC tool
Bit rate       : 500000 bps
Encoding       : MFM
Interface      : Shugart
Track format   : DOS Floppy HxC SDK compatible

Disk geometry  : FM Towns 2HD
  Tracks       : 77 (sides 0 and 1)
  Sides        : 2
  Sectors/track: 8
  Sector size  : 1024 bytes
  Total size   : 77 × 2 × 8 × 1024 = 1 261 568 bytes

First Track / sector numbering:
  First track  : 0
  First side   : 0
  First sector : 1
```

### HxCFloppyEmulator steps

1. `File → Load raw file…` → point at `FDIMAGEM.BIN`
2. In the settings dialog pick **FM Towns 2HD (1232 KB)** from the template
   list (or manually enter the geometry above).
3. Set **RPM = 360** (critical; the Gotek spins floppies at 300 RPM by
   default but FM Towns 1232 KB expects 360 RPM and the HFE metadata must
   match).
4. `File → Export → HxC HFE File` → `FDIMAGEM.HFE`
5. Copy the HFE onto the Gotek USB stick.

### Sanity check

Boot the FM Towns with the HFE selected. On a 640×480 screen you should see:

```
FMTOWNS RESCUE + CD MENU BY CAPTAINYS AND TUGS  MACHINE ID: xxxx
VERSION 202x0404a
http://www.ysflight.com
CD DRIVE FOUND AT SCSI ID=03H

                  [ main menu with 6 entries, including CD MENU - SWITCH CD ]
```

---

## 6. Credits & Acknowledgements

A huge, heartfelt **thank you to Soji Yamakawa (CaptainYS)**. None of this
project would exist without the staggering amount of reverse-engineering,
assembly work, patches, and documentation he has poured into the FM Towns
ecosystem over the years. The CD Menu is not a rewrite of anything: it sits
on top of CaptainYS' Rescue IPL and reuses every single display primitive,
every keyboard / pad reader, every SCSI routine, and the whole
`BOOT_FROM_SCSI_CD` pipeline that makes external SCSI boot actually work on
early FM Towns models like the UX.

Specific pieces of CaptainYS' work this project relies on:

- **The FM TOWNS Rescue IPL** (`TOWNS/IPL/*`) — the complete boot loader we
  extend. Everything visual and everything SCSI-related in CD Menu is
  piggy-backing on this code.
- **`YSSCSICD.SYS`** — the SCSI CD driver that redirects FM Towns internal
  CD-ROM BIOS calls to external SCSI, embedded inside the Rescue IPL.
- **The SCSI controller library** (`TOWNS/SCSILIB/SCSIIO.ASM`) — the
  `SCSI_COMMAND` routine used by CD Menu to talk to BlueSCSI without going
  through `INT 93H`.
- **Game patches** in `TOWNS/PATCHES/` — `RAINBOW`, `RAIDEN`, `AFTBRN3`,
  `ALONE`, `CHASEHQ`, `GF2`, `KyukyokuTiger`, `PUYOPUYO`, `RocketRanger`
  and friends. These binary patches make games that talk directly to the
  internal CD-ROM I/O actually play their CDDA tracks when booted via an
  external SCSI CD, and their accompanying dual-boot IPL lets you chain-
  boot patched CDs without any floppy at all. The workflow of this entire
  hobby setup — from patching Rainbow Islands to selecting it from a menu —
  is CaptainYS' work end to end.
- **Tsugaru** — CaptainYS' FM Towns emulator, indispensable for testing
  before committing changes to real hardware.
- The detailed write-ups at <https://ysflight.in.coocan.jp/FM/towns/>
  that explain how FM Towns boots from CD, how the internal CD-ROM
  controller works, the IPL4 signature, the BIOS hidden functions, and
  countless other things that are nowhere else to be found.

Thanks as well to:

- **Eric Helgeson** and the **BlueSCSI** project for the wonderful hardware
  and for exposing a clean vendor-opcode API (COUNT_CDS / LIST_CDS /
  SET_NEXT_CD) that makes menu-driven CD switching feasible at all.
- **nabe-abk** for `flatlink` (used during the TSTSCSI*.COM prototyping
  phase), `free386`, and the FM Towns development documentation.
- **Baron von Riedesel** for maintaining **JWASM**, without which there
  would be no way to build CaptainYS' MASM sources on macOS.

---

*Project: FM Towns CD Menu — integrates into CaptainYS' Rescue IPL.
Built with JWASM + Python on macOS, tested on a Fujitsu FM Towns UX with a
BlueSCSI v2 Desktop + S/PDIF Audio Link module.*
