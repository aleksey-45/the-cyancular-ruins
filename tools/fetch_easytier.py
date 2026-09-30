#!/usr/bin/env python3
"""下载 EasyTier 的 Windows 版并把两个 exe 放到仓库根(与游戏 exe 同目录)。

为什么由**这个脚本**下载,而不是游戏自己下载:
  · 发布版关掉了 mbedtls(`cyancular_build_profile.gdbuild` 的 `module_mbedtls_enabled: false`),
    引擎里**没有 TLS** —— 连不上 GitHub 的 https。开发态能连,发布版不能,写进游戏就是
    "开发机上好好的、发出去就下载失败";
  · 这两个 exe 是**可选的第三方组件**,不该进导出产物(见 export_presets 的 include_filter),
    下载/分发是构建期的事。

许可:EasyTier 是 **LGPL-3.0**(不是 AGPL)。本仓以**独立进程**方式调用它的官方 exe,
不静态链接、不改它的源码,故不触发 LGPL §4 的"组合作品"条款。分发时随包附上 LICENSE。

用法:
    python tools/fetch_easytier.py              # 缺什么下什么
    python tools/fetch_easytier.py --force      # 重新下
    python tools/fetch_easytier.py --dest DIR   # 换目标目录(默认仓库根)
"""
import argparse
import os
import shutil
import sys
import urllib.request
import zipfile

# ★ 版本号从 core/config/tunnel_meta.gd 读 —— 那是**唯一来源**,游戏侧的命令行参数与这里的
#   下载地址必须指同一版。手抄第二份的后果是"下载的版本与参数不匹配",而它**不报错**。
TOOLS = os.path.dirname(os.path.abspath(__file__))
PROJECT = os.path.dirname(TOOLS)
META = os.path.join(PROJECT, "core", "config", "tunnel_meta.gd")
WANTED = ("easytier-core.exe", "easytier-cli.exe")


def read_meta() -> dict:
    out = {}
    with open(META, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line.startswith("const ") or ":=" not in line:
                continue
            name, _, rest = line[len("const "):].partition(":=")
            out[name.strip()] = rest.strip().strip('"')
    missing = [k for k in ("ET_VERSION", "CORE_EXE", "CLI_EXE", "RELEASE_URL", "LICENSE_URL")
               if k not in out]
    if missing:
        sys.exit("读不到 %s 里的 %s —— 版本号/资产名的唯一来源就是它,别在这里另写一份"
                 % (os.path.relpath(META, PROJECT), ", ".join(missing)))
    return out


def download(url: str, dst: str) -> None:
    print("== 下载 %s" % url)
    tmp = dst + ".part"
    with urllib.request.urlopen(url, timeout=120) as r, open(tmp, "wb") as f:
        shutil.copyfileobj(r, f)
    os.replace(tmp, dst)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dest", default=None, help="目标目录(默认仓库根:与游戏 exe 同目录)")
    ap.add_argument("--force", action="store_true", help="已存在也重新下载")
    args = ap.parse_args()
    dest = args.dest or PROJECT
    os.makedirs(dest, exist_ok=True)

    meta = read_meta()
    have = [n for n in WANTED if os.path.isfile(os.path.join(dest, n))]
    if len(have) == len(WANTED) and not args.force:
        print("== EasyTier %s 已就位(%s),跳过" % (meta["ET_VERSION"], ", ".join(have)))
        print("   许可 LGPL-3.0:%s" % meta["LICENSE_URL"])
        return

    version = meta["ET_VERSION"]
    url = meta["RELEASE_URL"] % (version, version)
    zip_path = os.path.join(dest, "easytier-%s.zip" % version)
    download(url, zip_path)
    print("== 解包到 %s" % dest)
    # ★★ **整包解压**,不是只挑两个 exe:`easytier-core.exe` 静态导入 `Packet.dll`,
    #   少了它的表现是**进程根本起不来**(Windows 报 0xC0000135、stdout/stderr 一个字节都没有)
    #   —— 那在客户端侧看起来与"打洞失败"一模一样。2026-09-29 实测踩到过一次。
    with zipfile.ZipFile(zip_path) as z:
        for info in z.infolist():
            base = os.path.basename(info.filename)
            if not base or info.is_dir():
                continue
            with z.open(info) as src, open(os.path.join(dest, base), "wb") as dst:
                shutil.copyfileobj(src, dst)
    os.remove(zip_path)
    missing = [n for n in WANTED if not os.path.isfile(os.path.join(dest, n))]
    if missing:
        sys.exit("解包后仍缺 %s —— 资产结构可能变了,检查 %s" % (", ".join(missing), url))

    # 许可全文:分发 LGPL 组件必须随附(见文件头)。
    lic = os.path.join(dest, "easytier-LICENSE.txt")
    try:
        download(meta["LICENSE_URL"], lic)
        print("   已附许可全文 %s" % os.path.relpath(lic, PROJECT))
    except Exception as e:                      # 网络抖动不该让整个下载算失败
        print("   ! 许可全文没下下来(%s),请手动补一份:%s" % (e, meta["LICENSE_URL"]))

    print("== 完成:EasyTier %s(LGPL-3.0)→ %s" % (version, dest))


if __name__ == "__main__":
    main()
