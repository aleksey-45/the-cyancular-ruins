# 编辑器格式核心层（`level_editor/core/`）

> 本文件记 `level_editor/core/` 的契约、常量与边界。★ 冲突以源码为准，读前先 `grep` 复核。
> 返回索引：[`README.md`](README.md)。

## 1. 分片与加载顺序

- 13 片按**文件名字典序**加载，`NN_` 前缀就是顺序。顺序的真相源是 `level_editor/editor.html` 的
  `<script src>` 列表；node 侧的 `level_editor/loader.js` 从同一处读，不另抄一份。
- `level_editor/worker.js` 的 `importScripts` 列表必须与页面加载的 core 分片**逐项相同**、末尾再加
  `tile_defs.js`（§6.1 的纹理闸必须在真做编码的 worker 侧也成立），`parts_check.js` 守这条。
- 分片在**一个共享作用域**里求值，可直接引用彼此的顶层声明；**顶层名不许重名**，重名即静默覆盖。
- ★ **core/ 是纯逻辑**：不引用任何 DOM API，必须能被 node 直接 `new Function(src)()` 求值。
- 末片恒为 `99_exports.js`：公开 API 表只在它里面。

## 2. 与游戏侧的对应

★ 与 `core/sim/map_format.gd`（游戏侧读取实现）逐字对应的几处：自编解码闭环
（`encodeMap` / `decodeMap` ↔ `MapFormatV4`）、取角映射（§7）、meta 文本形状（§8）、旧格式 2×2 转换（§8）。
**两边改一处必须同步改另一处。**

## 3. `MAX_BODY_SIZE = 64MB`

- 作用对象是「头部声明的解压后大小」，判在**任何解压动作之前**。
- 用在两道闸上，两道都不可省：① `decodeMap` 里比对头部声明的 `body_size`（挡声明侧的炸弹）；
  ② `inflateBytes` 的 `maxBytes`（作用在**实际输出**上，挡「谎报声明 + 真炸弹」）。
- `inflateBytes` 的 `maxBytes` 传的是 `bodySize`，**不是** `MAX_BODY_SIZE`：合法文件的解压结果恒等于
  `body_size`，故 `bodySize` 是精确上界；`MAX_BODY_SIZE` 只是松值。
- 合法文件最坏尺寸 = 上限 400×300 格 = 1600×1200 子格（`n = 1,920,000`），四层全在且都取最坏编码：

| 段 | 最坏字节数 | 约 |
|---|---|---|
| 背景层（颜色） | `1 + 4n` = 7,680,001 | 7.68MB |
| 三个纹理层各 | `1 + 2 + 4×65535 + 1 + 2n` = 4,102,144 | 4.10MB ×3 ≈ 12.31MB |
| meta | `2 + 65535`（u16 长度字段上限） | 0.07MB |
| **合计** | **20,051,970** | **≈ 19.1MiB** |

- 64MB（67,108,864）= 上表的 ≈3.3 倍，对任何合法文件都不可能误拒。`smoke.js` 有断言
  `MAX_BODY_SIZE > 20MB`，把常量调到会误拒合法大图时会红。
- `inflateBytes` 的 `cancel` 是 **fire-and-forget**：先抛再 `cancel().catch(function () {})`，
  取消只做善后，不可挂在安全路径上。

## 4. `decodeMap` 的对外保证

**保证**（不满足就 reject，绝不静默返回一张残缺的图）：

1. 头部合理性：长度 ≥ 20、magic === `"CYRM"`、version === 4、`compression ∈ {0,1}`；
2. 尺寸合理：`sub_cols` / `sub_rows` > 0 且都是 `SUB_PER_CELL` 的倍数；
3. 解压闸门：头部声明的 `body_size ≤ MAX_BODY_SIZE`（判在解压之前），且解压**实际输出**不超过 `body_size`；
4. body 长度精确：解压后字节数 === 头部声明的 `body_size`；
5. CRC 相符：算得的 CRC32 与头部字段逐位相等（CRC 只覆盖 body，**不覆盖头部**）；
6. body 全消费：解完四层后剩余字节必须是 0；
7. 索引与调色板边界：调色板非空、`index_width ∈ {1,2}`、每个索引都 `< palette_count`；
8. 每层分配前的粗筛：头部尺寸反推出的格数不得超过该层剩余字节能装下的量。

