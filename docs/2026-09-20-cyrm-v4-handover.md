# `.cyrm` v4 游戏侧交接文档

日期:2026-09-20
写给:接手游戏侧改造的人(用户本人)
来源:编辑器侧 `core.js` 已实现并验证完毕(`node smoke.js` 343 通过 / 0 失败),规格见
`docs/superpowers/specs/2026-09-19-cyrm-v4-editor-design.md`,实现计划见
`docs/superpowers/plans/2026-09-19-cyrm-v4-core-format.md`。

> ★ **本文档的断言边界**:格式规格、字节布局、取角规则、迁移规则 —— 这些是**已实现且被 343 条断言验证**的,可放心照做。
> 游戏侧各文件"要改什么"是**读代码得出的**,**我没有跑过任何 Godot 代码**。凡是推断而非实证的,文中都标了"推断"。

---

## 0. 一页速览

| | 旧(v3) | 新(v4) |
|---|---|---|
| 文件形态 | 文本,每格 4 字符 | **二进制**,明文头 20 字节 + deflate body |
| 格 | 64px,2×2 子格(32px) | 64px,**4×4 子格(16px)** |
| 每格内容 | 一个纹理 + 4 位形状掩码 | 每子格一个 32 位描述符(纹理 + 四种颜色辅码) |
| 图层 | 1 层 | **4 层**(前景 / 场景 / 后景 / 背景) |
| 碰撞 | 全图 | **只有「场景」层** |

**你要动的最小集合**(推断,详见 §4):

```
core/sim/map_format.gd          二进制解析替换 v3 文本  ← 必改
core/sim/collision_builder.gd   2×2 → 4×4,子格 250×150 → 500×300
scenes/level_0.gd               ★ atlas 方案必须换(见 §4.3)
core/sim/tile_defs.gd           逐子格破坏
core/sim/grid_pathfinder.gd     取决于 §3 那个决策
```

---

## 1. `.cyrm` v4 字节级规格

### 1.1 文件布局(明文头,不压缩)

| 偏移 | 大小 | 字段 | 说明 |
|---|---|---|---|
| 0 | 4 | magic | `"CYRM"` = `43 59 52 4D` |
| 4 | 1 | version | `4` |
| 5 | 1 | compression | `0` = 无,`1` = deflate(zlib / RFC1950) |
| 6 | 4 | body_size | u32 小端,**解压后** body 的字节数 |
| 10 | 4 | body_crc32 | u32 小端,**解压后** body 的 CRC32(IEEE,多项式 `0xEDB88320`) |
| 14 | 2 | sub_cols | u16 小端,16px 子格列数 = 格数 × 4 |
| 16 | 2 | sub_rows | u16 小端,16px 子格行数 = 格数 × 4 |
| 18 | 1 | layer_flags | bit0..3 = 前景 / 场景 / 后景 / 背景 是否存在 |
| 19 | 1 | reserved | 固定 0(解码端目前忽略,可前向兼容) |
| 20 | … | body | `compression=1` 时整段是 deflate 流 |

★ **`body_size` 与 `body_crc32` 都是针对解压后的 body** —— 这是最容易写反的一处。写反的症状是"解压出来长度对不上"。
★ **所有多字节整数小端。**

### 1.2 body 布局(解压后)

```
u16   meta_len
      meta_utf8      meta_len 字节的 UTF-8 文本
然后按 layer_flags 从 bit0 到 bit3 的顺序,每个"存在"的层一个块
```

**meta 文本就是今天那几行 `#` 注释**,形状不变:

```
# 说明性注释(任意多行,原样保留)
# player  3 4
# player2 10 4
# player3 20 8          ← 第 3 个及以后:编辑器会写,你的解析器可以忽略
# enemy  fly_bird 20 12
```

★ **好消息**:`MapFormat.parse_spawn_metadata()` **零改动可用**。你只要把 meta 文本按 `\n` 切开丢给它就行。
★ **spawn 坐标仍以 64px 格为单位**(不是子格)。你现有的出生点/地板判定/敌人布点全在格级,不用缩放。
★ **已知归一化**(别假设 meta 能逐字节还原):编辑器会把注释的空白规范化(`#   foo  ` → `# foo`),空注释行会变成 `# `,且**注释统一排在 spawn 行之前**。内容不丢,顺序与空白会变。
★ **已知丢弃**:spawn 行**末尾的多余 token 会被吃掉**(`# player 3 4 start` → `# player 3 4`)。真实地图不会这么写。

