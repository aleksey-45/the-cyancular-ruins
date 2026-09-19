# -*- coding: utf-8 -*-
"""生成《焚毁的诺顿》(Burnt Norton)时空地图 .cyrt
用法: python editor/make_burnt_norton.py  → map/burnt_norton.cyrm→.cyrt
150×100 大图(比标准 125×75 大 60%),w0=600s(10 分钟),事件按诗的五乐章编排。"""
import random

random.seed(1942)  # 《四个四重奏》四诗合刊年
COLS, ROWS = 150, 100
g = [[0] * COLS for _ in range(ROWS)]


def put(x, y, tex, shape=15):
    if 0 <= x < COLS and 0 <= y < ROWS:
        g[y][x] = tex * 16 + shape


def rect(x0, y0, x1, y1, tex):
    for y in range(y0, y1 + 1):
        for x in range(x0, x1 + 1):
            put(x, y, tex)


def clear(x0, y0, x1, y1):
    for y in range(y0, y1 + 1):
        for x in range(x0, x1 + 1):
            if 0 <= x < COLS and 0 <= y < ROWS:
                g[y][x] = 0


def hollow(x0, y0, x1, y1, tex):
    for x in range(x0, x1 + 1):
        put(x, y0, tex)
        put(x, y1, tex)
    for y in range(y0, y1 + 1):
        put(x0, y, tex)
        put(x1, y, tex)


def blob(cx, cy, rx, ry, tex_fn):
    for dy in range(-ry, ry + 1):
        for dx in range(-rx, rx + 1):
            if (dx * dx) / (rx * rx + .1) + (dy * dy) / (ry * ry + .1) <= 1.0:
                if random.random() < 0.88:
                    put(cx + dx, cy + dy, tex_fn())


leaves = lambda: random.choice([15, 16, 17, 18])

# ── 边界与大地 ──
rect(0, 0, 1, ROWS - 1, 2)
rect(COLS - 2, 0, COLS - 1, ROWS - 1, 2)
rect(0, 0, COLS - 1, 1, 2)
rect(0, 88, COLS - 1, ROWS - 1, 2)          # 地表
rect(28, 84, 58, 87, 2)                      # 西侧花园高地
rect(112, 84, 144, 87, 2)                    # 东侧庄园台地

# ── 记忆的走廊(地面下的隧道,足音回荡处)──
clear(10, 82, 44, 85)                        # 隧道本体
clear(12, 86, 13, 87)                        # 西入口竖井(从地表落入)
clear(42, 86, 43, 87)                        # 东出口竖井

# ── 玫瑰园:三棵巨树(干 19 / 冠叶)──
for tx in (30, 42, 54):
    rect(tx, 46, tx + 1, 83, 19)
    blob(tx + 1, 38, 6, 5, leaves)
# 空中玫瑰园将在此上空由事件生成(T-540)

# ── 玫瑰丛与荆棘(叶纹指代:16=玫瑰丛 17=荆棘 18=落瓣)──
for bx in range(22, 60, 3):                        # 花园高地上的玫瑰丛带
    bh = random.randint(1, 2)
    for y in range(84 - bh, 84):
        for x in range(bx, min(bx + 2, 60)):
            put(x, y, 16 if random.random() < 0.72 else 17)
for x in range(66, 89):                            # 静止点塔基的荆棘环
    put(x, 87, 17)
for _ in range(26):                                # 空中飘散的落瓣
    put(random.randint(20, 62), random.randint(24, 78), 18)
# 枯藤(锁链 12上/13中/14下)自庄园断裂的屋顶垂下——可攀爬
for vx in (104, 112, 120, 128, 136):
    top = random.randint(54, 58)
    vlen = random.randint(7, 14)
    for i in range(vlen):
        put(vx, top + i, 12 if i == 0 else (14 if i == vlen - 1 else 13))

# ── 静止点之塔(中央,光的中心)──
hollow(70, 30, 84, 86, 1)
for y in range(31, 86):                      # 塔内爬梯
    put(77, y, 11)
for wx, wy in ((72, 44), (82, 52), (71, 66), (83, 74)):  # 窗
    clear(wx, wy, wx + 1, wy + 1)
