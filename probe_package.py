#!/usr/bin/env python3
# SwitcherProbe 打包脚本（macOS runner 无 dpkg-deb，纯 Python 构建 deb）
# 复用 QingSplit package.py 的 ar/tar 逻辑，rootless var/jb 布局

import os, io, tarfile, lzma, time

BASE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(BASE, "SwitcherProbe_0.1.0_iphoneos-arm64e.deb")

def ar_member(name, data, mode=0o100644):
    mtime = int(time.time())
    hdr = "%-16s%-12d%-6d%-6d%-8o%-10d`\n" % (name, mtime, 0, 0, mode, len(data))
    assert len(hdr) == 60, f"ar header wrong size: {len(hdr)}"
    blob = hdr.encode("latin1") + data
    if len(data) % 2:
        blob += b"\n"
    return blob

def tar_xz_from_files(files):
    buf = io.BytesIO()
    tf = tarfile.open(fileobj=buf, mode="w")
    for arcname, content, is_dir, mode in files:
        if is_dir:
            ti = tarfile.TarInfo(arcname)
            ti.type = tarfile.DIRTYPE
            ti.mode = mode
            tf.addfile(ti)
        else:
            ti = tarfile.TarInfo(arcname)
            ti.size = len(content)
            ti.mode = mode
            tf.addfile(ti, io.BytesIO(content))
    tf.close()
    return buf.getvalue()

def tar_xz_from_dir(dirpath, prefix):
    files = []
    for root, dirs, fs in os.walk(dirpath):
        rel = os.path.relpath(root, dirpath)
        if rel != ".":
            arc = prefix + "/" + rel.replace(os.sep, "/")
            files.append((arc + "/", b"", True, 0o755))
        for f in fs:
            fp = os.path.join(root, f)
            arc = prefix + "/" + (os.path.relpath(fp, dirpath)).replace(os.sep, "/")
            with open(fp, "rb") as fh:
                files.append((arc, fh.read(), False, 0o755 if f == "SwitcherProbe" else 0o644))
    return tar_xz_from_files(files)

def build():
    # deb 布局：rootless var/jb
    data = tar_xz_from_dir(BASE, "")  # placeholder, replaced below
    # 手工构造 data.tar.xz：仅 var/jb/Library/MobileSubstrate/DynamicLibraries/SwitcherProbe.dylib
    dy = open(os.path.join(BASE, "SwitcherProbe.dylib"), "rb").read()
    files = [
        ("var/", b"", True, 0o755),
        ("var/jb/", b"", True, 0o755),
        ("var/jb/Library/", b"", True, 0o755),
        ("var/jb/Library/MobileSubstrate/", b"", True, 0o755),
        ("var/jb/Library/MobileSubstrate/DynamicLibraries/", b"", True, 0o755),
        ("var/jb/Library/MobileSubstrate/DynamicLibraries/SwitcherProbe.dylib", dy, False, 0o755),
    ]
    data_xz = tar_xz_from_files(files)
    ctrl = """Package: com.qingsplit.switcherprobe
Name: QingSplit SwitcherProbe (Phase0 read-only)
Version: 0.1.0
Architecture: iphoneos-arm64e
Description: Read-only Phase0 probe for switcher route. NO state written.
Maintainer: QingSplit
Section: Tweaks
Depends: mobilesubstrate
""".encode()
    ctrl_xz = tar_xz_from_files([
        ("", b"", True, 0o755),
        ("control", ctrl, False, 0o644),
    ])
    deb = ar_member("debian-binary", b"2.0\n") + ar_member("control.tar.gz", ctrl_xz) + ar_member("data.tar.xz", data_xz)
    with open(OUT, "wb") as f:
        f.write(deb)
    print("deb written", OUT, os.path.getsize(OUT))

if __name__ == "__main__":
    build()