### 1.3 纹理层块(kind = 1)—— 前景 / 场景 / 后景

```
u8    kind = 1
u16   palette_count            调色板条目数
      palette_count × u32      描述符,小端
u8    index_width              1 或 2
      sub_cols × sub_rows × index_width 字节    行主序(下标 = y * sub_cols + x)
```

- **索引 0 恒为描述符 0(空气)** —— 即使本层一个空气格都没有也占着第 0 位。于是"空层 = 1 项调色板 + 全 0 索引流"是**无条件成立**的不变量,解码端不需要任何特判。
- `palette_count ≤ 256` 时 `index_width = 1`,否则 `2`。解码端按写着的值读。
- **调色板逐层独立。**

### 1.4 背景层块(kind = 2)

```
u8    kind = 2
      sub_cols × sub_rows × 4 字节    0xRRGGBBAA,行主序
```

**没有调色板** —— 背景是真彩,平滑渐变交给 deflate 压。

★ **磁盘上的字节序是 `AA BB GG RR`(alpha 在前)**,因为值是按 u32 小端写的。**你必须按小端 u32 解包**:

```gdscript
var v := f.get_32()                     # 小端读
var r := (v >> 24) & 0xFF
var g := (v >> 16) & 0xFF
var b := (v >>  8) & 0xFF
var a :=  v        & 0xFF
```

若按 `[R,G,B,A]` 位置去读,整层颜色全错(且不报错)。

### 1.5 描述符(descriptor)位域

**纹理层**每个 16px 子格存一个 32 位无符号整数,`0` = 空气:

```
bit  0- 2   hue          0-7
bit  3- 5   brightness   0-7
bit  6- 8   saturation   0-7
bit  9-11   alpha        0-7
bit 12-23   texture      1-4095   (0 = 空气)
bit 24-31   保留,固定 0
```

**中性描述符 = `(hue 4, bright 4, sat 4, alpha 7)`** = 原图不改一点。迁移产生的全部是这个值。

★ **三列的中性档不在同一行**:hue / brightness / saturation 的中性在**档 4**,alpha 的中性在**档 7**。

### 1.6 压缩

- `compression = 1` 用 **deflate(zlib 格式,RFC 1950)** 覆盖整个 body。
- Godot 侧:`PackedByteArray.decompress(body_size, FileAccess.COMPRESSION_DEFLATE)`,或 `FileAccess.get_file_as_bytes` + `decompress`。
- ★ **编辑器侧已用 Node 的 `zlib.inflateSync` 独立解过自己的流并逐字节比对通过** —— 这是能在编辑器侧拿到的最强验证,但仍**不能**证明 Godot 读得进。见 §6.1。

---

## 2. 两端必须一致的两处数学

这两处如果不一致,表现都是**画面对不上但不报错**。

### 2.1 取角映射(§2.2 规范定义)

```
子格全局坐标 (X, Y),X ∈ [0, sub_cols), Y ∈ [0, sub_rows)
令 qx = X % 4,  qy = Y % 4
若该子格纹理为 T(1-22),则:
  从 structure.png 取 T 的源图块(32px)中第 (qx, qy) 个 8px 象限
  放大 2× 画到该子格的 16px 位置
```

**一个 64px 格里 16 个子格填同一种纹理 → 拼回完整 32px 源图放大 2×,与旧版 `shape=15` 逐像素相同。** 这条已被编辑器侧的"精确铺满"断言证明(3×3 格 × 4 象限全查,且做过变异验证)。

★ **象限由子格在格内的位置决定,不是存在数据里的字段** —— 因为每个子格可以有自己的纹理,它必须能独立推出自己该画哪一块。
★ 编辑器侧已用**手工从规格推导的 golden 字节向量**钉住字节序,但那只保证文件写得对;**shader/渲染实现是否符合这条映射,只能在游戏侧验**。

### 2.2 辅码 tint 公式

