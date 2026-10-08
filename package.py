#!/usr/bin/env python3
# QingSplitPOC — 纯 Python 打包 .deb（不依赖 dpkg-deb / theos）
# 方法借鉴 QingSplit4A 仓库 package.py（rootless var/jb 布局，iphoneos-arm64e）
# 与 qingsplit-probe 探针管线 1:1 复用，仅改包名/文件名

import os, io, tarfile, lzma, time

BASE = os.path.dirname(os.path.abspath(__file__))

def find_dylib():
    candidates = [
        os.path.join(BASE, "QingSplitPOC.dylib"),
        os.path.join(BASE, ".theos", "obj", "debug", "QingSplitPOC.dylib"),
        os.path.join(BASE, ".theos", "obj", "debug", "arm64", "QingSplitPOC.dylib"),
        os.path.join(BASE, ".theos", "obj", "QingSplitPOC.dylib"),
    ]
    for c in candidates:
        if os.path.exists(c):
            return c
    for root, dirs, files in os.walk(BASE):
        if ".theos" in root or ".git" in root:
            continue
        for f in files:
            if f == "QingSplitPOC.dylib":
                return os.path.join(root, f)
    return None

PLIST_SRC = os.path.join(BASE, "QingSplitPOC.plist")
PREFS_SRC = os.path.join(BASE, "QingSplitPrefs.plist")
PREFS_BUNDLE_DIR = os.path.join(BASE, "QingSplitPrefs.bundle")
CONTROL_SRC = os.path.join(BASE, "control")
OUT = os.path.join(BASE, "QingSplitPOC_0.4.56_iphoneos-arm64e.deb")

DYLIB_DEST = "var/jb/Library/MobileSubstrate/DynamicLibraries/QingSplitPOC.dylib"
PLIST_DEST = "var/jb/Library/MobileSubstrate/DynamicLibraries/QingSplitPOC.plist"
# v0.4.44: 恢复 executable（诊断结论：PreferenceLoader 只注册带 isController 的条目；白屏在 controller 层）
# A/B 结论：静态无-controller 版在 Shuffle 聚合不显示 → 必须 bundle+executable；白屏用 QingSplitPrefs.log 定位
PREFS_DEST = "var/jb/Library/PreferenceLoader/Preferences/QingSplitPrefs.plist"
PREFS_BUNDLE_ROOT_DEST = "var/jb/Library/PreferenceBundles/QingSplitPrefs.bundle/Root.plist"
PREFS_BUNDLE_EXE_DEST = "var/jb/Library/PreferenceBundles/QingSplitPrefs.bundle/QingSplitPrefs"
PREFS_BUNDLE_INFO_DEST = "var/jb/Library/PreferenceBundles/QingSplitPrefs.bundle/Info.plist"
PREFS_BUNDLE_TARGETS_DEST = "var/jb/Library/PreferenceBundles/QingSplitPrefs.bundle/Targets.plist"
PREFS_BUNDLE_BEHAVIOR_DEST = "var/jb/Library/PreferenceBundles/QingSplitPrefs.bundle/QingSplitBehavior.plist"

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
            ti.mtime = int(time.time())
            ti.uid = 0; ti.gid = 0
            tf.addfile(ti)
        else:
            if isinstance(content, bytes):
                data = content
            else:
                data = open(content, "rb").read()
            ti = tarfile.TarInfo(arcname)
            ti.size = len(data)
            ti.mode = mode
            ti.mtime = int(time.time())
            ti.uid = 0; ti.gid = 0
            tf.addfile(ti, io.BytesIO(data))
    tf.close()
    return lzma.compress(buf.getvalue(), format=lzma.FORMAT_XZ)

def main():
    DYLIB_SRC = find_dylib()
    if not DYLIB_SRC:
        print("[!] 未找到 dylib（QingSplitPOC.dylib）")
        return 1
    print(f"[*] dylib 路径: {DYLIB_SRC}")
    if not os.path.exists(PLIST_SRC):
        print(f"[!] 未找到 plist: {PLIST_SRC}")
        return 1
    if not os.path.exists(CONTROL_SRC):
        print(f"[!] 未找到 control: {CONTROL_SRC}")
        return 1

    dylib = open(DYLIB_SRC, "rb").read()
    print(f"[*] dylib size = {len(dylib)}")
    if dylib[:4] not in (b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xfe\xed\xfa\xcf"):
        print("[!] 警告：dylib 头部不是 Mach-O magic，可能路径不对！")
        return 1

    files = [
        ("var/jb/", None, True, 0o755),
        ("var/jb/Library/", None, True, 0o755),
        ("var/jb/Library/MobileSubstrate/", None, True, 0o755),
        ("var/jb/Library/MobileSubstrate/DynamicLibraries/", None, True, 0o755),
        (DYLIB_DEST, dylib, False, 0o755),
        (PLIST_DEST, PLIST_SRC, False, 0o644),
        ("var/jb/Library/PreferenceLoader/", None, True, 0o755),
        ("var/jb/Library/PreferenceLoader/Preferences/", None, True, 0o755),
        (PREFS_DEST, PREFS_SRC, False, 0o644),
        ("var/jb/Library/PreferenceBundles/", None, True, 0o755),
        ("var/jb/Library/PreferenceBundles/QingSplitPrefs.bundle/", None, True, 0o755),
        (PREFS_BUNDLE_ROOT_DEST, os.path.join(PREFS_BUNDLE_DIR, "Root.plist"), False, 0o644),
        (PREFS_BUNDLE_EXE_DEST, os.path.join(PREFS_BUNDLE_DIR, "QingSplitPrefs"), False, 0o755),
        (PREFS_BUNDLE_INFO_DEST, os.path.join(PREFS_BUNDLE_DIR, "Info.plist"), False, 0o644),
        (PREFS_BUNDLE_TARGETS_DEST, os.path.join(PREFS_BUNDLE_DIR, "Targets.plist"), False, 0o644),
        (PREFS_BUNDLE_BEHAVIOR_DEST, os.path.join(PREFS_BUNDLE_DIR, "QingSplitBehavior.plist"), False, 0o644),
    ]
    data_xz = tar_xz_from_files(files)

    ctrl_files = [("control", CONTROL_SRC, False, 0o644)]
    ctrl_xz = tar_xz_from_files(ctrl_files)

    deb = b"!<arch>\n"
    deb += ar_member("debian-binary", b"2.0\n")
    deb += ar_member("control.tar.xz", ctrl_xz)
    deb += ar_member("data.tar.xz", data_xz)

    open(OUT, "wb").write(deb)
    print(f"[*] 已生成 {OUT}  ({len(deb)} bytes)")
    print("[*] 架构标签 iphoneos-arm64e，rootless 布局（var/jb/ 前缀）")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