**不保证**（下游自己判）：调色板 `[0]` 是空气（编码端义务）；描述符的纹理位 ≤ 22 或纹理 0 与整体 0 一致；
尺寸在上限内（`MAX_CELLS_W/H` 是编辑器输入钳制，不是格式边界）；出生点／敌人坐标在地图内或落在非实心格里；
`sub_cols` / `sub_rows` 与 body 里实际排布的子格数一致（只有第 8 条粗筛兜底）。

## 5. 调色板与索引

- ★ **索引 0 恒为空气**：即使本层一个空气格都没有，也要占住第 0 位，使「空图 = 调色板 `[0]` + 全 0 索引流」
  无条件成立。解码端对空调色板**硬拒**（`decodeTexLayer` 的 '调色板为空'）。
- **调色板上界是 `p ≤ 65534`**（`p` = 加入该项之前的 `pal.length`，加入后为 `p + 1 ≤ 65535`）。
  写成 `p > 65535` 会放行 65536 项，`w.u16(65536)` 按位截断成 0，产出本文件自己拒绝的文件。
- 错误信息里的数字必须与实际限值一致（**65535 = u16 上限**，不是 `p` 的上限）。

## 6. descriptor 位域与 `isAir`

```
descriptor (u32)
  bit  0- 2   hue          0-7
  bit  3- 5   brightness   0-7
  bit  6- 8   saturation   0-7
  bit  9-11   alpha        0-7
  bit 12-23   texture      1-4095   (0 = 空气)
  bit 24-31   保留，固定 0
```

- 中性档：hue / brightness / saturation 在**档 4**，alpha 在**档 7**（`neutralDesc` 拼的是 `(4, 4, 4, 7)`）。
- `isAir(d)` 判的是**整体等于 `DESC_AIR`（0）**，只对**本编码器产出的**数据可靠（`packDesc()` 保证空气恒为 0）。
- 读**外来**文件时唯一的空气判据是 **`texOf(d) === 0`**。一个「辅码非 0 而纹理为 0」的畸形描述符
  （如 `0x000007FF`）会让 `isAir(d) === false` 与 `texOf(d) === 0` 得出相反结论；`decodeMap` /
  `decodeTexLayer` 不归一化来路不明的描述符。

### 6.1 legacy 纹理 id：读时迁移（`95_legacy.js`）

- 背景：旧图集 22 块里 tex **2,3,4,5**（纯色方块色相变体）与 **16,17,18**（树叶色相变体）废弃。
  新 `structure.png` 这 7 槽**全透明**、其余 15 块未动；纹理 id 空间**稳定 1..22 不重编号**，
  文件格式**保持 v4 不升版本**。`tile_defs.js`（生成物）现为 **15 条 `tiles` + 顶层 `legacy_texture_map`**
  （旧 tex → `{base, hue}`）；UI 可点选调色板 = 15 条再排除派生的 22 ⇒ **14 项**（[editor-ui.md](editor-ui.md) §12.4）。
- ★ **迁移发生在读时、不在文件里**：`migrateDescriptor(d)` 的规则（已定决策）——
  `tex = texOf(d)` 命中 `legacy_texture_map` 时 `new_tex = base`、
  `new_hue = clamp(hueOf(d) + legacy_hue − 4, 0, 7)`（hue 是档位，legacy_hue 4 = 中性）、
  bri/sat/alpha 原样；未命中（含 tex 0 与畸形）原样返回。`migrateMap(map)` 对**三个 tex 层**原地迁移，
  color 层是 RGBA 不是描述符、一个字节不碰。
- ★ **表缺席是 no-op 而不是抛**：迁移表来自 `globalThis.TILE_DEFS`（worker 侧由 `importScripts('tile_defs.js')`
  带上，见 §1）；只装 core 的 node 冒烟里没有表 ⇒ 原样返回。生产路径（页面 / worker / dist）恒有表。
- ★ **`decodeMap` 自己不迁移**（core 的格式契约不变）；迁移挂在页面侧**全部四个读入口**上：
  v4 二进制（`level_editor/ui/10_util.js` 的 `mapFromBytes`）、v3 文本与旧字母格式（`migrateV3` 在产出 desc 时逐条
  `migrateDescriptor`，`level_editor/core/70_v3_text.js`）、**草稿恢复**（`level_editor/ui/75_draft_store.js` 的 `offerDraft`）与
  **崩溃槽位**（`level_editor/ui/80_ui_state.js` 的 `checkCrashSlot`）。漏掉任何一个，上次会话的旧数据就会带着
  legacy id 回到内存。