```
输入:源像素 (r, g, b) ∈ [0,1],源 alpha a ∈ [0,1],描述符 (H, B, S, A)
1. (h, s, v) = RGB_to_HSV(r, g, b)        // ★ 是 HSV 不是 HSL
2. h' = fposmod(h + (H - 4) * 15, 360)
3. s' = clamp(s * SAT_MUL[S], 0, 1)
4. v' = clamp(v * BRI_MUL[B], 0, 1)
5. (r', g', b') = HSV_to_RGB(h', s', v')
6. a' = a * (A / 7)
输出:(r', g', b', a')
```

| 档 | hue 偏移 | brightness/saturation 乘数 | alpha |
|---|---|---|---|
| 0 | −60° | ×0.6 | 0 |
| 1 | −45° | ×0.7 | 1/7 |
| 2 | −30° | ×0.8 | 2/7 |
| 3 | −15° | ×0.9 | 3/7 |
| **4** | **0°** | **×1.0** | 4/7 |
| 5 | +15° | ×1.1 | 5/7 |
| 6 | +30° | ×1.2 | 6/7 |
| 7 | +45° | ×1.3 | **1(原色)** |

★ hue 的 8 档**不对称**(−60°…+45°),这是设计如此(−60° 等价于 +300°)。
★ brightness/saturation 是**乘法**不是加法(用户裁定):暗部不会被压成纯黑,中性档(4)恰好是恒等元。
★ **是 HSV 的 S 与 V,不是 HSL**。这条不一致,编辑器里调好的颜色进游戏就变样。

---

## 3. ★★ 头号决策:`current_grid` 用哪一级

**这是整个游戏侧改造里最大的分叉,必须你先拍板,后面的改动清单才成立。**

现状:地图格 = 64px,`MazeGenerator.current_grid` 是**格级**二维数组(如 125×75),全项目 **20 个文件**在读它:

```
core/sim/    beam_trace.gd      explosion.gd        grid_pathfinder.gd
             map_format.gd      maze_generator.gd   spawn_picker.gd
             tile_defs.gd       tile_query.gd       water.gd
             world_builder.gd
scenes/      effects/water_fx.gd
             enemies/enemy_base.gd  enemy_black_bird.gd  enemy_fly_base.gd
             level_0.gd
             player/climb_component.gd  player.gd  player/swim_component.gd
             pvp_match_client.gd
             weapons/bullet_base.gd
```

而 v4 的数据是**子格级**的(500×300 = 格数 × 4)。三个选项:

### 选项 A —— `current_grid` 保持格级,另加一张子格网格

- 20 个调用方**零改动**(`is_blocked` / `is_floor_cell` / A* / LOS / 水 / 攀爬判定全部照旧)。
- 需要一个**降采样规则**:一个 64px 格怎样算"可走"。建议"该格 16 个子格中,覆盖玩家身体走廊的那几个" —— 但这就是新的设计,得你定。
- 碰撞与渲染读子格网格;逻辑读格级网格。
- **代价最小,但引入"两套网格可能不一致"的长期维护面。**

### 选项 B —— `current_grid` 直接变成子格级(500×300)

- 语义统一,没有降采样规则要发明。
- **20 个文件全部要重新定标**:A* 的节点数 ×16、`toroidal_dist` 的单位从格变子格、`is_floor_cell` 的"正下方一格"变成 16px、水面的列扫描、攀爬的格判定、子弹的 `cell_of`……
- ★ **性能**:`GridPathfinder.astar_path_nearest` 有 `max_visit` 上限(当前 4000),在 16 倍节点数下要么调大(更慢)要么更频繁地走直线兜底。

### 选项 C —— 双网格并存

- 逻辑用格级、渲染/碰撞用子格级,但**明确**把两张网格都建出来并规定谁是权威。
- 比 A 多一份内存与一次同步,换来"降采样规则只在一处"。

**我的建议(仅供参考):先按 A 做。** 理由是 v4 引入 16px 精度的**直接目的是美术表现**(砖缝、台阶、细边),不是玩法精度;而 20 个调用方逐一重新定标是**风险远大于收益**的改动面。等 A 跑起来、确认真有玩法需要 16px 精度时,再单独立项做 B。

★ **有一条必须想清楚的**:旧版 `TileDefs.damage_tile(cell, …)` 是按**格**拆的。v4 里子弹打中的是**子格**。若走选项 A,你要决定"打掉一个子格算不算打掉整格"(按 hp 表是逐格存的)。这是 A 选项下**唯一**真正需要新设计的点。

