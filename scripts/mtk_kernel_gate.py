#!/usr/bin/env python3
"""MTK kernel size gate.

MTK LK (the pre-Linux bootloader) inflates the boot image kernel into a
buffer sized at BSP build time for the STOCK kernel. A kernel that inflates
LARGER than the stock one makes LK crash (bootreason=lk_crash) before the
Linux kernel starts -- the device just reboot-loops.

This gate runs after the kernel build:
  * inflates ${kernel}
  * if inflated size > --target: exit 1 (build failed, trim config)
  * if inflated size <  --target: pad with zero bytes to exactly --target
    (covers the "LK expects the exact stock size" variant; trailing zeros
    are ignored by the ARM64 Image), then re-gzips (level 9, mtime 0, no
    filename -- header bytes identical to the stock MTK gzip)

Usage: mtk_kernel_gate.py --kernel Image.gz --target 30740496
"""

import argparse
import gzip
import struct
import sys


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--kernel", required=True, help="kernel blob (gzipped)")
    ap.add_argument("--target", required=True, type=int,
                    help="max/exact inflated size (stock kernel size)")
    a = ap.parse_args()

    raw = open(a.kernel, "rb").read()
    if raw[:2] != b"\x1f\x8b":
        sys.exit(f"kernel blob is not gzip: {raw[:4].hex()}")
    img = gzip.decompress(raw)
    n = len(img)

    print(f"kernel inflated size: {n} (stock target: {a.target})")
    if n > a.target:
        sys.exit(f"kernel is {n - a.target} bytes LARGER than the stock "
                 f"kernel ({a.target}). MTK LK cannot inflate it (its output "
                 f"buffer is sized for the stock kernel) and will crash "
                 f"(bootreason=lk_crash). Remove config options or features "
                 f"until the kernel fits, then rebuild.")

    if n == a.target:
        print("kernel already exactly stock size; nothing to do")
        return

    padded = img + b"\x00" * (a.target - n)
    print(f"padding kernel with {a.target - n} zero bytes -> {a.target}")

    # gzip level 9, mtime 0, no filename: produces the same 10-byte header
    # as the stock MTK image (1f 8b 08 00 00 00 00 00 02 03).
    co = gzip.GzipFile(filename="", mode="wb", fileobj=open(a.kernel, "wb"),
                       compresslevel=9, mtime=0)
    co.write(padded)
    co.close()

    # verify round-trip
    new = open(a.kernel, "rb").read()
    back = gzip.decompress(new)
    assert back == padded, "gzip round-trip mismatch"
    print(f"re-gzipped kernel written: {a.kernel} ({len(new)} bytes compressed)")


if __name__ == "__main__":
    main()