- 迁移后**内存即干净** ⇒ 新保存的文件不再含 legacy id；最后一道防线是 §9 的「纹理不在 tile_defs」error
  （`encodeMap` 只拒 errors）。守卫：`level_editor/tests/format/70_legacy_migration.js`（全表 + 钳制 +
  migrateMap + v3/legacy 文本 + 纹理闸）、editor 冒烟的三处接线（`10_core_tools` ①b / `62` ⑥b / `66` ⑪d）、
  tint 冒烟 ⑥b（真图集：15 块非空、legacy 7 槽全透明 —— 「把空槽抠掉重排图集」会红）。

## 7. 取角映射（`subcellRender`）

子格全局坐标 `(X, Y)` → 目标矩形（世界像素）+ 源矩形（贴图块内偏移）；调用方按 `(texture-1)` 定位贴图块，
再加这里的 `src` 偏移。

- `dst: [x, y, w, h]` 世界像素，**恒为 16×16**；
- `src: [x, y, w, h]` 贴图块内偏移，**恒为 8×8**；
- 象限由子格在 64px 格内的位置决定（`X % 4` / `Y % 4`），不存在数据字段里。

★★ **调用方约束：`X` / `Y` 必须非负，调用方自己 `posmod`**。负坐标会得到 `qx = -1` ⇒ `src[0] = -8`，
落在贴图块外；本函数不做归一化、不抛错，只会安静地给出**错误的源矩形**。

## 8. v3 文本与旧字母格式

- ★ **`packed = texture*16 + shape`** 是 v3 编码，与 v4 descriptor 无关：一律走
  `_v3Pack` / `_v3TexOf` / `_v3ShapeOf`，**不可**与 `packDesc` / `texOf` 混用。
- **版本标记行的唯一谓词**是 `isV3MarkerLine`，`isV3Text` 与 `parseV3Text` 两处都必须走它（两处必须同宽）。
  实现在规范写法 `# cyrm-v3` 之外容许 `#cyrm-v3` 与行尾附加内容（如 `# cyrm-v3 (demo)`）。
- **旧字母格式的宽高必须都是 ≥2 的偶数**（它靠 2×2 折叠成 1 格）；否则会抛裸 `TypeError` 或静默丢列。
- 旧 2×2 字母网格 → 1 格 packed：纹理取组内首个非零，形状 = 2×2 掩码；逻辑与游戏侧
  `MapFormat.convert_old_grid` 逐字对应。旧字母表只认 `0-9` 与 `A`（大小写均可）。
- **meta 文本形状**就是那几行 `# ...` 注释。输出顺序：先注释，再出生点（`player` / `player2` /
  `player3`…），再**按侧复活点**（侧 1 全部在前、侧 2 在后），最后敌人。
- **按侧复活点 `# respawn <1|2> <col> <row>` 编辑器认识**（见 [world.md](world.md)「出生/复活点:按阵营半区的地图数据」）：
  `parseMeta` 把合法行解析进 `map.respawns`（元素 `{side, x, y}`，侧 1 = 左半、侧 2 = 右半），
  `buildMeta` 按**侧分组**回写（侧 1 全部在前、侧 2 在后）——★ 游戏侧同侧按**文件顺序**去重（首次出现生效），
  顺序一变"生效的那条"也会变，故输出必须确定。
- **侧号只认 `1|2`、坐标必须是整数字面量**（与 `map_format.gd` / `_parse_cell_tokens` 同口径）；
  认不出的 `# respawn` 行**降级成注释**（走下面那条通用规则），不会被丢掉。
- 可视化：画布上按侧画 `R1`/`R2` 标记（侧 1 深绿、侧 2 深橙），顶栏「标线」叠加半区中线与 3×3 桶网格；
  校验见 §9。★ 这不改变格式：meta 仍是 `u16 meta_len` + UTF-8 文本，v4 二进制一个字节没动。
- **解析失败的行降级成注释而不是丢掉**（含坐标不是整数、坐标个数不够）。整数判定必须是**整数字面量**
  （`/^[+-]?\d+$/`），不可用 `isFinite`（`parseInt('3.5')===3` / `parseInt('7abc')===7` / `parseInt('1e3')===1`）。