---

## 4. 逐文件改动清单

### 4.1 `core/sim/map_format.gd` —— 二进制解析(必改)

现在的 `load_map_file` / `map_size` / `load_spawns` / `read_lines` 全是文本路径。需要:

- 新增 `load_binary(path)`:`FileAccess.get_file_as_bytes` → 读 20 字节头 → 校验 magic / version / 尺寸 4 的倍数 → 必要时 `decompress(body_size, COMPRESSION_DEFLATE)` → 校验 CRC32 → 解析 body。
- **保留** `parse_spawn_metadata(lines)`(它现在吃 meta 文本,零改动)。
- **保留** v3 文本路径作为**只读迁移入口**(现有 `maps/*.cyrm` 转完就可以删,但转换脚本要用)。
- `map_size()` 要改成读二进制头(或先解出 body 看一眼)。

★ **已有的防御照抄过来**:编辑器侧已经在 `decodeMap` 里做了这些检查,建议逐条对齐 —— 坏 magic / 未知版本 / CRC 不符 / 尺寸为 0 / 尺寸非 4 的倍数 / `body_size` 与解压后长度不符 / 短于 20 字节 / 未知 compression / **头部声明的尺寸超过 body 余量**(防"坏头部触发巨量分配")/ **`body_size` 上限 + 解压输出上限**(防 deflate 炸弹)。最后两条是真事:编辑器侧实测过一个畸形头部会触发 **17GB 分配且真的分配成功**,也实测过去掉上界后炸弹**完整解出 65MB**。

### 4.2 `core/sim/collision_builder.gd` —— 2×2 → 4×4

- `SUB_TS` 从 32 变 **16**;`build_sub` 的展开循环从 `for qy in 2 / for qx in 2` 变 **4×4**,子格网格从 250×150 变 **500×300**。
- 位序:`shape & (1 << (qy * 4 + qx))`(**注意是 ×4 不是 ×2**)。
- `CHUNK_CELLS = 12` 是按 √125 推的,尺寸变了要重算(推断:√500 ≈ 22)。
- `_greedy_region` / `_instantiate` 的 9 环面副本逻辑**完全不用动**。
- `build_climb_ledges` 的 `LEDGE_THICKNESS = 6` 与 `TILE_TS` 仍是格级,**不用动**。
- ★ **只有「场景」层进碰撞**。前/后/背景三层一律不产生碰撞体。

### 4.3 `scenes/level_0.gd` —— ★ 最容易低估的一处

**头号风险:`_create_wall_tileset()` 现在预生成「16 形状 × 22 纹理」的 atlas。**
若把形状掩码理解成 16 位,那就是 **65536 形状 ⇒ 预生成 atlas 这条路直接死掉**(65536 × 22 × 64×64 像素 ≈ 6GB)。

**好消息是"取角"模型救回来了**:每个 16px 子格渲染成 `(纹理, 象限)` 组合,atlas 只需要 **22 × 16 = 352 张 16px 小图**(排成 16 列 × 22 行 = 256×352 像素)。**根本不需要形状掩码。**

要做的事(推断):
- `_create_wall_tileset` 改成建 **352 张 16px tile**(或直接用一张 256×352 的 atlas),tile 坐标 = `(象限, 纹理-1)`。
- `_paint_maze` 改成铺 **16px 子格**:对每个非空子格 `set_cell(子格坐标, source, Vector2i(qx, qy))`,其中 `qx = X % 4, qy = Y % 4`。
- **9 环面副本照旧**(逻辑不变,只是坐标单位变子格)。
- **四层各有自己的渲染层**,顺序:背景 → 后景 → 场景 → (玩家/敌人) → 前景。★ 前景在后还是在前**你需要定**(见 §5)。
- `_paint_water` 的水面派生逻辑现在是格级的(`above = grid[posmod(y-1, rows)][x]`)—— 在子格网格上要重新定义"上方非液体"。
- `_on_tile_destroyed` 现在清一格 2×2 子格 → 变 4×4。
- `reset_destructibles` 的整体重铺逻辑不变,但单位变子格。

