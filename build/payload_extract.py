"""Extract partitions from the payload.bin of a full A/B OTA zip.

usage: payload_extract.py <ota.zip> <outdir> <partition> [<partition> ...]
"""
import bz2
import hashlib
import lzma
import os
import struct
import sys
import zipfile

try:
    from compression import zstd as _zstd
except ImportError:
    _zstd = None


def varint(buf, i):
    shift = val = 0
    while True:
        b = buf[i]
        i += 1
        val |= (b & 0x7F) << shift
        if b < 0x80:
            return val, i
        shift += 7


def fields(buf):
    i = 0
    while i < len(buf):
        key, i = varint(buf, i)
        num, wt = key >> 3, key & 7
        if wt == 0:
            v, i = varint(buf, i)
        elif wt == 1:
            v = buf[i:i + 8]; i += 8
        elif wt == 2:
            ln, i = varint(buf, i)
            v = buf[i:i + ln]; i += ln
        elif wt == 5:
            v = buf[i:i + 4]; i += 4
        else:
            raise ValueError(f"unsupported wire type {wt}")
        yield num, wt, v


def parse_extent(b):
    start = num = 0
    for n, _, v in fields(b):
        if n == 1: start = v
        elif n == 2: num = v
    return start, num


def parse_op(b):
    op = {"type": 0, "off": 0, "len": 0, "dst": []}
    for n, _, v in fields(b):
        if n == 1: op["type"] = v
        elif n == 2: op["off"] = v
        elif n == 3: op["len"] = v
        elif n == 6: op["dst"].append(parse_extent(v))
    return op


def parse_partition(b):
    p = {"name": None, "ops": [], "size": None, "hash": None}
    for n, _, v in fields(b):
        if n == 1: p["name"] = v.decode()
        elif n == 8: p["ops"].append(parse_op(v))
        elif n == 7:
            for n2, _, v2 in fields(v):
                if n2 == 1: p["size"] = v2
                elif n2 == 2: p["hash"] = v2
    return p


def decompress(t, data):
    if t == 0: return data
    if t == 1: return bz2.decompress(data)
    if t == 8: return lzma.decompress(data)
    if t == 14:
        if _zstd is None:
            raise RuntimeError("zstd needs Python >= 3.14")
        return _zstd.decompress(data)
    raise RuntimeError(f"operation {t} not supported (incremental OTA?)")


def main():
    ota, outdir, wanted = sys.argv[1], sys.argv[2], set(sys.argv[3:])
    os.makedirs(outdir, exist_ok=True)
    with zipfile.ZipFile(ota) as z, z.open("payload.bin") as f:
        magic, ver, msize = struct.unpack(">4sQQ", f.read(20))
        if magic != b"CrAU" or ver != 2:
            sys.exit("unsupported payload.bin")
        sigsize = struct.unpack(">I", f.read(4))[0]
        manifest = f.read(msize)
        base = 24 + msize + sigsize
        block = 4096
        parts = []
        for n, _, v in fields(manifest):
            if n == 3: block = v
            elif n == 13: parts.append(parse_partition(v))
        missing = wanted - {p["name"] for p in parts}
        if missing:
            sys.exit(f"not in payload: {' '.join(sorted(missing))}")
        for p in parts:
            if p["name"] not in wanted:
                continue
            path = os.path.join(outdir, p["name"] + ".img")
            with open(path, "wb") as out:
                out.truncate(p["size"])
                for op in p["ops"]:
                    if op["type"] in (6, 7):
                        continue
                    f.seek(base + op["off"])
                    data = decompress(op["type"], f.read(op["len"]))
                    pos = 0
                    for start, num in op["dst"]:
                        out.seek(start * block)
                        out.write(data[pos:pos + num * block])
                        pos += num * block
            if hashlib.sha256(open(path, "rb").read()).digest() != p["hash"]:
                sys.exit(f"{p['name']}: sha256 mismatch")
            print(f"{p['name']}.img OK")


if __name__ == "__main__":
    main()