- **v3 → v4 迁移**：旧掩码 bit `(qy*2+qx)` 为 1 → 新网格的 4 个子格 `X∈[2qx,2qx+1], Y∈[2qy,2qy+1]`
  填同一纹理；spawn 坐标同步 ÷2。前 / 后 / 背景三层留空。迁移是**单向**的。

## 9. 尺寸上限与校验

- `MAX_CELLS_W = 400` / `MAX_CELLS_H = 300`；缺省 `125×75`。
- 用户输入一律**钳制**而不是报错回滚（输 99999 变成 400）。
- ★ `MAX_CELLS_W/H` 是**编辑器**的输入钳制，**不是格式的边界条件** —— 格式只要求 `subCols` / `subRows`
  是 4 的倍数。
- **导出前校验只报告、不阻止导出**：`errors` = 真正非法；`warnings` = 能导出但游戏里可能不按预期跑。
  `encodeMap` **只拒 `errors`**。
- ★ **「纹理不在 tile_defs」是 error**（§6.1 的另一半守卫）：tex 层 desc 的 `texOf` 非 0 且不在
  `TILE_DEFS.tiles` 键集（legacy id 与越界号都算）⇒ 每层报一条、点名纹理号。`encodeMap` 只拒 errors，
  故它天然拦住「绕过迁移入口手改内存」的 legacy 残留被保存出去。`TILE_DEFS` 缺席时跳过这条检查
  （没有表可判，别把"没表"当成"全非法"）。
- **复活点判据**（`_checkRespawns`，常量 `RESPAWN_MIN_PER_SIDE = 5` / `RESPAWN_MIN_SIDE_GAP = 5` /
  `RESPAWN_EDGE_MARGIN = 10` / `RESPAWN_BUCKETS = 3`，与 `core/sim/spawn_chooser.gd`、
  [`tools/map_spawn_meta.gd`](../../tools/map_spawn_meta.gd) 同源）：每侧点数、点必须在自己半区、
  离接缝（`x=0`/`cols`）与半区中线 ≥10 格、同侧两两环面距离 ≥5 格、每侧 3×3 桶覆盖。
  ★ 全是 **warning**（游戏侧对不合规老图有回退路径），且"没有任何 `# respawn`"只在**有 `player2`（PvP 意图）**
  时才提示 —— 单机图不该被这条吵。
- `encodeMap` 必须先跑一遍 `validateMap`：`decodeMap` 在尺寸／图层长度上是严格的（非 4 倍数、图层长度
  不符一律拒收）。

## 10. 头部前向兼容（有意为之，别加校验）

`reserved` 字节与 `layer_flags` 的 bit4-7 一律**读掉不判**：写侧恒写 0（`encodeMap` 里 `w.u8(0)`、
`layerFlags` 只看 bit0-3），读侧只认低 4 位。**不可**加 `reserved === 0` 或 `flags & 0xF0 === 0` 的校验。

★ **闸门顺序**：`decodeMap` 必须先判头部声明的解压后大小、再碰 payload。这条顺序**没有守卫**
（行为侧只钉「超限必须拒」、期望子串 `64MB`，钉不住位置）。

## 11. 已知边界

| 项 | 状态 |
|---|---|
| `isAir` 的两种收口方式（加归一化 / 改判据为 `texOf`） | **未定**，要动公开接口（§6） |
| 「0 ≡ 空气」在解码侧成立 | **不成立**，编码端义务，解码端不代偿（§4、§6） |
| `MAX_BODY_SIZE` 之外的炸弹面 | 两道闸都不可省（§3） |

## 12. 图层模型（7 层：3 纹理 + 4 景深背景）

- `LAYER_COUNT = 7`：`0 前景` / `1 场景` / `2 后景`（纹理层）、`3 背景100%` / `4 背景75%` / `5 背景50%` / `6 背景25%`（**颜色层**，`u32 0xRRGGBBAA`/子格）。层号 = `layer_flags` 位号（`bit0-6`），`bit7` 保留写 0。
- 绘制顺序 = `DRAW_ORDER`（由 `LAYER_COUNT` 派生，层号倒序）：背景 25% 最先画、前景最后画。
- ★ **颜色层按需分配**：`createMap` 只分配层 0-3（历史文件恒有 bit3），层 4-6 默认 `null` —— 不落笔就不占内存、也不出 `layer_flags` 位；第一次要往里画时由 `Core.ensureLayer(map, L)` 建出。`ensureLayer` 只补颜色层，纹理层缺席（旧文件）绝不凭空补。
- 判据唯一来源 = `Core.isColorLayer(L)`（=`LAYER_BG_FIRST..LAYER_BG_LAST`）；UI / render 里别再写 `L === LAYER_BG`（那是"只有一层背景"时代的写法）。
- 旧文件（只有 bit0-3）解出层 4-6 = `null`，不报错；旧读取器忽略 `bit4-6` ⇒ 只看到背景100%（可接受降级，见 [`registered-debt.md`](registered-debt.md)）。