★ **格子实例数会涨**:每层 500×300 × 9 副本 = 1.35M 格。实际铺贴量取决于非空格比例(旧版是 125×75 × 9 = 84k 的 15% 左右)。**这是最需要实测的一项**,建议先拿一张真实地图量 `set_cell` 后的节点/内存占用再决定要不要优化。

### 4.4 `core/sim/tile_defs.gd` —— 逐子格破坏

- `init_hp(grid)` / `hp_grid` / `damage_tile(cell, amount, source)` 全是**格级**的。
- 走选项 A 的话,这里要新增**子格级**的破坏路径,并定义"打掉子格 → 整格 hp 怎么扣"。
- `TileDefs.type_of(texture)` / `is_blocked` / `is_liquid` 等**纹理级**函数**完全不用动**(纹理号含义没变)。

### 4.5 `core/sim/grid_pathfinder.gd` —— 取决于 §3

- 它**无会话状态**,网格全部由调用方传入 ⇒ 改动量完全取决于你选 A 还是 B。
- 选 A:**零改动**。
- 选 B:`toroidal_dist` 的单位、`is_floor_cell` 的"正下方"、`astar_path_nearest` 的 `max_visit`(4000,在 16× 节点数下要重新评估)全要重定标。

### 4.6 其余受影响的文件

以下文件的改动**与 §3 的决策绑定**(选 A 则多数零改动),此处只列它们与网格的关系(推断):

| 文件 | 关系 |
|---|---|
| `core/sim/water.gd` | `surface_y_at` 按列向上扫最顶液体格 —— 格级语义 |
| `core/sim/tile_query.gd` | `topmost_solid_row` —— 格级 |
| `core/sim/beam_trace.gd` | DDA 走 32px 子格(注释说"64px 格 → 2×2 形状掩码")⇒ 若碰撞子格变 16px,这里的步长与语义要重新对齐 |
| `core/sim/explosion.gd` | AoE 的 LOS 走 `has_line_of_sight` —— 格级 |
| `core/sim/spawn_picker.gd` | `open_floor_cells` 判据是 `is_floor_cell_with_headroom` —— 格级 |
| `core/sim/world_builder.gd` | `build_sim` 的编排点,跟着 `collision_builder` 走 |
| `scenes/player/{climb,swim}_component.gd` | 攀爬/游泳的格判定 —— 格级 |
| `scenes/enemies/enemy_*.gd` | 飞行寻路用 `_bird_can_pass` + A* —— 格级 |
| `scenes/weapons/bullet_base.gd` | `cell_of` 命中判定 —— 格级 |

★ **`beam_trace.gd` 请优先看**:它的 `SUB_TS = 32` 注释明确写了"64px 格 → 2×2 形状掩码",而 v4 的碰撞子格是 16px。若 §3 选 A(格级网格不变),它可能可以不动;选 B 则必动。

---

## 5. 未决事项(需要你拍板)

1. **★★ §3 的 `current_grid` 级别(A / B / C)** —— 其它所有改动都以它为前提。
2. **四层的渲染顺序,特别是「前景」相对玩家在哪里。** 前景是"在玩家之前"还是"只在场景之前"?这决定它能不能做遮挡。
3. **spawn 协议是否扩到任意多出生点。** 游戏侧 `parse_spawn_metadata` 只认 `player` / `player2`;编辑器**允许**放任意多个并在导出时警告(不阻止)。第 3 个及以后目前是被**静默忽略**的。
4. **纹理 22(水面)的语义。** 编辑器调色板里 21/22 都有,但游戏只把 21 当水体、22 靠 `_paint_water` 自动派生 ⇒ 编辑器里画 22 和游戏里看到的不一样。
5. **旧字母路径的尺寸约束**(编辑器侧已收紧要偶数且 ≥2;游戏侧 `MapFormat.convert_old_grid` 仍是 `Math.floor(h/2)` 静默截断)。
6. **`MapFormat.pack` 与 v4 描述符的关系** —— 旧函数返回 `texture*16+shape`,v4 是完全不同的 32 位编码。建议**保留旧函数仅用于 v3 迁移路径**,不要试图让它兼容两套。

---

## 6. 已验证的风险与验证手段

### 6.1 ★ deflate 两端兼容性 —— 游戏侧第一件必做的事

