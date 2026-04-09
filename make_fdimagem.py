#!/usr/bin/env python3
"""
Reproduce LAYOUT.EXP + MAKEFILE steps for FDIMAGEM.BIN.

Looking at MAKEFILE lines 161-164:
  RUN386 LAYOUT.EXP FDIMAGEM.BIN 1232 FDFAT.BIN 1024 FDFAT.BIN 3072 FDDIR.BIN 5120
  RUN386 LAYOUT.EXP FDIMAGEM.BIN OVERWRITE FD_IPLM.BIN 0
  RUN386 LAYOUT.EXP FDIMAGEM.BIN OVERWRITE LOADER.BIN 11264

Step 1: create a 1232 KB (1261568 bytes) blank image filled with 0xF6
        (this is what FAT-formatted 2HD disks use as "unformatted" filler),
        then overwrite with FDFAT.BIN @ 1024, FDFAT.BIN @ 3072, FDDIR.BIN @ 5120
Step 2: overwrite with FD_IPLM.BIN @ 0
Step 3: overwrite with LOADER.BIN @ 11264

Final size: 1232 * 1024 = 1261568 bytes
"""
import os
import sys

SIZE_KB = 1232
SIZE_BYTES = SIZE_KB * 1024  # 1261568

def place(image: bytearray, path: str, offset: int):
    with open(path, 'rb') as f:
        data = f.read()
    image[offset:offset + len(data)] = data
    print(f"  placed {path} ({len(data)} bytes) at offset {offset}")

def main():
    script_dir = os.path.dirname(os.path.abspath(__file__))
    os.chdir(script_dir)

    print(f"Building FDIMAGEM.BIN ({SIZE_BYTES} bytes)")
    image = bytearray(b'\x00' * SIZE_BYTES)

    # Step 1: FAT and directory tables
    place(image, 'FDFAT.BIN', 1024)
    place(image, 'FDFAT.BIN', 3072)
    place(image, 'FDDIR.BIN', 5120)

    # Step 2: overwrite IPL sector at offset 0
    place(image, 'FD_IPLM.BIN', 0)

    # Step 3: overwrite LOADER at offset 11264
    place(image, 'LOADER.BIN', 11264)

    # Write output
    with open('FDIMAGEM.BIN', 'wb') as f:
        f.write(image)

    print(f"Wrote FDIMAGEM.BIN ({len(image)} bytes)")

if __name__ == '__main__':
    main()
