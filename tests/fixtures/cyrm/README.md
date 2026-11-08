# 跨语言黄金夹具（`.cyrm` v4 / v3 文本）

> 用途：把 **JS 编辑器核心**（`level_editor/core/*.js`）现在产出的字节冻结成夹具。
> 以后 GDScript 侧（`core/sim/map_format_v4.gd` / 移植后的 `core/editor/*`）**解 → 重编码必须与这里的字节逐字节相等**。
> 这是 `.tmp/editor-in-godot-plan.md` P0 的验收物；计划里「`.cyrm` 只有一份编解码实现」的对照基准就是这批文件。

## 生成 / 复现

```bash
# 仓库根目录执行（生成脚本不入库：.tmp/ 整目录被 .gitignore 的 `*.tmp` 挡掉）
node .tmp/gen_golden.js
```

- 脚本自己写运行日志 `/.tmp/js_baseline.log`（**每个文件的 size + sha256 + 逐条自检结论**，末尾
  `GOLDEN GEN: OK(9 fixtures)`；任一条失败打 `FAIL` 并以退出码 1 结束）。10 号（最大尺寸）由另一个一次性脚本 `.tmp/gen_maxfix.js` 补生成，判词 `MAX FIXGEN: OK(...)`。
- 脚本两跑输出稳定（sha256 一致）；只有 `v4_mixed_7layers_deflate.cyrm` 的压缩字节依赖运行时 zlib 实现，
  换 Node/zlib 版本可能变 —— 见 §4。
- 生成后 `tests/fixtures/cyrm/` 应为 **10 项夹具 / 11 个文件**（3 号夹具额外带一份「迁移后期望字节」，10 号由 `gen_maxfix.js` 生成）。

## 1. 夹具清单与它钉住的契约

