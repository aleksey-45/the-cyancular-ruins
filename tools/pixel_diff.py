#!/usr/bin/env python3
"""逐像素比对两张截图。

用法:
    python tools/pixel_diff.py <A.png> <B.png> [--threshold 0.004] [--out diff.png]

输出格式:
    DIFF <n> / <total>    n 为通道差超过阈值的像素数（0 表示完全一致）
    MAXDELTA <d>          d 为全部像素中单通道最大差值（0-255 整数）
    SIZE MISMATCH <Wa>x<Ha> vs <Wb>x<Hb>   图像尺寸不匹配

阈值说明:
    单像素计算 RGBA 四通道差值的最大值，并除以 255 归一化。
    例如 --threshold 0.004 允许单通道差值在 1 以内，容忍 PNG 编解码的微小浮点误差，
    同时覆盖 RGB 与 Alpha 通道的实质性变动。

差异输出:
    --out 可选输出差异可视化图片，将逐像素差值放大 16 倍并高亮标红，便于人工排查。
"""

import sys

from PIL import Image, ImageChops


def _parse_threshold(raw):
    """解析 --threshold 参数值。若输入非合法数字则打印错误提示并返回 None。"""
    try:
        v = float(raw)
    except ValueError:
        print("用法错误:--threshold 要一个数字,实得「%s」" % raw)
        return None
    # 过滤 NaN 值，防止判断恒为假导致误判通过
    if v != v:
        print("用法错误:--threshold 不能是 nan(那会让每个像素都被判成没超阈值,即假绿)")
        return None
    return v


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
            threshold = _parse_threshold(args[i])
            if threshold is None:
                return 1
        elif a.startswith("--threshold="):
            threshold = _parse_threshold(a.split("=", 1)[1])
            if threshold is None:
                return 1
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

    # 计算逐通道绝对差，取 RGBA 四通道中的最大值（包含 Alpha 通道差异）
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
