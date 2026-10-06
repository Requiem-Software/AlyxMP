"""Dev: list / extract files from a Valve VPK (v1 or v2, single file or chunked *_dir.vpk).

  python tools/vpk.py list  PATH_dir.vpk [substring]
  python tools/vpk.py get   PATH_dir.vpk OUTDIR name1 [name2 ...]
"""
import os
import struct
import sys


def index(dir_path):
    f = open(dir_path, "rb")
    sig, ver = struct.unpack("<II", f.read(8))
    if sig != 0x55AA1234:
        raise ValueError("not a VPK")
    tree = struct.unpack("<I", f.read(4))[0]
    header = 28 if ver == 2 else 12
    f.seek(header)
    data = f.read(tree)
    entries, i = {}, 0

    def rs():
        nonlocal i
        j = data.index(b"\0", i)
        s = data[i:j].decode("utf-8", "replace")
        i = j + 1
        return s

    while True:
        ext = rs()
        if not ext:
            break
        while True:
            path = rs()
            if not path:
                break
            while True:
                fn = rs()
                if not fn:
                    break
                crc, pre, arc, off, ln, term = struct.unpack("<IHHIIH", data[i:i + 18])
                i += 18
                preload = data[i:i + pre]
                i += pre
                name = (f"{path}/{fn}.{ext}" if path.strip() not in ("", " ") else f"{fn}.{ext}")
                entries[name] = (arc, off, ln, preload, header + tree)
    return entries


def read(dir_path, entry):
    arc, off, ln, preload, dataoff = entry
    if arc == 0x7FFF:
        f = open(dir_path, "rb")
        f.seek(dataoff + off)
        return preload + f.read(ln)
    chunk = dir_path.replace("_dir.vpk", f"_{arc:03d}.vpk")
    f = open(chunk, "rb")
    f.seek(off)
    return preload + f.read(ln)


if __name__ == "__main__":
    mode, vpk = sys.argv[1], sys.argv[2]
    idx = index(vpk)
    if mode == "list":
        sub = sys.argv[3] if len(sys.argv) > 3 else ""
        for n in sorted(idx):
            if sub in n:
                print(n)
    else:
        out = sys.argv[3]
        for name in sys.argv[4:]:
            if name not in idx:
                print("missing:", name)
                continue
            dst = os.path.join(out, name.replace("/", os.sep))
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            open(dst, "wb").write(read(vpk, idx[name]))
            print("extracted", name)