**这是整个格式的头号风险,而它只能在游戏侧证伪。** 编辑器侧已经用 Node 的 `zlib.inflateSync` 独立解过自己的流(即"另一个实现能读我们的流"),但**Godot 的 `COMPRESSION_DEFLATE` 读不读得进,没人验过**。

**做法**:拿一份编辑器导出的真 `.cyrm`,在 Godot 里:

```gdscript
var bytes := FileAccess.get_file_as_bytes(path)
# 读头 → 取 body_size / body_crc32 → decompress → 逐字节比 CRC
```

对不上先试 `compression = 0`(编辑器导出面板上有「压缩」勾选框,取消即导裸 body)。**`compression=0` 是一条完整可用的路径,不是半成品。**

### 6.2 编辑器侧已实现的防御(建议逐条对齐)

| 防御 | 为什么需要(实测依据) |
|---|---|
| 头部尺寸 vs body 余量 | 畸形头部(CRC 只覆盖 body、不覆盖头)实测触发 **17GB 分配,而且真的分配成功**(没有 RangeError 兜底) |
| `body_size` 上限,在解压**之前** | 声明的尺寸也是攻击者可控的 |
| 解压**输出**上限(流式累计) | 去掉上界后实测炸弹**完整解出 65MB**;`body_size` 谎报小值也拦不住 |
| CRC32 校验 | 上面两条都只防"大",CRC 才防"错" |

### 6.3 迁移正确性的证明基础

旧图迁移后**视觉逐像素不变**,这一点在编辑器侧被证明过:旧版 2×2 掩码的每个 32px 象限,恰好被新版 2×2 个 16px 子格**精确铺满**(尺寸相等 + 包围盒相等 ⇒ 不重不漏),源矩形同样。3×3 格 × 4 象限全查,并做过变异验证。

★ 但请注意它**只证了两个映射函数的几何一致**,不覆盖"游戏侧 shader 是否照 §2.1 实现" —— 那是 §2.1 存在的理由。

---

## 7. 编辑器侧已实现的公开 API(参考)

`level_editor/core.js`(978 行,DOM-free,`node smoke.js` 343 条断言全绿)。游戏侧不需要引它,但**它定义了规范**,有疑问时以它为准:

```
常量      SUB_PER_CELL=4  SUB_PX=16  CELL_PX=64  TEXTURE_MAX=4095
          DESC_AIR=0  LAYER_FRONT/SCENE/BACK/BG   LAYER_NAMES  LAYER_KINDS
          FORMAT_VERSION=4  MAX_BODY_SIZE(64MB)
          MAX_CELLS_W=400  MAX_CELLS_H=300  HUE/BRI/SAT/ALPHA_NEUTRAL
描述符    packDesc / texOf / hueOf / brightOf / satOf / alphaOf / isAir / neutralDesc
          ★ isAir(d) 是严格 d===0,只对本编码器产出的数据可靠;
            读外来文件时唯一的空气判据是 texOf(d) === 0
地图      createMap / cellsWOf / cellsHOf / subIndex
字节      ByteWriter / ByteReader / crc32
层块      encodeTexLayer / decodeTexLayer / encodeColorLayer / decodeColorLayer
meta      buildMeta / parseMeta
容器      encodeMap / decodeMap(均为 async)/ deflateBytes / inflateBytes / layerFlags
v3        isV3Text / parseV3Text / _v3Pack / _v3TexOf / _v3ShapeOf
迁移      subcellRender / migrateV3
校验      validateMap / clampMapSize
工具      sanitizeName / brushOffsets / lineCells / normRegion
```

★ **`decodeMap` 的保证清单**(它的注释里写全了):保证头部合理性、body 长度精确、CRC 相符、body 全消费、索引与调色板边界。**不**保证:调色板[0] 是空气、纹理 ≤22、尺寸在编辑器上限内、`0 ≡ 空气` 的不变量。前者是"读得进",后者要你自己判。

---

## 8. 一句话收尾

**格式是冻结的、字节级的、有 343 条断言和若干次变异验证撑着的。** 你真正要花时间想的只有一件:**§3 那个 `current_grid` 的级别** —— 它决定了这次改造是"改 3 个文件"还是"改 20 个文件"。其余都是照着 §1/§2 的规格写解析器。