## 13. GDScript 移植（`core/editor/`；P0/P1，2026-11-08）

> 计划是一次性的（`.tmp/editor-in-godot-plan.md`，不入库）；本节只记**已落地的事实**。
> 在那之前 **JS 编辑器仍是唯一可用的编辑器**，`level_editor/core` 仍是 `.cyrm` 的第二份实现 ——
> 改 `.cyrm` 仍必须两边同步（§2 的契约不变）。计划 P2 起才做编辑器场景 / 导出两动作 / 两份导出 / JS 退役。

### 13.1 模块与镜像关系

`core/editor/` 是 `level_editor/core/*.js` 的 1:1 移植。**`99_exports.js` 不移植**：GDScript 的
`class_name` 就是全局符号表，再抄一份公开 API 表 = 两份真相源。

| JS shard | GDScript | class_name |
|---|---|---|
| `00_constants.js` | `editor_constants.gd` | `EditorConstants` |
| `20_bytes.js` | `editor_bytes.gd` | `EditorBytes` |
| `90_desc.js` | `editor_desc.gd` | `EditorDesc` |
| `85_geometry.js` | `editor_geometry.gd` | `EditorGeometry` |
| `40_meta.js` | `editor_meta.gd` | `EditorMeta` |
| `95_legacy.js` | `editor_legacy.gd` | `EditorLegacy` |
| `10_map.js` | `editor_map.gd` | `EditorMap` |
| `30_layers.js` | `editor_layers.gd` | `EditorLayers` |
| `50_compress.js` | `editor_compress.gd` | `EditorCompress` |
| `60_codec.js` | `editor_codec.gd` | `EditorCodec` |
| `70_v3_text.js` | `editor_v3.gd` | `EditorV3` |
| `80_validate.js` | `editor_validate.gd` | `EditorValidate` |

- 全部 `extends RefCounted`，只用 `static func` / `const` / `static var`。
- ★ **禁止 `RegEx`**（客户端导出走裁剪模板，`module_regex_enabled: false` ⇒ 整个脚本解析失败）：
  JS 的三条正则（meta 整数字面量、v3 标记行、`sanitizeName`）全部手写成码点循环；
  `EditorGeometry._is_js_space` 是 JS `\s` 集合的唯一实现（meta / v3 / clamp 共用）。
- legacy 迁移表**不抄**：直接读 `core/sim/tile_defs.gd` 的 `legacy_base_of` / `legacy_hue_of`
  （真相源仍是 `data/tile_defs.json`）。

### 13.2 地图对象形状（对应 JS 的 plain object）

```gdscript
{ "name": String, "sub_cols": int, "sub_rows": int, "layers": Array,   # layers 恒 7 项
  "players": [{x,int}], "enemies": [{type,x,y}], "respawns": [{side,x,y}], "comments": [String] }
```

层 = `{"kind":"tex","desc":PackedInt32Array}` | `{"kind":"color","rgba":PackedInt32Array}` | `null`。
下标一律 `y * sub_cols + x`。

- ★ `PackedInt32Array`（与游戏侧 `MapFormatV4` 同）：u32 超过 int32 会落成负数，**这是有意的** ——
  字节掩码（`v & 0xFF` 等）对负数同样正确；需要无符号值时才 `v & 0xFFFFFFFF`。
- 层 4-6 默认 `null`，由 `EditorMap.ensure_layer` 按需建；**纹理层缺席绝不凭空补**（旧文件就是没有那层）。

### 13.3 错误约定

GDScript 没有异常 ⇒ 可能失败的操作返回 `{ok:false, "error": String}`（文案照抄 JS 的 `throw`）。
**不抛错、不拿 `push_error` 当失败路径**。`EditorBytes.Reader` 越界置 `failed` / `error`（不抛），
`EditorLayers` / `EditorCodec` 每次读后必须判 `r.failed`。

