"""P1 前后取图逐像素对比（一次性量具）。

用法：python p1_diff.py <before_dir> <after_dir>
判据：打印的 "P1 DIFF: ALL-ZERO" 才是过；"非零 = ..." 时列出差异镜头。
阈值：单像素 RGB 差之和 > 30 记为变化（与 P0 审计同一口径）。
"""
import os
import sys

import numpy as np
from PIL import Image


def load(d, n):
    return np.asarray(Image.open(os.path.join(d, n)).convert("RGB")).astype(int)


# 已知不稳定区(逐镜头):主菜单左下角版本号含 git 提交数,并行会话一提交就变 —— 与版式无关。
MASKS = {
    "main_sp_panel.png": [(0, 1380, 260, 1440)],
}


def main():
    if len(sys.argv) != 3:
        print("USAGE: python p1_diff.py <before_dir> <after_dir>")
        return 2
    before, after = sys.argv[1], sys.argv[2]
    lines = []
    names = sorted(n for n in os.listdir(before) if n.endswith(".png"))
    if not names:
        print("P1 DIFF: FAIL before 目录没有 png")
        return 2
    total = 0
    bad = []
    for n in names:
        pa = os.path.join(after, n)
        if not os.path.exists(pa):
            print(f"{n:26s} MISSING(after)")
            bad.append(n)
            continue
        a, b = load(before, n), load(after, n)
        if a.shape != b.shape:
            print(f"{n:26s} SIZE {a.shape} vs {b.shape}")
            bad.append(n)
            continue
        diff = np.abs(a - b)
        for (x0, y0, x1, y1) in MASKS.get(n, []):
            diff[y0:y1, x0:x1] = 0
        changed = int((diff.sum(axis=2) > 30).sum())
        total += changed
        if changed:
            bad.append(n)
        print(f"{n:26s} changed_px={changed:8d} mean_abs={diff.mean():7.4f}")
    lines.append(f"P1 DIFF: shots={len(names)} total_changed={total} nonzero={len(bad)}")
    if bad:
        print("P1 DIFF: NONZERO = " + ", ".join(bad))
        return 1
    print("P1 DIFF: ALL-ZERO")
    return 0


if __name__ == "__main__":
    sys.exit(main())