| # | 文件 | size | 构图摘要 | 钉住的契约 | JS 侧自检结论 |
|---|---|---|---|---|---|
| 1 | `v4_golden_1x1.cyrm` | 181 B | 1×1 格（4×4 子格）；场景层前 8 子格 `neutralDesc(1)`、后 8 空；背景 16 子格偶 `0x11223344` / 奇 `0xAABBCCDD`；`comments=['hi']`、`players=[{x:1,y:2}]` | **v4 编码器输出的完整字节向量**（20 头 + 161 body）：小端字段、调色板 `[0]` 恒空气、索引流、CRC32、层顺序、meta 文本顺序。头字段 = `body_size 161` / `crc 0x3FF579A9` / `sub 4×4` / `layer_flags 0x0F`。构图与 `level_editor/tests/format/40_golden_and_limits.js` 手推的 golden 向量同源 | 总长 181 ✓、body_size/crc 与手推一致 ✓、decode→encode(compress:false) 逐字节相等 ✓ |
| 2 | `v4_sparse_scene_only.cyrm` | 147 B | 3×2 格（12×8 子格）；**只留层 1**，层 0/2/3 全 `null`；`comments=[]`、`players=[{x:1,y:1}]` | 稀疏 `layer_flags`（`0x02`）：缺席层不写块、解码回到 `null`、重编码顺序稳定；历史文件「没有 bit3」也要能读 | `layer_flags=0b0010` ✓、回读层 0/2/3 为 null ✓、往返逐字节相等 ✓ |
| 3a | `v4_legacy_tex.cyrm` | 212 B | 4×2 格（16×8 子格）；层 1 调色板含 **legacy 纹理 id 2,3,4,5,16,17,18**（hue 各异）；`comments=['legacy tex']`、`players=[{x:1,y:1}]` | ① 格式层必须**原样读出再原样写回** legacy id（`layer_flags=0x02`）；② `decodeMap` / `MapFormatV4.parse` 都**不做迁移**（迁移是编辑器读入口的事，不是格式契约） | 手拼容器校验通过 ✓、回读 7 个 legacy 描述符与构图一致 ✓、未迁移地图 `encodeMap` 被拒且 error 含「不在 tile_defs」✓ |
| 3b | `v4_legacy_migrated.cyrm` | 212 B | 3a 经 `decodeMap → migrateMap → encodeMap(compress:false)` 的**期望字节**：legacy 7 条迁成 `(tex1,hue3/1/6/0)` 与 `(tex15,hue2/7/6)` | 读时迁移的确定输出（`new_hue = clamp(hue + legacy_hue − 4, 0, 7)`、bri/sat/alpha 原样、color 层不动）；GDScript 迁移层重编码必须逐字节等于它 | decode→migrateMap→encode 与文件逐字节相等 ✓、迁移后往返逐字节相等 ✓ |
| 4 | `v4_mixed_7layers.cyrm` | 2982 B | 3×3 格（12×12 子格）；**7 层全在**（纹理 0/1/2 + 颜色 3/4/5/6，见 §2）；meta：`comments=['alpha','beta']`、2 出生点、侧 1/侧 2 各 3 复活点、2 敌人 | 完整图层模型（`layer_flags=0x7F`）+ 四段 meta 顺序（注释→出生点→按侧复活点→敌人）+ 颜色层 u32 RGBA 字节序；重编码必须完整复现 | 7 层回读非 null ✓、四段 meta 回读一致 ✓、往返逐字节相等 ✓ |
| 5 | `v4_mixed_7layers_deflate.cyrm` | 249 B | 4 号同一张图 `Core.encodeMap(map)`（默认 deflate，`compression=1`） | 压缩容器契约：`body_size` 是**解压后**大小、CRC 覆盖解压后 body、deflate = zlib RFC1950（Godot `COMPRESSION_DEFLATE` 可解）。★ **压缩载荷本身不冻结**（zlib 实现可异），钉的是「解出的图重编码 = 4 号字节」 | `compression=1` ✓、decode→encode(compress:false) 逐字节等于 4 号 ✓ |
| 6 | `v3_simple.txt` | 75 B | `# cyrm-v3` 标记 + 2 格宽 × 3 行，每格 4 字符 = 3 位十进制纹理 + 1 位形状 hex；meta 行 `# player 2 1` / `# enemy slime 3 2` / `# note` | v3 文本解析：标记行判定（识别与跳过同源）、`packed = texture*16 + shape`、行宽一致、meta 行解析 | 内容/UTF-8/LF ✓、`isV3Text` 为真 ✓、解析 2×3 格 ✓ |
| 7 | `v4_from_v3_simple.cyrm` | 773 B | `parseV3Text(6 号) → migrateV3 → encodeMap(compress:false)` | v3→v4 单向迁移：形状掩码 bit `(qy*2+qx)` → 新网格 4 子格；前/后/背景三层留空；meta 原样带过。GDScript 解析 v3 后重编码必须等于它 | decode 出的 players/enemies/comments 与文本行一致 ✓、往返逐字节相等 ✓ |
| 8 | `legacy_letters.txt` | 33 B | 旧字母格式（**无** v3 标记），4×4 偶数网格，字符只 `0-9/A`；meta `# player 4 2` | 旧格式自动识别（无标记 → 字母表）→ 2×2 折叠成 1 格（纹理取组内首个非零、形状 = 2×2 掩码）→ spawn 坐标 ÷2 | 非 v3 判定 ✓、解析 2×2 格 ✓、player (4,2)→(2,1) ✓ |
| 9 | `v4_from_legacy_letters.cyrm` | 520 B | `parseV3Text(8 号) → migrateV3 → encodeMap(compress:false)` | 旧字母 → v4 迁移（`layer_flags=0x0F`）；经 `migrateV3` 时 legacy id 也逐条迁移（样本里字符 `3` → tex3 → tex1/hue1） | decode 出的 players=(2,1)、enemies/comments 为空 ✓、往返逐字节相等 ✓ |
| 10 | `v4_max_400x300_empty.cyrm` | 13131 B | 400×300 格 = 1600×1200 子格 = 1,920,000 子格/层（格式允许上界）；四层全空、deflate 后 13 KB；`GDScript` 侧只钉「能解 + 尺寸/层长 1,920,000 + 4-6 层 null」，不钉压缩字节 | 最大尺寸边界：`sub_cols`/`sub_rows` 是 u16、层数组长度 = n，越界或按格数误分配会在解码期暴露 | `decodeMap` 回读 sub 1600×1200、四层各 1,920,000、层 4-6 null ✓（`.tmp/gen_maxfix.js`，判词 `MAX FIXGEN: OK(13131 bytes / sub 1600x1200 / n=1920000)`） |

