# -*- coding: utf-8 -*-
"""生成《焚毁的诺顿》(Burnt Norton)时空地图 .cyrt —— v2 可玩性版
用法: python editor/make_burnt_norton.py  → map/burnt_norton.cyrt

v2 相对 v1 的拓扑修复/强化:
  · 地表全通: 高地改阶梯、玫瑰丛改散点、塔开基座门洞、庄园开东西双门 → 西→东全程可走
  · 双层循环(the way up is the way down): 地面环 + 地下隧道环(四竖井+爬梯贯通)
  · 空中环线: 树冠→浮岛链→塔顶→密室→庄园屋顶→枯藤落地
  · 水池改为浅盆(水 88-93/混凝土底 94-95/隧道 96-98 互不穿透),可游渡
  · 怪物: 地面/隧道/空中/楼层共 10 只 + 事件刷怪
纹理指代(不动引擎): 16=玫瑰丛 17=荆棘 18=落瓣 12/13/14=枯藤 11=梯 21=水
"""
import random

random.seed(1942)
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

# ── 边界与大地(地表 y=87 走廊 / 隧道 y 96-98)──
rect(0, 0, 1, ROWS - 1, 2)
rect(COLS - 2, 0, COLS - 1, ROWS - 1, 2)
rect(0, 0, COLS - 1, 1, 2)
rect(2, 88, COLS - 3, ROWS - 1, 2)          # 大地基底(88-99)

# ── 西侧出生广场(平整,留 2 格头部空间)──
# (默认空地即可,出生点 (6,84))

# ── 玫瑰园高地:三阶台阶上去,台面 y=85 顶 ──
rect(22, 87, 23, 87, 2)                      # 一级台阶
rect(24, 86, 25, 87, 2)                      # 二级台阶
rect(26, 85, 60, 87, 2)                      # 高台主体
rect(58, 86, 59, 87, 2)                      # 东侧二级(重复无害)
rect(60, 87, 61, 87, 2)                      # 东侧一级

# 玫瑰丛:台面散点(每 5 列一簇,可跳越/绕行)
for bx in range(28, 60, 5):
    put(bx, 84, 16)
    if random.random() < 0.5:
        put(bx + 1, 84, 17)
for _ in range(22):                          # 空中飘散的落瓣
    put(random.randint(20, 62), random.randint(30, 80), 18)

# 三棵巨树(干落在高台上)
for tx in (31, 43, 55):
    rect(tx, 46, tx + 1, 84, 19)
    blob(tx, 40, 6, 5, leaves)

# ── 记忆的走廊:地下隧道 y 96-98,横贯全图(与地面构成双 Deck 循环)──
clear(8, 96, 140, 98)
for px in range(20, 140, 14):                # 隧道内立柱(留 3 宽通道)
    rect(px, 96, px, 98, 2)
SHAFTS = [12, 56, 118, 138]                  # 四竖井+爬梯(花园西/东,池东,庄园内)
for sx in SHAFTS:
    clear(sx, 88, sx, 98)
    for y in range(88, 99):
        put(sx, y, 11)                       # 梯贯穿地表→隧道

# ── 静止点之塔(中央;基座东西门洞贯通地面路)──
hollow(70, 30, 84, 86, 1)
clear(70, 79, 71, 87)                        # 西门洞(3 高)
clear(83, 79, 84, 87)                        # 东门洞
for y in range(31, 87):                      # 塔内爬梯
    put(77, y, 11)
for wx, wy in ((72, 44), (82, 52), (71, 66), (83, 74)):  # 窗
    clear(wx, wy, wx + 1, wy + 1)
rect(68, 28, 86, 29, 1)                      # 塔顶环台(空中环线枢纽)
for x in (66, 67, 87, 88):                   # 塔基两侧短荆棘(1 高,可跳)
    put(x, 87, 17)

# ── 蓄水池(浅盆:水 88-93 / 混凝土底 94-95 / 隧道 96-98)──
clear(90, 88, 112, 93)
rect(90, 88, 112, 93, 21)
clear(118, 88, 118, 98)                      # (井位已凿)

# ── 从未打开的门:东北密室 ──
hollow(100, 18, 122, 30, 1)
for gx, gy in ((106, 22), (110, 25), (115, 21)):        # 阳光碎片
    put(gx, gy, 10)

# ── 焚毁的庄园(东南;东西双门贯通,三层可爬)──
hollow(126, 52, 146, 87, 7)
clear(126, 82, 127, 85)                      # 西门洞
clear(145, 82, 146, 85)                      # 东门洞(通向地图东缘)
rect(126, 66, 146, 67, 8)                    # 三层地板
clear(136, 66, 138, 67)
rect(126, 79, 146, 80, 8)                    # 二层地板
clear(130, 79, 132, 80)
for px in (132, 140):                        # 上层廊柱(不挡地面层)
    rect(px, 68, px, 78, 7)
