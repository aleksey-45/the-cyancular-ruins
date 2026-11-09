# Godot 编辑器场景（`core/editor` + `scenes/editor`，P2）

> P0/P1 把 `.cyrm` 编解码移植进 `core/editor/`（格式契约与模块表见 [`editor-core.md`](editor-core.md) §12）。
> 本文件记 **P2 编辑器场景**（2026-11-08 落地）：分层、坐标、渲染、撤销、读写、守卫、已知边界。
> 迁移过程与取舍见 [`editor-core.md`](editor-core.md) §14；历史（含已删的浏览器编辑器）一律看 `git log`。
> ★ 冲突以源码为准。

## 1. 分层与文件

| 层 | 文件 | 职责 |
|---|---|---|
| 文档模型 | [`core/editor/editor_doc.gd`](../../core/editor/editor_doc.gd) | 地图字典 + 当前层 + 稀疏 cells 撤销栈 + 环面归一化 + `changed`/`structure_changed` 信号；纯逻辑、可 `-s` 测 |
| 读写门面 | [`core/editor/editor_io.gd`](../../core/editor/editor_io.gd) | `open_path`（v4 二进制 / v3 文本 / 旧字母格式 + 读时 legacy 迁移）、`save_path`（校验 + 编码 + 写盘）、`default_target`、`list_maps` |
| 画布 | [`scenes/editor/editor_canvas.gd`](../../scenes/editor/editor_canvas.gd) | 视口离屏层合成、相机（origin/zoom）、`screen_to_subcell`、层可见/压暗、网格与画刷框、`pointer_*` 信号 |
| 场景根 | [`scenes/editor/editor_root.gd`](../../scenes/editor/editor_root.gd) / [`.tscn`](../../scenes/editor/editor_root.tscn) | 顶栏 / 7 层面板 / 工具 / 调色板 / 校验输出 / 状态栏；把画布事件接到 `EditorDoc`；公开 `open_path` / `save_to` / `validate` / `get_doc` / `get_editor_canvas` |

★ 纯逻辑（编解码 / 校验 / 文档 / 读写）全在 `core/editor/`；`scenes/editor/` 只做 UI 与接线 —— 场景探针不需要点按钮就能验完整链路。

## 2. 坐标与环面

- 世界坐标 = **子格**（16px）；格坐标 = 子格 ÷ 4（`EditorConstants.SUB_PER_CELL`）。
- 画布：`origin`（画布左上角对应的世界子格，float）+ `zoom`（px / 子格，默认 16，档位 `[4,8,12,16,24,32,48,64]`）。
  `screen_to_subcell(pos) = floor(origin + pos / zoom)` —— **可能为负**；归一化（`posmod`）由 `EditorDoc` 兜底。
- 环面：编辑写入口在 `EditorDoc` 内做 `posmod`；画布采样用 `posmod` 取本图，拖到图外看到的是环绕副本。
- 画笔几何复用 `EditorGeometry.brush_offsets` / `line_cells` / `norm_region`（与 JS 编辑器同一套规则）。

## 3. 渲染（视口离屏层）

- 每次 `refresh()` 把**可见区**合成到一张与画布等大的 `Image`：层号倒序（背景 25% → … → 前景），
  纹理层从 `TerrainAtlas.build_atlas_image_for(descs)` 的图集按象限 blit（列 = `(sy%4)*4 + (sx%4)`，行 = `row_of[desc]`），
  颜色层按子格填 `rgba`；非 active 层 alpha 压到 `0.45`、不可见层跳过；空气露 `TerrainAtlas.SKY_COLOR`。
- ★ 图集与 tint 数学**复用游戏侧** `TerrainAtlas`（源砖 `assets/textures/structure.png`）—— 编辑器里看到的就是游戏里那一格，不是第二套渲染。
- 图集行表按当前地图全部非空描述符去重排序；`EditorDoc.changed` 里探测到**新描述符**才重建行表，`structure_changed` 全量重建。
- ★ 用 `ImageTexture.create_from_image` **重建**而不是 `update()`：`update()` 不刷新 CPU 侧 `image_storage`，
  `Texture2D.get_image()` 会读到旧像素 ⇒ 像素断言假红/假绿（探针已踩过）。
- 缩放/平移/尺寸变化都触发重建；网格线（64px 格线、地图 0 边接缝高亮）与画刷框在 `_draw()` 里画。

## 4. 文档模型与撤销

- 撤销条目 = `{layer, idxs:PackedInt32Array, before, after, color:bool}`（**稀疏 cells**，不是整层快照）：
  环面回绕的笔画也能精确回放，1.9M 子格的大图不炸内存。
