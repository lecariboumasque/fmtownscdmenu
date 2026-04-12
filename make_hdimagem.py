#!/usr/bin/env python3
"""
Build HDIMAGEM.BIN — bootable HD image with CD Menu.

From the CaptainYS Makefile:
  DISKIMG\HDIMAGE.BIN : BUILD\HD_IPL0.BIN BUILD\HD_IPL.BIN BUILD\LOADER.BIN BUILD\LAYOUT.EXP
      LAYOUT DISKIMG\HDIMAGE.BIN 1025 HD_IPL0.BIN 0 HD_PTAB.BIN 512 HD_0108.BIN 1040
      LAYOUT DISKIMG\HDIMAGE.BIN OVERWRITE HD_IPL.BIN 1536 HD_F9FF.BIN 2048
      LAYOUT DISKIMG\HDIMAGE.BIN OVERWRITE HD_FAT.BIN 2560 HD_FAT.BIN 5632
      LAYOUT DISKIMG\HDIMAGE.BIN OVERWRITE LOADER.BIN 16896
"""
import os

SIZE_KB = 1025
SIZE_BYTES = SIZE_KB * 1024  # 1,049,600

def place(image, path, offset):
    with open(path, 'rb') as f:
        data = f.read()
    image[offset:offset + len(data)] = data
    print(f"  placed {path} ({len(data)} bytes) at offset {offset}")

def main():
    os.chdir(os.path.dirname(os.path.abspath(__file__)))

    print(f"Building HDIMAGEM.BIN ({SIZE_BYTES} bytes = {SIZE_KB} KB)")
    image = bytearray(b'\x00' * SIZE_BYTES)

    # Step 1: initial layout
    place(image, 'HD_IPL0.BIN', 0)
    place(image, 'HD_PTAB.BIN', 512)
    place(image, 'HD_0108.BIN', 1040)

    # Step 2: overwrite
    place(image, 'HD_IPL.BIN', 1536)
    place(image, 'HD_F9FF.BIN', 2048)

    # Step 3: FAT tables
    place(image, 'HD_FAT.BIN', 2560)
    place(image, 'HD_FAT.BIN', 5632)

    # Step 4: main loader (with CD Menu)
    place(image, 'LOADER.BIN', 16896)

    with open('HDIMAGEM.BIN', 'wb') as f:
        f.write(image)
    print(f"Wrote HDIMAGEM.BIN ({len(image)} bytes)")

if __name__ == '__main__':
    main()
