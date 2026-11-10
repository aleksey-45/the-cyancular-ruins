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
| 真渲染预览 | [`scenes/editor/editor_preview.gd`](../../scenes/editor/editor_preview.gd) | 复用游戏管线（TerrainAtlas tileset + ParallaxBg + PostProcess）的预览；三个 SubViewport 合成后贴回画布区域 |
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

- 顶栏：新建（名字/宽/高，`EditorValidate.clamp_map_size` 钳制）· 打开（列出 `list_maps`，卡片带 `MapCatalog` 缩略图与显示名）· 保存（有路径直接写，否则「保存为」）· 校验 · 导出（选 `user://maps` 或 exe 同目录）· 导出并加载（写盘 + 设为单人地图 + 回单人开局）· **预览开关** · 返回主菜单。
- 左栏：**竖直工具列**（画笔/橡皮/直线/矩形/油漆桶/吸管/选框/渐变；2026-11-10 从横条改成 Photoshop/Inkscape/Aseprite 式 tool palette，选中态用 `BtnAccent` 边框）。右栏 4 个 Tab：**图层**（7 层 + 显示开关）· **调色板**（纹理缩略图 · 画刷格数下拉 · 颜色：画笔/渐变终点）· **选区 & meta**（选区信息 + 6 剪贴板按钮 + 5 个 meta 模式 + 计数 + 清空）· **校验消息**（校验 + 输出）。\n- 编辑器根挂 `ui/theme/menu_theme.tres`：Tab、下拉（OptionButton/SpinBox 已换 OptionButton）、滚动条、工具提示、`ConfirmationDialog` 全部走同一套像素字体与 16 号字（2026-11-10 字体统一）。
- 状态栏：消息 · 尺寸 · 当前层 · 工具 · 光标子格（环面归一化）· 当前值 · 缩放 · 未保存标记。
- 快捷键走**独立 `editor_` 前缀 InputMap**（`editor_undo/redo/save/open/zoom_in/zoom_out/copy/cut/paste/delete/mirror_h/mirror_v`），不与游戏 action 混：`Ctrl+Z/Y/S/O/C/X/V`、`Delete`、`H`/`V`、`+`/`-`。
- 左键落笔；中键或空格拖动只平移（不发 `pointer_*`）；滚轮以鼠标为锚缩放。

## 7. 守卫

| 支 | 判词 | 条数闸 | 钉什么 |
|---|---|---|---|
| `tests/smoke/editor_doc_smoke.gd` | `EDITOR DOC SMOKE: OK(183 条断言)` | 183 | 7 层建图 / 环面 / Bresenham / 4 邻接与接缝油漆桶 / 颜色层 u32 / undo 往返与合并 / 栈上限 / load_map 清栈 / validate+to_bytes / **选区剪贴板镜像渐变 / meta 快照与 undo** |
| `tests/smoke/editor_io_smoke.gd` | `EDITOR IO SMOKE: OK(53 条断言)` | 53 | v4 7 层读入 / legacy 读时迁移 / v3 与旧字母文本 / 坏文件 / 保存确定性 / 校验拒写 / 三处目录 / 默认落点 / **P3 导出落点与 res:// 拒写** |
| `tests/probe/editor_canvas_probe.tscn` | `EDITOR CANVAS PROBE: ALL-OK(48 条断言)` | 48 | 上述 + **脏区刷新与全量 refresh 逐像素一致（单格/颜色层/跨接缝/小图多环面副本）** + 选区框几何 + meta 标记锚点 + `_draw` 真跑 |
| `tests/probe/editor_scene_probe.tscn` | `EDITOR SCENE PROBE: ALL-OK(36 条断言)` | 36 | 真实例化场景：打开 `maps/newfactory.cyrm` → 改一格 → undo/redo → 保存 → 重开 → 再保存**逐字节相等**；P3 导出并加载的 `Settings.sp_map_path`/`map_file_path()`；**后置项：选区/复制/粘贴/镜像/渐变/meta/预览开关** |
| `tests/probe/editor_preview_probe.tscn` | `EDITOR PREVIEW PROBE: ALL-OK(21 条断言)` | 21 | 真渲染预览的结构统计（773 瓦片 / 背景 1 层 / post 存在）/ 相机口径 / 显隐切换 / refresh 幂等 / doc 信号接线 |

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
- **真渲染预览**（`editor_preview.gd`）：复用游戏管线（`TerrainAtlas` 图集/TileSet + `ParallaxBg` 背景四层 + `PostProcess`），世界/背景/合成三个 SubViewport 串起来把合成图贴回画布区域。**headless（dummy 渲染）只验结构/相机/信号，像素要非 headless 人眼**。
- 其余边界：画布脏区只重画变化的子格（图集因出现新 desc 需要平移行号时退回全量）；缩略图复用 `MapCatalog` 的低分辨率格级图（不是 16px 实拍）；预览不摆 3×3 环面副本（相机出地图边界会看到空区）。
- v3 文本 / 旧字母格式打开后另存为写的是 **v4**（`EditorV3` 迁移是单向的，与计划一致）。
- 画布的图集行数 = 本图去重描述符数；一张图里出现大量 hue/bri 变体会让图集体积线性增长（16×16/行），极端图可能吃显存。