### 13.4 跨语言黄金夹具（P0）

`tests/fixtures/cyrm/`：10 项夹具 / 11 个文件，由 **JS 编辑器核心**产出（生成脚本 `.tmp/gen_golden.js`（1-9 号）+ `.tmp/gen_maxfix.js`（10 号最大尺寸），
不入库）。构图、生产命令、每个夹具钉住的契约见 [`tests/fixtures/cyrm/README.md`](../../tests/fixtures/cyrm/README.md)。

`tests/probe/cyrm_golden_probe.gd`（`-s`，26 条断言）钉：

1. 无压缩夹具 `decode_map → encode_map(compress:false)` **逐字节相等**（调色板顺序 / 层块顺序 / 头字段全在内）；
2. legacy 夹具：解码**不迁移** → 未迁移编码被 `validate_map` 拒（error 含「不在 tile_defs」）→
   `EditorLegacy.migrate_map` 之后逐字节等于 `v4_legacy_migrated.cyrm`；
3. v3 文本 / 旧字母格式 → `EditorV3.parse_v3_text` / `migrate_v3` → 逐字节等于 JS 迁出的 v4 夹具；
4. `maps/*.cyrm` 全部可解、重编码稳定（解→编→解→编 字节相等）。

★ 压缩夹具**不钉 deflate 字节**（zlib 输出依赖实现/版本），只钉「解 → 无压缩重编码 == 无压缩孪生夹具」。

### 13.5 守卫

| 支 | 判词 | 条数闸 | 钉什么 |
|---|---|---|---|
| `tests/smoke/editor_core_smoke.gd` | `EDITOR CORE SMOKE: OK(37 条断言)` | 37 | 常量 / 描述符位域 / 字节序 / CRC / meta / 几何 / legacy / 地图对象 |
| `tests/smoke/editor_codec_smoke.gd` | `EDITOR CODEC SMOKE: OK(56 条断言):…` | 56 | 层编解码 / 容器 / 压缩 / 稀疏 flags / 双字节索引 / 65535 上界 / 七类坏输入 |
| `tests/smoke/editor_v3_smoke.gd` | `EDITOR V3 SMOKE: OK(41 条断言)` | 41 | v3 标记判定 / 解析报错 / 旧字母 2×2 / 迁移展开 / `subcell_render` |
| `tests/smoke/editor_validate_smoke.gd` | `EDITOR VALIDATE SMOKE: OK(20 条断言)` | 20 | 尺寸钳制 / errors vs warnings / 复活点判据 |
| `tests/probe/cyrm_golden_probe.gd` | `CYRM GOLDEN PROBE: ALL-OK(26 条断言)` | 26 | 见 §13.4 |

`EXPECTED_CHECKS` 都真用于比较（`run_all --list` 的 `GATE` 栏可见）；`bash tests/run_all.sh` 自动收录。

### 13.6 已知差异 / 取舍（照实写）

- `EditorCompress.inflate_bytes`：Godot `decompress` 无法区分「超上界」与「流损坏」（都返回空）⇒
  合并成一条 error；`ok:false` 语义不变，文案与 JS 的两条不同。
- `deflate_bytes` 空输入：Godot `compress()` 拒绝空输入（JS 会产出合法空流）；`encode_body` 的 body
  恒 ≥2 字节，实际不可达。
- `EditorMap.create_map` 尺寸非法返回空字典（不抛错）；调用方应先 `EditorValidate.clamp_map_size`。
- `EditorV3.migrate_v3` 与 JS 一致地**不复制** `respawns`（parsed 里有、地图数据里丢）；要改必须两边同改。
- UTF-16（JS `length` / `charAt`）vs UTF-32（GDScript `length`）：只影响含非 BMP 字符的**畸形**网格行的报错数字。

### 13.7 后续阶段

- **P2 编辑器场景已落地**（`scenes/editor/` + `EditorDoc` / `EditorIO`）：场景、坐标/环面、渲染、撤销、读写与守卫见
  [`editor-godot.md`](editor-godot.md)。
- 还没做：P3 导出两个动作、P5 客户端 / 服务端两份导出的编辑器裁剪（含主菜单入口按 `OS.has_feature("editor")`）、
  P6 `level_editor/` 退役。
- 在那之前别删 JS 编辑器，也别让 `core/editor` 反向依赖 `level_editor/`。