> size 是当前实现的稳定值（两跑一致）。sha256 只在 `.tmp/js_baseline.log`（含全部 11 个文件），
> **不入库**以免文档随 zlib 版本漂移。

## 2. 4 号（7 层）的确定性构图

3×3 格 → `subCols = subRows = 12`，`n = 144`，子格下标 `i = y*12 + x`：

- 纹理层 0（前景）：`i % 7 === 0` → `neutralDesc(1)`；`i % 11 === 5` → `packDesc(6, 2, 5, 6, 7)`。
- 纹理层 1（场景）：`i % 5 === 0` → `neutralDesc(9)`；`i % 9 === 2` → `packDesc(11, 6, 4, 4, 7)`。
- 纹理层 2（后景）：`i % 4 === 0` → `neutralDesc(19)`；`i % 13 === 3` → `packDesc(21, 3, 4, 4, 7)`。
- 颜色层 3/4/5/6：偶 `i` / 奇 `i` 两色交替 —— 层 3 `0x102030FF`/`0x40506080`、层 4 `0xAA0000FF`/`0x00AA00FF`、
  层 5 `0x0000AAFF`/`0xFFFFFF00`、层 6 `0xFF00FFFF`/`0x00112233`（写盘为 u32 小端）。
- meta：`comments=['alpha','beta']`；`players=[{0,0},{2,2}]`；
  `respawns` = 侧 1 `(1,0),(0,1),(0,2)` + 侧 2 `(2,0),(2,1),(2,2)`（按侧分组写）；
  `enemies=[{slime,1,1},{bat,2,0}]`。

## 3. 3 号为什么是「手拼」的（与直觉/计划假设不符，务必看）

`Core.encodeMap` 在编码前会跑 `validateMap`，而 **legacy 纹理 id（2,3,4,5,16,17,18）在 `validateMap` 里是
`errors` ⇒ `encodeMap` 硬拒**（`docs/eng/editor-core.md` §6.1/§9：这是「内存里还有 legacy 残留」的最后防线）。

但夹具要钉的恰恰是「**文件里就该有 legacy id** 时格式层能读能写」。所以 `v4_legacy_tex.cyrm` 用
`Core` 暴露的原语手拼 v4 容器，绕过 `encodeMap` 的校验：

```js
meta   = Core.buildMeta(map)                        // 文本
layer1 = Core.encodeTexLayer(map.layers[1].desc, subCols, subRows)
body   = u16(meta.length) + meta + layer1
file   = "CYRM" + 4 + 0 + u32(body.length) + u32(Core.crc32(body))
       + u16(subCols) + u16(subRows) + u8(0b0010) + u8(0)
       + body
```

即头 20 字节：magic / version=4 / compression=0 / body_size / crc32 / sub_cols=16 / sub_rows=8 /
`layer_flags=0b0010` / reserved=0。生成脚本里对应函数 `assembleV4SceneOnly()`（`.tmp/gen_golden.js`）。

**给 GDScript 侧的两层分工**（别混）：

- **编辑器层**（移植后的 `EditorCodec`，镜像 JS `encodeMap`）：`decode_map` 不迁移（内存里仍是 legacy id）、
  未迁移直接 `encode_map` 必须被拒（error 含「不在 tile_defs」）、`EditorLegacy.migrate_map` 之后
  `encode_map(compress:false)` 必须逐字节等于 `v4_legacy_migrated.cyrm`。这就是现有
  `tests/probe/cyrm_golden_probe.gd` 的 ⑤ 组口径。
