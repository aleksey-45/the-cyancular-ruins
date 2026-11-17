# `.cyrm` 格式与编辑器核心（`core/editor/`）

> 2026-11-09：浏览器编辑器 `level_editor/`（143 个文件）已整体退役删除，历史一律看 `git log`（本仓不设归档目录）。
> `.cyrm` 现在只有 **GDScript 一份实现**：游戏侧读 + 编辑器侧读写。本文 §1–§11 记格式契约，§12 起记 GDScript 模块与守卫。
> 编辑器场景（画布/面板/导出动作/两份产物）见 [`editor-godot.md`](editor-godot.md)。★ 冲突以源码为准，读前先 `grep` 复核。

## 1. 两份 GDScript 实现的分工

| 实现 | 文件 | 职责 | 校验 |
|---|---|---|---|
| 游戏读取 | [`core/sim/map_format_v4.gd`](../../../core/sim/map_format_v4.gd)（门面 [`map_format.gd`](../../../core/sim/map_format.gd)） | `parse`（只留「场景」层 + 背景四层）、`serialize`（只写场景层、裸 body）、`replace_meta`（字节级改 meta 尾巴） | 不跑 `validateMap`（读得快、不拦老图） |
| 编辑器读写 | [`core/editor/`](../../../core/editor)（`EditorCodec` / `EditorLayers` / `EditorValidate` …） | 7 层完整编解码、导前校验、v3/旧字母迁移、legacy 读时迁移 | `encode_map` 先跑 `EditorValidate.validate_map`，**只拒 errors** |

★ **改格式必须两边同改**：同一份格式在游戏侧与编辑器侧各有一半（游戏侧是性能裁剪版，编辑器侧是完整版）。
编辑器的字节契约由 `tests/fixtures/cyrm/` 的黄金夹具钉住（见 [`tests/fixtures/cyrm/README.md`](../../../tests/fixtures/cyrm/README.md)）。

## 2. `MAX_BODY_SIZE = 64MB`（两道闸，都不可省）

- 作用对象 = 头部声明的**解压后** body 大小；① 判在**任何解压动作之前**（挡声明侧炸弹）；② 解压的 `maxBytes` 作用在**实际输出**上（挡「谎报声明 + 真炸弹」）。
- 解压上界传的是 `body_size`（合法文件解压结果恒等于它，是精确上界），**不是** `MAX_BODY_SIZE`（松值）。
- 合法文件最坏尺寸 = 上限 400×300 格 = 1600×1200 子格（`n = 1,920,000`）：

| 段 | 最坏字节 | 约 |
|---|---|---|
| 背景层（颜色） | `1 + 4n` = 7,680,001 | 7.68MB |
| 三个纹理层各 | `1 + 2 + 4×65535 + 1 + 2n` = 4,102,144 | 4.10MB ×3 ≈ 12.31MB |
| meta | `2 + 65535` | 0.07MB |
| **合计** | **20,051,970** | **≈ 19.1MiB** |

64MB = 上表的 ≈3.3 倍，对任何合法文件都不可能误拒。

## 3. `decode_map` 的对外保证

**保证**（不满足就 `{ok:false}`，绝不静默返回残缺图）：

1. 头部合理性：长度 ≥ 20、magic `"CYRM"`、version 4、`compression ∈ {0,1}`；
2. 尺寸合理：`sub_cols` / `sub_rows` > 0 且都是 `SUB_PER_CELL`（4）的倍数；
3. 解压闸门：头部声明 ≤ 64MB（判在解压前），且实际输出不超过声明；
4. body 长度精确：解压后字节数 === 声明；
5. CRC 相符（CRC **只覆盖 body**，不覆盖头部）；
6. body 全消费：解完 7 层后剩余字节必须是 0；
7. 索引与调色板边界：调色板非空、`index_width ∈ {1,2}`、每个索引 `< palette_count`；
8. 每层分配前的粗筛：头部尺寸反推出的格数不得超过该层剩余字节能装下的量。