- 双上限：`undo_capacity = 60` 条 + `undo_cells_budget = 2_000_000` cells（超了丢最旧；单条就超预算时保留最新一条）。
- `begin_stroke()/end_stroke()` 把连续鼠标拖动合并成一条；空笔画不产生条目；`undo()` 用**条目里的层**写回（不是 `active_layer`）。
- 层 0-2 读写 `desc`（描述符）；层 3-6 读写 `rgba`（u32 `0xRRGGBBAA`，存 `PackedInt32Array` 会变负数是正常的）。
  颜色层缺席时由 `EditorMap.ensure_layer` 按需建并补 `layer_flags`；**纹理层缺席绝不补**（旧文件就是没有那层）。
- `dirty`：任何成功改动置 true；`load_map/new_map` 清栈并置 false；undo 不回退 dirty（未落盘）。

## 5. 读写门面（`EditorIO`）

- `open_path`：按 `EditorCodec.MAGIC` 分流 —— 二进制走 `EditorCodec.decode_map` + **读时 `EditorLegacy.migrate_map`**；
  文本走 `EditorV3.parse_v3_text` + `migrate_v3`（v3 / 旧字母格式由它自己识别）。返回 `source ∈ {v4,v3,legacy}`。
- `save_path`：先 `EditorValidate.validate_map` —— **errors 非空就拒写**（不写盘、逐条返回）；再 `EditorCodec.encode_map`（默认压缩）；
  自动建父目录。`res://` 拒写（导出后只读），默认落 `user://maps/<sanitize>.cyrm`。
- `list_maps`：`user://maps` + `res://maps` + exe 同目录三处的 `*.cyrm`，去重排序。
- 打开时把 `validate()` 的 warnings 带出来（只提示不阻止）；保存成功也回传 warnings。

## 6. 场景与交互

- 顶栏：新建（名字/宽/高，`EditorValidate.clamp_map_size` 钳制）· 打开（列出 `list_maps`）· 保存（有路径直接写，否则「保存为」）· 校验 · 导出（选 `user://maps` 或 exe 同目录）· 导出并加载（写盘 + 设为单人地图 + 回单人开局）· 返回主菜单。
- 右栏：7 层（点名字 = 当前编辑层；勾选框 = 显示/隐藏）· 工具（画笔/橡皮/直线/矩形/油漆桶/吸管）· 画刷格数 · 调色板（`data/tile_defs.json` 的 tiles，缩略图取 `TerrainAtlas.source_image()`）· 校验/消息输出。
- 状态栏：消息 · 尺寸 · 当前层 · 工具 · 光标子格（环面归一化）· 当前值 · 缩放 · 未保存标记。
- 快捷键走**独立 `editor_` 前缀 InputMap**（`editor_undo/redo/save/open/zoom_in/zoom_out`），不与游戏 action 混。
- 左键落笔；中键或空格拖动只平移（不发 `pointer_*`）；滚轮以鼠标为锚缩放。

## 7. 守卫

| 支 | 判词 | 条数闸 | 钉什么 |
|---|---|---|---|
| `tests/smoke/editor_doc_smoke.gd` | `EDITOR DOC SMOKE: OK(93 条断言)` | 93 | 7 层建图 / 环面 / Bresenham / 4 邻接与接缝油漆桶 / 颜色层 u32 / undo 往返与合并 / 栈上限 / load_map 清栈 / validate+to_bytes |
| `tests/smoke/editor_io_smoke.gd` | `EDITOR IO SMOKE: OK(53 条断言)` | 53 | v4 7 层读入 / legacy 读时迁移 / v3 与旧字母文本 / 坏文件 / 保存确定性 / 校验拒写 / 三处目录 / 默认落点 / **P3 导出落点与 res:// 拒写** |
| `tests/probe/editor_canvas_probe.tscn` | `EDITOR CANVAS PROBE: ALL-OK(27 条断言)` | 27 | 视口纹理尺寸 / `screen_to_subcell` 手算 / 鼠标锚缩放 / 层可见与压暗 / 颜色层与纹理层像素 / `pointer_down` / 新 desc 重建图集 / 空 doc 安全 |
| `tests/probe/editor_scene_probe.tscn` | `EDITOR SCENE PROBE: ALL-OK(25 条断言)` | 25 | 真实例化场景：打开 `maps/newfactory.cyrm` → 改一格 → undo/redo → 保存 → 重开 → 再保存**逐字节相等**；校验形状；画布纹理非空；**P3 导出并加载后 `Settings.sp_map_path`（含 settings.cfg 持久化）/ `MazeGenerator.map_file_path()` 指向该文件、PvP 地图设置不变** |

