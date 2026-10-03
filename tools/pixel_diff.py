#!/usr/bin/env python3
"""逐像素比对两张截图 —— 「迁移 = 外观不变」那条判据的量尺。

用法:
    python tools/pixel_diff.py <A.png> <B.png> [--threshold 0.004] [--out diff.png]

输出(一律给**文本**,本仓纪律:退出码从来不是判据,调用方 grep `DIFF 0 /`):
    DIFF <n> / <total>    n = 通道差超过阈值的像素数(=0 才算不变)
    MAXDELTA <d>          d = 全部像素里**单通道**最大差的 0~255 整数(定位量级用)
    SIZE MISMATCH <Wa>x<Ha> vs <Wb>x<Hb>   尺寸不同 ⇒ 直接判失败

★ 阈值语义:单像素取 R/G/B **三通道差里的最大者**,再除以 255 归一。故 `--threshold 0.004`
  等价于"单通道差 > 1.02 才算一个不同像素" —— 容掉 PNG 编解码的 ±1 抖动,又不放过真正的
  alpha 混合差异(2 及以上一律计入)。

★ `--out` 是可选的**人眼定位**产物:逐像素差放大 16 倍后贴在 B 图上,超阈值处涂红。
  它不参与判据 —— 判据永远只有上面那行 DIFF 文本。
"""

import sys

from PIL import Image, ImageChops


def main(argv):
    args = argv[1:]
    if "--help" in args or "-h" in args or len(args) < 2:
        print(__doc__.strip())
        return 0 if ("--help" in args or "-h" in args) else 1

    threshold = 0.004
    out_path = None
    positional = []
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--threshold":
            i += 1
            if i >= len(args):
                print("用法错误:--threshold 缺参数")
                return 1
            threshold = float(args[i])
        elif a.startswith("--threshold="):
            threshold = float(a.split("=", 1)[1])
        elif a == "--out":
            i += 1
            if i >= len(args):
                print("用法错误:--out 缺参数")
                return 1
            out_path = args[i]
        elif a.startswith("--out="):
            out_path = a.split("=", 1)[1]
        else:
            positional.append(a)
        i += 1

    if len(positional) != 2:
        print("用法错误:要两个 PNG 路径,实得 %d 个" % len(positional))
        return 1

    pa, pb = positional
    try:
        ia = Image.open(pa).convert("RGBA")
        ib = Image.open(pb).convert("RGBA")
    except Exception as exc:                                    # noqa: BLE001
        print("读图失败: %s" % exc)
        return 1

    if ia.size != ib.size:
        print("SIZE MISMATCH %dx%d vs %dx%d"
              % (ia.size[0], ia.size[1], ib.size[0], ib.size[1]))
        return 1

    # 逐通道绝对差,取三通道(RGB)最大者 —— alpha 差也计入(遮罩半透明处最容易漂)。
    diff = ImageChops.difference(ia, ib)
    bands = list(diff.split())
    max_band = bands[0]
    for b in bands[1:]:
        max_band = ImageChops.lighter(max_band, b)

    hist = max_band.histogram()
    total = ia.size[0] * ia.size[1]
    max_delta = max(i for i, c in enumerate(hist) if c) if total else 0
    cut = threshold * 255.0
    over = sum(c for v, c in enumerate(hist) if v > cut)

    print("DIFF %d / %d" % (over, total))
    print("MAXDELTA %d" % max_delta)

    if out_path:
        # 可视化:差放大 16 倍贴在 B 上,超阈值像素涂红(便于人眼定位,不参与判据)。
        vis = ib.convert("RGB")
        if over:
            amp = max_band.point(lambda v: min(255, v * 16))
            tint = Image.merge("RGB", (amp, Image.new("L", amp.size, 0),
                                       Image.new("L", amp.size, 0)))
            vis = ImageChops.lighter(vis, tint)
        vis.save(out_path)
        print("OUT %s" % out_path)

    return 0 if over == 0 else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