**不保证**（下游自己判）：调色板 `[0]` 是空气（编码端义务）；纹理 0 与整体 0 一致；尺寸在上限内（`MAX_CELLS_W/H` 是编辑器输入钳制，不是格式边界）；出生点/敌人坐标在图内或落在非实心格；`sub_cols`/`sub_rows` 与 body 里实际排布一致（只有第 8 条粗筛兜底）。

## 4. 调色板与索引

- ★ **索引 0 恒为空气**：即使本层一个空气格都没有，也占住第 0 位 ⇒「空图 = 调色板 `[0]` + 全 0 索引流」无条件成立；解码端对空调色板**硬拒**。
- **调色板上界 `p ≤ 65534`**（`p` = 加入该项之前的 `pal.size()`；加入后 `p+1 ≤ 65535 = u16 上限`）。写成 `p > 65535` 会放行 65536 项，`u16` 按位截断成 0，产出自己拒绝的文件。
- `index_width`：调色板 ≤ 256 用 1 字节，否则 2 字节。
- 背景颜色层不做调色板：真彩 `u32 0xRRGGBBAA`/子格（平滑渐变恰好是 deflate 最擅长的一类数据）。

## 5. descriptor 位域与空气判据

```
descriptor (u32)
  bit  0- 2   hue          0-7
  bit  3- 5   brightness   0-7
  bit  6- 8   saturation   0-7
  bit  9-11   alpha        0-7
  bit 12-23   texture      1-4095   (0 = 空气)
  bit 24-31   保留，固定 0
```

- 中性档：hue / brightness / saturation 在**档 4**，alpha 在**档 7**（`neutral_desc` 拼 `(4,4,4,7)`）。
- `is_air(d)` 判的是**整体等于 0**，只对**本编码器产出的**数据可靠（`pack_desc` 保证空气恒为 0）。
- 读**外来**文件时唯一空气判据是 **`tex_of(d) == 0`**：畸形描述符（如 `0x7FF`）会让 `is_air` 与 `tex_of` 得出相反结论；`decode_map` / `decode_tex_layer` **不归一化**来路不明的描述符。
- 注意 `PackedInt32Array` 存 u32 会落成负数（如 `0xFFFFFFFF` → `-1`），这是有意的：字节掩码（`v & 0xFF` 等）对负数同样正确，需要无符号值时才 `v & 0xFFFFFFFF`。

## 6. legacy 纹理 id：读时迁移（`EditorLegacy`）

- 旧图集 22 块里 tex **2,3,4,5**（纯色方块色相变体）与 **16,17,18**（树叶色相变体）废弃：新 `structure.png` 这 7 槽全透明、其余 15 块未动；纹理 id 空间**稳定 1..22 不重编号**、格式**保持 v4 不升版本**。迁移表 = `data/tile_defs.json` 的 `legacy_texture_map`（生成物 `TileDefs` 读它，单一真相源）。
- **迁移发生在读时、不在文件里**：`migrate_descriptor(d)` = tex 命中表时 `new_tex = base`、`new_hue = clamp(hue_of(d) + legacy_hue − 4, 0, 7)`，bri/sat/alpha 原样；未命中（含 tex 0 与畸形）原样返回。
- 调用点 = `EditorIO.open_path`（v4 读入后 `migrate_map`）+ `EditorV3.migrate_v3`（产出 desc 时逐条迁移）。**`decode_map` 自己不迁移**（格式契约不变）。
- 迁移后内存即干净 ⇒ 新保存的文件不再含 legacy id；最后一道防线是 §9「纹理不在 tile_defs」error。
- 守卫：`tests/unit/editor_core_smoke.gd`（全表 + 钳制 + migrate_map）、`editor_v3_smoke.gd`（v3 产出时迁移）、`cyrm_golden_probe.gd`（迁移后期望字节 `v4_legacy_migrated.cyrm`）。

## 7. 取角映射（`EditorV3.subcell_render`）

子格全局坐标 `(X, Y)` → 目标矩形（世界像素，恒 16×16）+ 源矩形（贴图块内偏移，恒 8×8）；调用方按 `(texture-1)` 定位贴图块再加 `src` 偏移。