## 9. 计划 P6 已执行（2026-11-09）

`level_editor/`（浏览器编辑器 146 个跟踪文件）与其四份旧文档（`editor-ui/render/io/server.md`）已删除；
`.cyrm` 只剩 GDScript 一份实现。编辑器后置项已在 §11 补齐；P6 的档 3 评审
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

## 11. 后置项补全（2026-11-09）

| 项 | 实现 | 口径 / 边界 |
|---|---|---|
| 选区 | `EditorDoc.selection`（子格 `Rect2i`，越界裁剪不回绕）+ 画布虚线框 | 只在 `_draw` 叠加层，不影响 `view_image()`；根在 `doc.set_selection` 后自己喂 `canvas.set_selection` |
| 剪贴板 | `copy_selection` / `cut_selection` / `paste_clipboard(at_cell)` / `clear_selection_cells` | 与旧 JS 同语义：类型互斥（纹理↔颜色不互转）、粘贴以**格**为左上角、环面回绕；粘贴/剪切/清除各一条 undo |
| 镜像 | `mirror_selection("h"|"v")` | **只翻选区**（不是整层）；无变化不产生 undo；非法轴返回 `{ok:false}` |
| 渐变 | `paint_gradient(a_sub, b_sub, rgba0, rgba1, clip_selection=false)` | 只对颜色层 3-6；t = 子格在 a→b 上的投影/|b−a|²（夹 0..1），逐通道四舍五入；旧 JS `createGradientJob` 同口径 |
| meta 可视化编辑 | `add_player/remove_player_at/add_respawn(side)/remove_respawn_at/add_enemy/remove_enemy_at/clear_meta/meta_snapshot` | 坐标是**格**；快照式 undo 条目（`kind:"meta"`）、只发 `meta_changed`；画布画 P1/P2、R1/R2、敌人红点+首字母 |
| 真渲染预览 | `EditorPreview`（`setup/refresh/set_camera/set_active/stats`，无 class_name） | 3 个 SubViewport（世界/背景/合成）+ `TileMapLayer`×3 + `ParallaxBg` + `PostProcess`；相机公式 `Camera2D.zoom = zoom/16`、`position = origin*16 + viewport_size*0.5/(zoom/16)`；隐藏时 `set_active(false)` 停渲染 |
| 缩略图列表 | 打开弹层每张图 `MapCatalog.texture(path, 2)` + `display_name` | 复用主菜单选图同一套简图/缓存，不另做管线；不覆盖的图（如 user:// 未在 catalog 目录里）仍可打开，只是缩略图为 `MapCatalog` 的兜底图 |
| 脏区优化 | `EditorCanvas.refresh_region(sub_rect)` + `_on_doc_changed` 按 bbox 局部重画 | 环面副本 k 范围按可见世界动态算；与全量 `refresh()` **逐像素一致**由探针钉住；出现新 desc（图集行号会整体平移）时退回全量 |

- meta 编辑**不进** `changed`（没有 cells 变更），面板/标记靠 `doc.meta_changed` 刷新；保存按钮看 `doc.dirty`。
- 本次没有新增「浏览器编辑器对照」：预览/脏区/选区框都是 Godot 侧新写，headless 判据只到结构/像素一致性，观感仍需非 headless 人眼。