- **游戏侧格式层**（`core/sim/map_format_v4.gd`，不经 `validateMap`）：`parse → encode` 应能把
  `v4_legacy_tex.cyrm` **原样读回写回**（字节相等；JS 侧已用 `decodeMap + 原语手拼`验证过，
  见上）。这条是可选的更强断言，**不要**拿「编辑器层拒绝」去要求它。

## 4. 5 号压缩件钉什么、不钉什么

- **钉**：`compression=1`、`body_size`/CRC 都针对**解压后** body、能解出与 4 号同一张图、
  解出后 `encodeMap(compress:false)` 与 4 号逐字节相等（Godot 侧对应
  `bytes.compress/decompress(FileAccess.COMPRESSION_DEFLATE)`，RFC1950）。
- **不钉**：deflate 输出的**具体字节**。zlib 的压缩结果依赖实现/版本，换 Node 版本重跑可能不同；
  所以 `js_baseline.log` 里的 sha256 也只在当次运行有意义。跨语言往返断言必须走「解→重编码」而非「压缩字节相等」。

## 5. 自检结论（`.tmp/js_baseline.log` 摘要）

```
OK  1) v4_golden_1x1: 181 字节 / body_size=161 / crc=0x3ff579a9 / decode→encode 逐字节相等
OK  2) v4_sparse_scene_only: layer_flags=0b0010 / 层 0·2·3 回读 null / 往返逐字节相等
OK  3) v4_legacy_tex: 未迁移 encode 被拒(含「不在 tile_defs」) / migrateMap→encode 逐字节等于 v4_legacy_migrated.cyrm
OK  4) v4_mixed_7layers: 7 层全在 / meta 四段回读正确 / decode→encode 逐字节相等
OK  5) v4_mixed_7layers_deflate: compression=1 / decode→encode(compress:false) 逐字节等于 v4_mixed_7layers.cyrm
OK  6/7) v3_simple.txt(2×3 格/LF) → parseV3Text → migrateV3 → v4_from_v3_simple.cyrm: meta 一致、往返逐字节相等
OK  8/9) legacy_letters.txt(无 v3 标记/4×4 偶数网格) → parseV3Text(旧字母) → migrateV3: 2×2 折叠、坐标 ÷2、往返逐字节相等
GOLDEN GEN: OK(9 fixtures)
```

自检一律**逐字节比较**（不是只比长度）；JS 核心套件基线同轮 `node level_editor/smoke.js` 为
`结果: 339 通过, 0 失败 / SMOKE OK`（1 号夹具与该套件里手推的 181 字节向量同源，故两边互为证明）。

## 6. 文本夹具原文

`v3_simple.txt`（UTF-8、LF；每行 2 格 × 4 字符）：

```
# cyrm-v3
0010006F
00900112
015F0198
# player 2 1
# enemy slime 3 2
# note
```

`legacy_letters.txt`（UTF-8、LF；2×2 折叠）：

```
1234
5678
9A01
2345
# player 4 2
```

## 7. 下游怎么用（给 GDScript 探针）

对每个夹具的**格式层**断言应为：

1. 读文件 → `MapFormatV4.parse` / 移植后的 `EditorCodec.decodeMap`；
2. 再编码（无压缩路径）→ 与原文件**逐字节相等**；
3. 例外只有两个：`v4_legacy_tex.cyrm` 走编辑器层三步（解码不迁移 / 未迁移 encode 被拒 /
   `migrate_map` 后 == 3b），若另测游戏侧 `MapFormatV4` 格式层则 parse→encode 应原样相等（见 §3）；
   `v4_mixed_7layers_deflate.cyrm` 要按 4 号字节比（解压后重编码，不比较压缩载荷）。