- 象限由子格在 64px 格内的位置决定（`X % 4` / `Y % 4`），不存在数据字段里。
- ★★ **调用方约束：`X` / `Y` 必须非负，调用方自己 `posmod`**。负坐标会得到 `qx = -1` ⇒ `src[0] = -8`，落在贴图块外；本函数不做归一化、不抛错，只会安静地给出**错误的源矩形**（环面语义属于调用方的世界模型）。
- 游戏侧等价实现：`TerrainAtlas.build_atlas_image_for`（列 = `(sy%4)*4 + (sx%4)`，行 = 描述符行）。

## 8. v3 文本与旧字母格式

- ★ **`packed = texture*16 + shape`** 是 v3 编码，与 v4 descriptor 无关：一律走 `EditorV3._v3_pack` / `_v3_tex_of` / `_v3_shape_of`，**不可**与 `pack_desc` / `tex_of` 混用。
- **版本标记行的唯一谓词**是 `is_v3_marker_line`（`is_v3_text` 与 `parse_v3_text` 两处都必须走它）。实现在规范写法 `# cyrm-v3` 之外容许 `#cyrm-v3` 与行尾附加内容（如 `# cyrm-v3 (demo)`）。**禁止 RegEx**（客户端导出裁剪了 regex 模块）⇒ 逐码点手写。
- **旧字母格式的宽高必须都是 ≥2 的偶数**（它靠 2×2 折叠成 1 格）；否则会静默丢边缘行/列。
- 旧 2×2 字母网格 → 1 格 packed：纹理取组内首个非零、形状 = 2×2 掩码；旧字母表只认 `0-9` 与 `A`（大小写均可）。
- **meta 文本形状**就是那几行 `# ...` 注释。输出顺序：先注释，再出生点（`player` / `player2` / `player3`…），再**按侧复活点**（侧 1 全部在前、侧 2 在后），最后敌人。
- **按侧复活点 `# respawn <1|2> <col> <row>`**（见 [`world.md`](../gameplay/world.md)「出生/复活点：按阵营半区的地图数据」）：`parse_meta` 解析进 `map.respawns`（`{side,x,y}`，侧 1 = 左半、侧 2 = 右半），`build_meta` 按侧分组回写 —— 游戏侧同侧按**文件顺序**去重（首次出现生效），顺序一变「生效的那条」也会变，故输出必须确定。
- **侧号只认 `1|2`、坐标必须是整数字面量**；认不出的 `# respawn` 行**降级成注释**（不会被丢掉）。整数判定必须是**整数字面量**（手写 `/^[+-]?\d+$/` 的等价循环，不可用 `is_valid_float` 之类前缀截断语义）。
- **v3 → v4 迁移**：旧掩码 bit `(qy*2+qx)` 为 1 → 新网格 4 个子格 `X∈[2qx,2qx+1], Y∈[2qy,2qy+1]` 填同一纹理；spawn 坐标同步 ÷2（负坐标 floor）。前/后/背景三层留空。迁移**单向**。（`migrate_v3` 与旧 JS 版一致地**不复制** `respawns`，见 §13。）

## 9. 尺寸上限与校验（`EditorValidate`）

- `MAX_CELLS_W = 400` / `MAX_CELLS_H = 300`；缺省 `125×75`。用户输入一律**钳制**而不是报错回滚（输 99999 变成 400）。
- ★ `MAX_CELLS_W/H` 是**编辑器**的输入钳制，**不是格式边界** —— 格式只要求 `sub_cols` / `sub_rows` 是 4 的倍数。
- **导出前校验只报告、不阻止导出**：`errors` = 真正非法（`encode_map` 只拒 errors）；`warnings` = 能导出但游戏里可能不按预期跑。
- ★ **「纹理不在 tile_defs」是 error**：tex 层 desc 的 `tex_of` 非 0 且不在 `data/tile_defs.json` 的 tiles 键集（legacy id 与越界号都算）⇒ 每层报一条、点名纹理号。`TILE_DEFS` 缺席时跳过（没有表可判，别把「没表」当「全非法」）。
- **复活点判据**（常量 `RESPAWN_MIN_PER_SIDE = 5` / `RESPAWN_MIN_SIDE_GAP = 5` / `RESPAWN_EDGE_MARGIN = 10` / `RESPAWN_BUCKETS = 3`，与 `core/sim/spawn_chooser.gd`、`tools/map_spawn_meta.gd` 同源）：每侧点数、点必须在自己半区、离接缝（`x=0`/`cols`）与半区中线 ≥10 格、同侧两两环面距离 ≥5 格、每侧 3×3 桶覆盖。★ 全是 **warning**（游戏侧对不合规老图有回退路径），且「没有任何 `# respawn`」只在**有 `player2`（PvP 意图）**时才提示。
- `encode_map` 必须先跑一遍 `validate_map`：`decode_map` 在尺寸/图层长度上很严格，不校验就会产出坏文件。