- 产品侧另有两条**真导出**才能回答的检查（不在默认批里，跑在 `tools/build_release.py`，见 §10）。

- 场景探针就是 P2 的验收口径（`editor_scene_probe` 的 ② 组）；判据一律 grep 判词，退出码不是判据。
- 跑法：`Godot --headless --path . -s res://tests/smoke/<支>.gd`（冒烟）、
  `Godot --headless --path . --quit-after 3600 res://tests/probe/<支>.tscn`（场景探针）；
  默认批 `bash tests/run_all.sh` 会自动收录（`tests/smoke/*.gd` 与 `tests/probe/*.tscn` 两个 glob），跑批纪律见 [`tests/README.md`](../../tests/README.md)。

## 8. 已知边界（照实写）

- **入口只在导出的客户端里出现**（P5）：主菜单 `_wire_menu()` 用
  `OS.has_feature("editor") and OS.has_feature("template")` 判定 —— 单用 `editor` 在编辑器二进制里恒真（Godot
  `core/os/os.cpp` 的 `TOOLS_ENABLED` 分支），会把开发态菜单版式也改掉。开发态 / 服务端 / Web 都看不到按钮。
- 「导出并加载」= 保存 → `Settings.sp_map_path` → `Settings.save()` → `MazeGenerator.set_map_file()` →
  回 `level_0`（单人流程；PvP 地图仍由大厅/服务端下发的 path 覆盖，不受影响）。
- **没有真渲染预览**：未接 `PostProcess` / `ParallaxBg`；画布用同一份地形图集 + `SKY_COLOR` 近似，背景四层按颜色层出（不是视差）。
- 未做：选区/复制粘贴/镜像、渐变工具、出生点与敌人 meta 的可视化编辑、缩略图列表、脏区优化（当前每次 refresh 重建整张视口纹理，超大图连续笔画可能掉帧）。
- v3 文本 / 旧字母格式打开后另存为写的是 **v4**（`EditorV3` 迁移是单向的，与计划一致）。
- 画布的图集行数 = 本图去重描述符数；一张图里出现大量 hue/bri 变体会让图集体积线性增长（16×16/行），极端图可能吃显存。

## 9. 计划 P6 已执行（2026-11-09）

`level_editor/`（浏览器编辑器 146 个跟踪文件）与其四份旧文档（`editor-ui/render/io/server.md`）已删除；
`.cyrm` 只剩 GDScript 一份实现。仍待补的编辑器功能见 §8「未做」那一行；P6 的档 3 评审
（地图格式写盘路径 / forced map 影响面 / 两份导出的裁剪面）结论写在当次提交信息与 `docs/eng/editor-core.md`。

## 10. 两份导出（P5，2026-11-09）

| 产物 | 预设 | `custom_features` | 编辑器入口 | 编辑器资源 |
|---|---|---|---|---|
| 客户端 | `Windows Desktop` / `macOS` | `editor` | 主菜单有（按钮在 Beta 之后） | 在 pck 里 |
| 服务端 | `Dedicated Server` / `macOS Server` | `serverui` | 无 | `exclude_filter` 排除 `scenes/editor/*,core/editor/*` |
| Web | `Web` | `""` | 无（计划明确不做 Godot 编辑器的 web 导出） | —— |

- 入口判定 = `OS.has_feature("editor") and OS.has_feature("template")`（见 §8 第一条的坑）。
- 产物自检（`tools/build_release.py` 内置两条；开关在 `--` 之后）：
  - 客户端：`The Cyancular Ruins.exe --headless --quit-after 120 -- --editor-entry-report` ⇒ 必须打 `[editor] feature=true entry=true`；
  - 服务端：主场景是 `server_main`，冒烟脚本在同目录写 `override.cfg` 把 `run/main_scene(.serverui/.dedicated_server)` 指回
    `main_menu.tscn`（导出模板按 `disable_path_overrides=yes` 编译，**不认**命令行场景位置参数），⇒ 必须打
    `[editor] feature=false entry=false`。
- 资源层「服务端 pck 不含编辑器」只有真导出验得了（推理不可靠）：可用 `Godot --headless --export-pack <preset> <out.pck>`
  后二进制 grep `scenes/editor/` / `core/editor/`（P5 落地时实测：客户端各 11/70 条，服务端 0 条）。
- 构建/冒烟/归档的完整流程见 [`RELEASE.md`](../../RELEASE.md)「两份产物」块；版本号仍唯一来源 `project.godot`。
