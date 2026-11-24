"""Replace the kernel of a v3/v4 boot.img, keeping its header and ramdisk.

usage: boot_swap_kernel.py <boot.img> <Image.gz> <out.img>
"""
import struct
import sys

PAGE = 4096


def pad(n):
    return (PAGE - n % PAGE) % PAGE


def main():
    src, kernel_path, dst = sys.argv[1:4]
    img = open(src, "rb").read()
    if img[:8] != b"ANDROID!":
        sys.exit(f"{src}: not an Android boot image")
    kernel_size, ramdisk_size = struct.unpack_from("<2I", img, 8)
    header_version = struct.unpack_from("<I", img, 40)[0]
    if header_version not in (3, 4):
        sys.exit(f"{src}: header v{header_version} not supported")

    ramdisk_off = PAGE + kernel_size + pad(kernel_size)
    ramdisk = img[ramdisk_off:ramdisk_off + ramdisk_size]
    sig = b""
    if header_version == 4:
        sig_size = struct.unpack_from("<I", img, 1580)[0]
        sig_off = ramdisk_off + ramdisk_size + pad(ramdisk_size)
        sig = img[sig_off:sig_off + sig_size]

    kernel = open(kernel_path, "rb").read()
    header = bytearray(img[:PAGE])
    struct.pack_into("<I", header, 8, len(kernel))

    with open(dst, "wb") as out:
        out.write(header)
        for blob in (kernel, ramdisk, sig):
            if blob:
                out.write(blob)
                out.write(b"\0" * pad(len(blob)))


if __name__ == "__main__":
    main()
