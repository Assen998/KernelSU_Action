#!/usr/bin/env python3
"""Repack an MTK-style Android boot image with a new kernel blob.

MediaTek kernel boot images use an 8-byte "ANDROID!" magic instead of
AOSP's 16-byte magic field, which shifts every header field by -8 bytes.
The stock AOSP unpack_bootimg.py therefore misparses MTK images (it reads
the ramdisk size as the kernel size, etc.).

MTK header layout (verified against a real MT6853 / cannon image):
    0x00  magic "ANDROID!" (8 bytes)
    0x08  kernel_size
    0x0C  kernel_addr
    0x10  ramdisk_size
    0x14  ramdisk_addr
    0x18  second_size
    0x1C  second_addr
    0x20  tags_addr
    0x24  page_size
    0x28  image_size / os_version (vendor-written, not significant)
    0x30  name[16]
    0x40  cmdline[512]
    -> header total 0x240, payload starts at the first page-aligned offset
       (0x800 for page_size 2048), then: kernel, ramdisk, both page-aligned.

This repacker:
  1. validates the MTK header (kernel/ramdisk must be gzip at the
     expected file offsets),
  2. swaps in a new kernel blob of arbitrary size,
  3. keeps the original header (updating kernel_size), ramdisk, cmdline,
     name, and all load addresses,
  4. writes the result with the sequential layout MTK bootloaders expect.

Usage:
    mtk_boot_repack.py --source boot.img --kernel Image.gz --output boot.img
"""

import argparse
import struct
import sys

MAGIC = b"ANDROID!"
HDR_SIZE = 0x240  # 8 + 40 + 16 + 512
VALID_PAGES = (512, 1024, 2048, 4096, 8192, 16384)


def u32(data, off):
    return struct.unpack_from("<I", data, off)[0]


def page_align(v, page):
    return ((v + page - 1) // page) * page


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--source", required=True, help="original MTK boot image")
    ap.add_argument("--kernel", required=True, help="new kernel blob (e.g. Image.gz)")
    ap.add_argument("--output", required=True, help="output boot image")
    a = ap.parse_args()

    try:
        src = open(a.source, "rb").read()
        newk = open(a.kernel, "rb").read()
    except OSError as e:
        sys.exit(f"cannot read input: {e}")

    if src[:8] != MAGIC:
        sys.exit(f"not an Android boot image (magic {src[:8]!r})")
    if len(src) < HDR_SIZE:
        sys.exit(f"source shorter than header ({len(src)} bytes)")
    if not newk:
        sys.exit("new kernel blob is empty")

    ks, ka = u32(src, 0x08), u32(src, 0x0C)
    rs, ra = u32(src, 0x10), u32(src, 0x14)
    tags, page = u32(src, 0x20), u32(src, 0x24)

    if page not in VALID_PAGES:
        sys.exit(f"implausible page_size {page}")
    if ks == 0 or rs == 0:
        sys.exit(f"zeroed kernel/ramdisk size (ks={ks}, rs={rs}); "
                 "is this really an MTK boot image?")

    k0 = page_align(HDR_SIZE, page)
    k1 = k0 + ks
    r0 = page_align(k1, page)

    if src[k0:k0 + 2] != b"\x1f\x8b":
        sys.exit(f"kernel at {k0:#x} is not gzip (magic {src[k0:k0+4].hex()}); "
                 "unexpected MTK header layout")
    if r0 + rs > len(src):
        sys.exit("ramdisk extends beyond end of file; unexpected layout")
    if src[r0:r0 + 2] != b"\x1f\x8b":
        sys.exit(f"ramdisk at {r0:#x} is not gzip (magic {src[r0:r0+4].hex()}); "
                 "unexpected MTK header layout")

    ramdisk = src[r0:r0 + rs]
    cmdline = src[0x40:HDR_SIZE].split(b"\x00")[0].decode(errors="replace")

    out = bytearray()
    out += MAGIC
    hdr_fields = bytearray(src[8:48])          # the 10 u32 fields
    struct.pack_into("<I", hdr_fields, 0, len(newk))
    out += hdr_fields
    out += src[48:64]                          # name[16]
    out += src[64:HDR_SIZE]                    # cmdline[512]
    out += b"\x00" * (k0 - HDR_SIZE)           # header padding
    out += newk
    out += b"\x00" * (page_align(k0 + len(newk), page) - (k0 + len(newk)))
    out += ramdisk

    with open(a.output, "wb") as f:
        f.write(bytes(out))

    print(f"repacked boot image:")
    print(f"  page_size   : {page}")
    print(f"  kernel      : {len(newk)} bytes (was {ks}), load addr 0x{ka:x}")
    print(f"  ramdisk     : {len(ramdisk)} bytes, load addr 0x{ra:x}")
    print(f"  tags addr   : 0x{tags:x}")
    print(f"  cmdline     : {cmdline}")
    print(f"  output size : {len(out)} bytes")


if __name__ == "__main__":
    main()