## 10. 头部前向兼容（有意为之，别加校验）

`reserved` 字节与 `layer_flags` 的 bit4-7 一律**读掉不判**：写侧恒写 0（`layer_flags` 只看 bit0-3），读侧只认低 4 位。**不可**加 `reserved == 0` 或 `flags & 0xF0 == 0` 的校验。

★ **闸门顺序**：`decode_map` 必须先判头部声明的解压后大小、再碰 payload（这条顺序没有守卫，只能靠人看）。

## 11. 图层模型（7 层：3 纹理 + 4 景深背景）

- `LAYER_COUNT = 7`：`0 前景` / `1 场景` / `2 后景`（纹理层）、`3 背景100%` / `4 背景75%` / `5 背景50%` / `6 背景25%`（**颜色层**，`u32 0xRRGGBBAA`/子格）。层号 = `layer_flags` 位号（`bit0-6`），`bit7` 保留写 0。
- 绘制顺序 = 层号倒序：背景 25% 最先画、前景最后画。
- ★ **颜色层按需分配**：`EditorMap.create_map` 只分配层 0-3（历史文件恒有 bit3），层 4-6 默认 `null` —— 不落笔就不占内存、也不出 `layer_flags` 位；第一次要往里画时由 `EditorMap.ensure_layer` 建出。**`ensure_layer` 只补颜色层，纹理层缺席（旧文件）绝不凭空补。**
- 判据唯一来源 = `EditorConstants.is_color_layer(L)`；UI / render 里别再写「`L == LAYER_BG`」（那是「只有一层背景」时代的写法）。
- 旧文件（只有 bit0-3）解出层 4-6 = `null`，不报错；旧读取器忽略 `bit4-6` ⇒ 只看到背景 100%（可接受降级）。

## 12. GDScript 模块与守卫（原 P0/P1 移植，2026-11-08）

模块表（12 个；`99_exports` 不移植 —— GDScript 的 `class_name` 就是全局符号表，再抄一份 API 表 = 两份真相源）：

| 文件 | class_name | 职责 |
|---|---|---|
| [`editor_constants.gd`](../../../core/editor/editor_constants.gd) | `EditorConstants` | 网格/图层常量、`is_color_layer` |
| [`editor_bytes.gd`](../../../core/editor/editor_bytes.gd) | `EditorBytes` | 小端读写器（`Reader.failed` 不抛错）+ CRC32 |
| [`editor_desc.gd`](../../../core/editor/editor_desc.gd) | `EditorDesc` | descriptor 位域 |
| [`editor_geometry.gd`](../../../core/editor/editor_geometry.gd) | `EditorGeometry` | 名字净化、画笔几何、JS `\s` 等价判定 |
| [`editor_meta.gd`](../../../core/editor/editor_meta.gd) | `EditorMeta` | meta 文本编解码 |
| [`editor_legacy.gd`](../../../core/editor/editor_legacy.gd) | `EditorLegacy` | legacy 读时迁移 |
| [`editor_map.gd`](../../../core/editor/editor_map.gd) | `EditorMap` | 地图对象 + `ensure_layer` |
| [`editor_layers.gd`](../../../core/editor/editor_layers.gd) | `EditorLayers` | 单层编解码 |
| [`editor_compress.gd`](../../../core/editor/editor_compress.gd) | `EditorCompress` | zlib（引擎原生 `COMPRESSION_DEFLATE`） |
| [`editor_codec.gd`](../../../core/editor/editor_codec.gd) | `EditorCodec` | v4 容器 |
| [`editor_v3.gd`](../../../core/editor/editor_v3.gd) | `EditorV3` | v3 文本 / 旧字母格式 / 迁移 / `subcell_render` |
| [`editor_validate.gd`](../../../core/editor/editor_validate.gd) | `EditorValidate` | 尺寸钳制 + 整图校验 |