for _ in range(55):                          # 焦痕
    put(random.randint(128, 144), random.randint(53, 86), 8)
# 枯藤(锁链)自断裂屋顶垂下——可攀爬上楼
for vx in (130, 142):
    top, vlen = random.randint(54, 56), random.randint(10, 14)
    for i in range(vlen):
        put(vx, top + i, 12 if i == 0 else (14 if i == vlen - 1 else 13))

# ── 空中浮岛链(两条航线)──
def island(ix, iy):
    put(ix, iy, 19)
    blob(ix, iy - 2, 3, 2, leaves)

for ix, iy in [(50, 34), (60, 30), (66, 27), (92, 24), (96, 22)]:   # 树冠→塔顶→密室
    island(ix, iy)
for ix, iy in [(126, 30), (132, 40), (138, 48)]:                     # 密室→庄园屋顶
    island(ix, iy)

# ── 事件(w0=600,五乐章;坐标对齐 v2 地形)──
EVENTS = [
    "# tl-w0: 600",
    "# tl: 585 gen 26 18 34 26 tex=15 rev=1 玫瑰先行萌发:绿色枝叶在空中铺展(序)",
    "# tl: 540 gen 26 16 34 30 tex=16 rev=1 玫瑰盛开:丛丛玫瑰在空中浮现,笑语盈盈(第一乐章)",
    "# tl: 528 spawn_enemy 40 30 type=fly_bird count=3 rev=1 「去吧,去吧,去吧」鸟说:人类无法承受太多现实",
    "# tl: 450 collapse 8 94 134 6 rev=1 未走的走廊在身后封闭:足音沉入记忆",
    "# tl: 384 open 100 21 1 8 rev=1 从未打开的门轰然洞开:往玫瑰园去",
    "# tl: 360 spawn_enemy 111 24 type=black_bird count=1 rev=1 隐去,隐入尘世的喧嚣——黑鸟掠过密室",
    "# tl: 300 wipe 101 90 6 dmg=35 rev=1 水池干涸:阳光蓄满的水化作混凝土(第三乐章)",
    "# tl: 240 gen 68 24 19 3 tex=7 rev=1 静止点:光的中心在塔顶冉冉升起(第四乐章)",
    "# tl: 180 explode 77 20 6 dmg=55 kb=320 rev=1 在无时间之处,时间之外——一阵强光炸开",
    "# tl: 120 collapse 26 16 34 30 rev=1 回望花园:玫瑰凋零,树叶散尽,笑声止息",
    "# tl: 90 spawn_enemy 40 60 type=fly_bird count=4 rev=1 鸟群离去,升入旋转世界的静点",
    "# tl: 30 wipe 75 55 20 dmg=70 rev=0 终末:焚毁诺顿(不可逆——一切终将安然",
]

ENEMIES = [
    "# enemy jump_bird 34 84",   # 玫瑰园高地
    "# enemy jump_bird 52 84",   # 高地东段
    "# enemy jump_bird 66 86",   # 塔西
    "# enemy jump_bird 96 87",   # 池西缘
    "# enemy jump_bird 115 87",  # 池东缘
    "# enemy jump_bird 133 84",  # 庄园一层
    "# enemy jump_bird 138 77",  # 庄园二层
    "# enemy jump_bird 30 94",   # 地下走廊
    "# enemy fly_bird 45 32",    # 空中航线
    "# enemy black_bird 111 24", # 密室守卫(门开后现身)
]

lines = ["# cyrt-v1", "# player 6 84"] + ENEMIES + EVENTS
for row in g:
    lines.append("".join("%03d%s" % (c // 16, "0123456789ABCDEF"[c % 16]) for c in row))
open("map/burnt_norton.cyrt", "w", encoding="utf-8", newline="\n").write("\n".join(lines) + "\n")

# ── 自检:地表走廊(每列 y 78-87 至少 2 格空气)、隧道净空 ──
blocked = [x for x in range(2, COLS - 2)
           if sum(1 for y in range(78, 88) if g[y][x] == 0) < 2]
tunnel_ok = all(g[y][x] == 0 for x in (30, 70, 100) for y in (96, 97, 98))
print("burnt_norton.cyrt v2:", COLS, "x", ROWS,
      "| 地表堵列:", blocked if blocked else "无",
      "| 隧道净空:", "OK" if tunnel_ok else "FAIL",
      "| 事件:", len([e for e in EVENTS if e.startswith('# tl:')]))