rect(68, 28, 86, 29, 1)                      # 塔顶环台

# ── 干涸前的水池(阳光蓄水)──
clear(78, 88, 104, 95)
rect(78, 96, 104, 99, 2)                     # 池底混凝土
rect(79, 88, 103, 94, 21)                    # 水(表层自动派生水面)

# ── 从未打开的门:东北密室 ──
hollow(100, 18, 122, 30, 1)
for gx, gy in ((106, 22), (110, 25), (115, 21)):        # 阳光碎片
    put(gx, gy, 10)

# ── 焚毁的庄园(东南,黑色焦痕)──
hollow(100, 52, 144, 87, 7)
rect(100, 66, 144, 67, 8)                    # 二层地板
clear(110, 66, 112, 67)
clear(130, 66, 132, 67)
rect(100, 79, 144, 80, 8)                    # 一层地板
clear(118, 79, 120, 80)
clear(138, 79, 140, 80)
for px in (108, 116, 124, 132, 140):         # 廊柱
    rect(px, 68, px, 78, 7)
clear(100, 82, 101, 85)                      # 西门洞
for _ in range(60):                          # 焦痕
    put(random.randint(102, 143), random.randint(53, 86), 8)

# ── 浮岛群(通往密室与高处的路径)──
for _ in range(9):
    ix, iy = random.randint(18, 140), random.randint(20, 48)
    put(ix, iy, 19)
    blob(ix, iy - 2, 3, 2, leaves)

# ── 输出 ──
EVENTS = [
    ("# tl-w0: 600", None),
    ("# tl: 585 gen 26 18 34 26 tex=15 rev=1 玫瑰先行萌发:绿色枝叶在空中铺展(序)", None),
    ("# tl: 540 gen 26 16 34 30 tex=16 rev=1 玫瑰盛开:丛丛玫瑰在空中浮现,笑语盈盈(第一乐章)", None),
    ("# tl: 528 spawn_enemy 40 30 type=fly_bird count=3 rev=1 「去吧,去吧,去吧」鸟说:人类无法承受太多现实", None),
    ("# tl: 450 collapse 10 80 36 7 rev=1 未走的走廊在身后封闭:足音沉入记忆", None),
    ("# tl: 384 open 100 21 1 8 rev=1 从未打开的门轰然洞开:往玫瑰园去", None),
    ("# tl: 360 spawn_enemy 111 24 type=black_bird count=1 rev=1 隐去,隐入尘世的喧嚣——黑鸟掠过密室", None),
    ("# tl: 300 wipe 91 91 7 dmg=35 rev=1 水池干涸:阳光蓄满的水化作混凝土(第三乐章)", None),
    ("# tl: 240 gen 69 26 17 3 tex=7 rev=1 静止点:光的中心在塔顶冉冉升起(第四乐章)", None),
    ("# tl: 180 explode 70 22 6 dmg=55 kb=320 rev=1 在无时间之处,时间之外——一阵强光炸开", None),
    ("# tl: 120 collapse 26 16 34 30 rev=1 回望花园:玫瑰凋零,树叶散尽,笑声止息", None),
    ("# tl: 90 spawn_enemy 40 60 type=fly_bird count=4 rev=1 鸟群离去,升入旋转世界的静点", None),
    ("# tl: 30 wipe 75 55 20 dmg=70 rev=0 终末:焚毁诺顿(不可逆——一切终将安然", None),
]

lines = ["# cyrt-v1", "# player 6 82",
         "# enemy jump_bird 130 62", "# enemy fly_bird 60 36"]
lines += [e[0] for e in EVENTS]
for row in g:
    lines.append("".join("%03d%s" % (c // 16, "0123456789ABCDEF"[c % 16]) for c in row))

out = "\n".join(lines) + "\n"
open("map/burnt_norton.cyrt", "w", encoding="utf-8", newline="\n").write(out)
mx = max(max(r) for r in g)
print("burnt_norton.cyrt:", COLS, "x", ROWS, "| 最大 packed 值:", mx, "(<336 ✓)" if mx < 336 else "越界!")
print("行数:", len(lines), "| 事件数:", len([e for e in EVENTS if e[0].startswith("# tl:")]))