- 全部 `extends RefCounted`，只用 `static func` / `const` / `static var`；错误一律 `{ok:false, "error"}`（文案中文、照抄旧实现），**不抛错、不拿 `push_error` 当失败路径**。
- ★ **禁止 `RegEx`**（客户端导出走裁剪模板，`module_regex_enabled: false` ⇒ 整个脚本解析失败）：旧实现的三条正则（meta 整数字面量、v3 标记行、`sanitizeName`）全部手写成码点循环。
- legacy 迁移表**不抄**：直接读 `core/sim/tile_defs.gd` 的 `legacy_base_of` / `legacy_hue_of`（真相源 `data/tile_defs.json`）。

守卫（`bash tests/run_all.sh` 自动收录，判据 = 判词文本）：

| 支 | 判词 | 条数闸 | 钉什么 |
|---|---|---|---|
| `tests/unit/cyrm_golden_probe.gd` | `CYRM GOLDEN PROBE: ALL-OK(26 条断言)` | 26 | 跨语言黄金夹具：解→重编码逐字节相等、legacy/v3 迁移期望字节、真实地图稳定、400×300 最大尺寸 |
| `tests/unit/editor_core_smoke.gd` | `EDITOR CORE SMOKE: OK(37 条断言)` | 37 | 常量/描述符/字节序/CRC/meta/几何/legacy/地图对象 |
| `tests/unit/editor_codec_smoke.gd` | `EDITOR CODEC SMOKE: OK(56 条断言)` | 56 | 层编解码/容器/压缩/稀疏 flags/双字节索引/65535 上界/七类坏输入 |
| `tests/unit/editor_v3_smoke.gd` | `EDITOR V3 SMOKE: OK(41 条断言)` | 41 | v3 标记/解析报错/旧字母 2×2/迁移展开/subcell_render |
| `tests/unit/editor_validate_smoke.gd` | `EDITOR VALIDATE SMOKE: OK(20 条断言)` | 20 | 钳制/errors vs warnings/复活点判据 |

编辑器场景/文档/导出两动作/两份产物的守卫表见 [`editor-godot.md`](editor-godot.md) §7、§10。

## 13. 已知差异 / 取舍（照实写）

- `EditorCompress.inflate_bytes`：Godot `decompress` 无法区分「超上界」与「流损坏」（都返回空）⇒ 合并成一条 error；`ok:false` 语义不变。
- `deflate_bytes` 空输入：Godot `compress()` 拒绝空输入（旧实现会产出合法空流）；`encode_body` 的 body 恒 ≥2 字节，实际不可达。
- `EditorMap.create_map` 尺寸非法返回空字典（不抛错）；调用方应先 `EditorValidate.clamp_map_size`。
- `EditorV3.migrate_v3` 与旧实现的语义一致地**不复制** `respawns`（解析结果里有、地图数据里丢）；要改必须两个读入口一起改。
- UTF-16（旧 JS `length`/`charAt`）vs UTF-32（GDScript `length`）：只影响含非 BMP 字符的**畸形**网格行的报错数字。
- 压缩夹具不钉 deflate 字节（zlib 实现可异），只钉「解 → 无压缩重编码 == 无压缩孪生夹具」。

## 14. 历史（一句话）

2026-11-09：`level_editor/`（浏览器编辑器：13 个 core shard + ui/render/io/server + 65 个 node 测试）删除；
迁移过程 = 先把格式核心 1:1 移植进 `core/editor/`（P1）+ 跨语言黄金夹具（P0），再做编辑器场景（P2）、导出两动作（P3）、
两份导出（P5），最后删 JS（P6）。为什么当时这么定：唯一能查的地方是 `git log`（本仓不设归档目录）。
