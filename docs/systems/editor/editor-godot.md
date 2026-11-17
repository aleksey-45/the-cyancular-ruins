# Godot 编辑器场景（`core/editor` + `scenes/editor`，P2）

> P0/P1 把 `.cyrm` 编解码移植进 `core/editor/`（格式契约与模块表见 [`editor-core.md`](editor-core.md) §12）。
> 本文件记 **P2 编辑器场景**（2026-11-08 落地）：分层、坐标、渲染、撤销、读写、守卫、已知边界。
> 迁移过程与取舍见 [`editor-core.md`](editor-core.md) §14；历史（含已删的浏览器编辑器）一律看 `git log`。
> ★ 冲突以源码为准。

## 1. 分层与文件

| 层 | 文件 | 职责 |
|---|---|---|
| 文档模型 | [`core/editor/editor_doc.gd`](../../../core/editor/editor_doc.gd) | 地图字典 + 当前层 + 稀疏 cells 撤销栈 + 环面归一化 + `changed`/`structure_changed`/`history_changed` 信号；meta 单项删除/改敌人类型/扁平列表；纯逻辑、可 `-s` 测 |
| 读写门面 | [`core/editor/editor_io.gd`](../../../core/editor/editor_io.gd) | `open_path`（v4 二进制 / v3 文本 / 旧字母格式 + 读时 legacy 迁移）、`save_path`（校验 + 编码 + 写盘）、`default_target`、`list_maps` |
| 画布 | [`scenes/editor/editor_canvas.gd`](../../../scenes/editor/editor_canvas.gd) | 视口离屏层合成、相机（origin/zoom）、`screen_to_subcell`、层可见/压暗、网格与画刷框、`pointer_*` 信号；**手形平移 / 移动工具**（拖选区发几何信号、meta 标记命中测试与拖拽预览）、光标形状；**meta 模式抑制画刷框 / 渐变方向预览 / 小地图 + 右键跳转 / `center_on_subcell`** |
| 真渲染预览 | [`scenes/editor/editor_preview.gd`](../../../scenes/editor/editor_preview.gd) | 复用游戏管线（TerrainAtlas tileset + ParallaxBg + PostProcess）的预览；三个 SubViewport 合成后贴回画布区域 |
| UI 场景 | [`scenes/editor/editor_root.tscn`](../../../scenes/editor/editor_root.tscn) | **全部静态 UI**：顶栏（标题/`FileMenu`·`EditMenu`/**保存**/撤销/重做/**文件名+未保存标记**/**跳转**/**帮助**/视图/预览/返回）· **左栏**（工具网格 10 键 + 画刷 + 颜色/纹理调色板**按层渐进披露** + 操作提示）· 中 `CanvasHost`+`EditorCanvas` · **右栏**（`LayersCard` 7 层常驻 + 2 Tab：**选区 / 地图事件**、校验消息；meta 列表可单条删除/改类型）· 状态栏（消息 + 信息 + 缩放控件）；根挂 `ui/theme/menu_theme.tres`，功能节点 `unique_name_in_owner` |
| 场景根逻辑 | [`scenes/editor/editor_root.gd`](../../../scenes/editor/editor_root.gd) | 装配 + 接线 + 公开 API（`open_path`/`save_to`/`validate`/`export_to`/`export_and_load`/`get_doc`/`get_editor_canvas`/`set_preview`/`current_path`/`new_map`）；撤销/重做可用态、工具快捷键、状态栏缩放、按层适用性/渐进披露、meta 列表、校验自动切 Tab；不建静态控件 |
| 工具层 | [`scenes/editor/editor_tools.gd`](../../../scenes/editor/editor_tools.gd) | 工具状态（含手形/移动）+ 画布指针 → `EditorDoc` 写入 + 选区拖拽 + meta 放置/拖动落点 + 敌人类型 + 渐变选区限制；只发信号（`message`/`tool_changed`/`paint_desc_changed`/`color_changed`/`meta_mode_changed`/`selection_changed`） |
| 命令层 | [`scenes/editor/editor_actions.gd`](../../../scenes/editor/editor_actions.gd) | 文件/编辑命令 + `ConfirmationDialog` 弹层内容（新建/打开/保存为/导出/**按格跳转**/**快捷键帮助**）+ **未保存改动拦截**（新建/打开/返回/关窗前确认）；读写仍走 `EditorIO` 与 root 公开 API |

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
- `move_selection_content(offset_sub)`（移动工具落点）：选区整块平移，**不环面回绕**（目标矩形必须完整在图内），
  先读源值再「源置 0、目标写源值」（重叠以目标值为准），恰好一条多值稀疏条目；缺席层 ⇒ 选区照移、`count=0`、不建层。
- `set_meta_position(kind,index,cell)`（拖动 meta 标记落点）：三 kind 严格、按格环面归一化、只改 x/y（保留
  `respawn.side` / `enemy.type`）、原地不动不入栈，一次拖动 = 一条 meta 快照条目。
- `remove_meta_at(kind,index)`（列表单条删除）：kind 三选一、越界/空表 false；原地删（其余条目保序）、一条 meta 快照条目。
- `set_meta_enemy_type(index,type)`（列表类型下拉）：只改 `enemies[index].type`、保留 x/y；同类型/空 type/越界 false 不入栈。
- `meta_entries()`：只读扁平列表（players → respawns → enemies，含 `kind/index/x/y/side/type`），返回新建字典，
  不产生 undo/信号/dirty；`index` 是**原数组下标**（损坏条目跳过时可能不连续），删除/改类型直接回传给上面两个 API。
- `dirty`：任何成功改动置 true；`load_map/new_map` 清栈并置 false；undo 不回退 dirty（未落盘）。
- `history_changed`（2026-11-12）：撤销条目**真正入栈**（`_commit_entry`，含笔画收尾）/ undo / redo / load_map 清栈时发；
  撤销/重做按钮的可用态只听它 —— `changed` 在笔画期间每一格都发，而条目要到 `end_stroke` 才入栈，只听 `changed` 会
  让「画完第一笔」后按钮一直是灰的。
- ★ 撤销移动只还原**格子**：选区框不是历史条目，撤销后 `doc.selection` 停在移动后的位置（与镜像/粘贴一致）。

## 5. 读写门面（`EditorIO`）

- `open_path`：按 `EditorCodec.MAGIC` 分流 —— 二进制走 `EditorCodec.decode_map` + **读时 `EditorLegacy.migrate_map`**；
  文本走 `EditorV3.parse_v3_text` + `migrate_v3`（v3 / 旧字母格式由它自己识别）。返回 `source ∈ {v4,v3,legacy}`。
- `save_path`：先 `EditorValidate.validate_map` —— **errors 非空就拒写**（不写盘、逐条返回）；再 `EditorCodec.encode_map`（默认压缩）；
  自动建父目录。`res://` 拒写（导出后只读），默认落 `user://maps/<sanitize>.cyrm`。
- `list_maps`：`user://maps` + `res://maps` + exe 同目录三处的 `*.cyrm`，去重排序。
- 打开时把 `validate()` 的 warnings 带出来（只提示不阻止）；保存成功也回传 warnings。

## 6. 场景与交互

- **布局（2026-11-12 UX 重排，2026-11-17 二次补全）**：顶栏（标题 · `文件 ▾` · `编辑 ▾` · **保存** · 撤销/重做 ·
  **文件名+未保存标记** · **跳转** · **帮助** · 视图/预览 · 返回）→ 中段 `Split` = **左栏｜画布｜右栏** → 状态栏。
  - **左栏** = 作画上下文常驻：工具网格（画笔/橡皮/直线/矩形/油漆桶/吸管/选框/**移动**/**手形**/渐变，2 列）+
    画刷格数 + **按层渐进披露**（纹理层只显示调色板；颜色层只显示画笔/渐变终点颜色，另一组整块隐藏）+ 操作提示。
  - **右栏** = 文档结构常驻：`LayersCard`（7 层 + 显示开关，**不随 Tab 切走**）+ `TabContainer` 2 页：
    **选区 / 地图事件**（选区信息 + 6 剪贴板按钮；meta 模式 + 敌人类型 + **已放置列表，可单条删除/改类型** + 计数 + 清空）、
    **校验消息**（校验 + 输出）。
  - 为什么这么分：画图时要同时看「当前层」和「当前纹理/颜色」，旧的 4 Tab 布局把图层和画刷塞进同一块 Tab 区，
    每次改画刷都要切走图层 —— 这是本轮返工的主因。
- **导航**：手形工具（`H`）左键直接平移；任何工具下 `空格`+左键拖或中键拖也平移（不发 `pointer_*`，不会顺手画一笔）；
  滚轮以鼠标为锚缩放；状态栏 `− / 百分比 / + / 适应` 四个控件与滚轮同源（百分比 = `zoom/16`）。
  **小地图**画在画布右上角（图幅 + meta 点 + 当前视口框），**右键点小地图跳转**；顶栏「跳转」/`Ctrl+G` 按格坐标跳。
- **移动工具（`V`）**：拖**选区内容**（选区框跟随；拖出图外由画布 clamp，doc 端再校验，不环面回绕）或拖
  **meta 标记**（出生点/复活点/敌人，命中半径 14px，拖动时标记跟鼠标、松手才按格落点）；两者各自一条 undo，
  拖动过程只画预览、不写 doc。
- **按当前层决定工具/面板适用性**：
  - 纹理层 0-2：纹理调色板可见；**渐变与两个颜色选择器隐藏**（不再常驻置灰）；吸管吸 `desc`（换画笔纹理）。
  - 颜色层 3-6：渐变与颜色选择器可见；**纹理调色板整块隐藏**；吸管吸 `RGBA`（换画笔颜色，并回写取色器）。
  - 切层后当前工具若变得不适用（渐变 → 纹理层）**自动切回画笔**并提示；快捷键 `T` 在纹理层被拒。
  - 画刷框颜色跟着当前层走：颜色层用当前画笔色（橡皮仍是红框），纹理层仍按描述符 tint。
  - **当前层的眼睛开关禁用**（画布恒显示 active 层）：避免「控件说关、画布还在画」。
- **渐变安全**：渐变**只作用于选区**（无选区直接拒绝并提示），拖动时画方向预览线，不再默认覆盖整层。
- **未保存拦截**：`doc.dirty` 时「新建 / 打开 / 返回 / **关窗（Alt+F4 或窗口 X，`NOTIFICATION_WM_CLOSE_REQUEST`）**」都先弹
  「有未保存的改动」确认（取消 = 什么都不做，确认才继续）；干净时不弹。编辑器根在 `_ready` 把 `auto_accept_quit`
  置 false、`_exit_tree` 还原（否则主菜单也关不掉窗口）。弹层是 `exclusive` 模态：开着时画布不能再改（避免确认后
  又变脏的 TOCTOU）。
- **校验结果**：校验/保存失败自动切到「校验消息」Tab，不再把错误藏在一个看不见的页里。
- **meta 放置模式**：若当前工具是手形/移动（画布接管指针），切换到放置模式时自动回到画笔，保证「点画布放置」可用；
  放置模式下画刷框被抑制；**点任一工具按钮自动退出放置模式**（两种模式不再同时高亮）。
- **预览与拖拽**：预览是盖在画布上的只读层；切到移动/手形时自动关预览（否则选区框/meta 标记被预览图盖住，拖拽没有反馈）。
- **快捷键**（独立 `editor_` 前缀 InputMap，不与游戏 action 混）：
  工具 `B/E/L/R/G/I/M/V/H/T`；`Ctrl+Z/Y` 撤销重做、`Ctrl+S/O` 保存/打开、`Ctrl+C/X/V` 选区复制/剪切/粘贴、
  `Delete` 清除选区、`Shift+H/V` 水平/垂直镜像、`+/-` 缩放、`F` 适应窗口、`Ctrl+G` 跳转、`F1` 快捷键帮助。
- 编辑器根挂 `ui/theme/menu_theme.tres`：Tab、下拉、滚动条、工具提示、`ConfirmationDialog` 全部走同一套像素字体与 16 号字。
- 状态栏分段：**消息**（`StatusText`）· **尺寸/层/工具/放置模式/子格/值**（`StatusInfo`）· 缩放控件 · 完整路径；
  文件名与未保存标记在顶栏 `DocLabel`（长名截断，tooltip 给全路径）。

## 7. 守卫

| 支 | 判词 | 钉什么 |
|---|---|---|
| `tests/unit/editor_doc_smoke.gd` | `EDITOR DOC SMOKE: OK` | 7 层建图 / 环面 / Bresenham / 4 邻接与接缝油漆桶 / 颜色层 u32 / undo 往返与合并 / 栈上限 / load_map 清栈 / validate+to_bytes |
| `tests/unit/editor_doc_extras_smoke.gd` | `EDITOR DOC EXTRAS SMOKE: OK` | 选区剪贴板镜像渐变 / meta 快照与 undo / 选区整块移动 / meta 单条改位置 / meta 单项删除·改敌人类型·扁平列表（夹具继承自 `editor_doc_smoke`） |
| `tests/unit/editor_io_smoke.gd` | `EDITOR IO SMOKE: OK` | v4 7 层读入 / legacy 读时迁移 / v3 与旧字母文本 / 坏文件 / 保存确定性 / 校验拒写 / 三处目录 / 默认落点 / **P3 导出落点与 res:// 拒写** |
| `tests/scene/editor_canvas_probe.tscn` | `EDITOR CANVAS PROBE: ALL-OK` | 上述 + **脏区刷新与全量 refresh 逐像素一致** + 选区框几何 + meta 标记锚点 + `_draw` 真跑 + **手形平移 / 移动 delta 与 clamp / meta 命中与 index / meta 模式抑制画刷框 / 渐变预览只画不写 / 小地图 rect + 右键跳转 + `center_on_subcell`** |
| `tests/scene/editor_scene_probe.tscn` | `EDITOR SCENE PROBE: ALL-OK` | 真实例化场景：打开 `maps/newfactory.cyrm` → 改一格 → undo/redo → 保存 → 重开 → 再保存**逐字节相等**；P3 导出并加载的 `Settings.sp_map_path`/`map_file_path()`；后置项：选区/复制/粘贴/镜像/渐变/meta/预览开关；**⑦ UI 行为：撤销按钮点击 + 笔画收尾后立即可用、工具快捷键（含 Ctrl+V/Shift+H 冲突）、按层渐进披露与吸管分语义、当前层眼睛禁用、meta 模式随工具退出、敌人类型合法 + 列表删除、保存按钮写盘、无选区渐变拒绝、无溢出**；**⑧ 未保存拦截（新建 / 确认 / 干净 / 关窗）**；**⑨ 移动工具端到端** |
| `tests/scene/editor_preview_probe.tscn` | `EDITOR PREVIEW PROBE: ALL-OK` | 真渲染预览的结构统计（773 瓦片 / 背景 1 层 / post 存在）/ 相机口径 / 显隐切换 / refresh 幂等 / doc 信号接线 |

> ★ 本轮新增断言按 [`test-economy.md`](../../workflow/test-economy.md) 只留「去掉实现会红、且指向具体缺陷」的行为/逻辑断言；
> 版式数值、控件存在性、宽高、菜单项条数等**不写自动化守卫**（配色/版式/观感按 [`tests.md`](../../workflow/tests.md) 只能人眼）。
> 场景探针 ⑦ 组因此从原来的「结构快照」缩成行为组；布局改动靠截图人工验收。

- 产品侧另有两条**真导出**才能回答的检查（不在默认批里，跑在 `tools/build_release.py`，见 §10）。

- 场景探针就是 P2 的验收口径（`editor_scene_probe` 的 ② 组）；判据一律 grep 判词，退出码不是判据。
- 跑法：`Godot --headless --path . -s res://tests/unit/<支>.gd`（冒烟）、
  `Godot --headless --path . --quit-after 3600 res://tests/scene/<支>.tscn`（场景探针）；
  默认批 `bash tests/run_all.sh` 会自动收录（`tests/unit/*.gd` 与 `tests/scene/*.tscn` 两个 glob），跑批纪律见 [`tests/README.md`](../../../tests/README.md)。

## 8. 已知边界（照实写）

- **入口判定 = `OS.has_feature("editor")`（2026-11-12 仓主决定）**：开发态（编辑器二进制里跑/直接跑工程）与导出客户端（`custom_features="editor"`）都显示按钮；服务端 / Web 没有该 feature ⇒ 不显示。开发态菜单因此比骨架多一个按钮，版式骨架仍只由生成器决定。
- 「导出并加载」= 保存 → `Settings.sp_map_path` → `Settings.save()` → `MazeGenerator.set_map_file()` →
  回 `level_0`（单人流程；PvP 地图仍由大厅/服务端下发的 path 覆盖，不受影响）。
- **真渲染预览**（`editor_preview.gd`）：复用游戏管线（`TerrainAtlas` 图集/TileSet + `ParallaxBg` 背景四层 + `PostProcess`），世界/背景/合成三个 SubViewport 串起来把合成图贴回画布区域。**headless（dummy 渲染）只验结构/相机/信号，像素要非 headless 人眼**。
- 其余边界：画布脏区只重画变化的子格（图集因出现新 desc 需要平移行号时退回全量）；缩略图复用 `MapCatalog` 的低分辨率格级图（不是 16px 实拍）；预览不摆 3×3 环面副本（相机出地图边界会看到空区）。
- 移动工具：拖选区**不环面回绕**（贴边即停，doc 端越界返回 `ok:false`）；拖动过程只画预览框/标记，松手才写一条 undo；
  撤销只还原格子，选区框停在移动后的位置（选区不是历史条目）。拖 meta 只在移动工具下生效（避免画图时误拖），命中半径 14px。
- 手形/空格平移要求画布有焦点（先点一下画布）；空格由画布 `_gui_input` 自己跟踪，根节点不处理空格。
- 关窗拦截只覆盖「编辑器场景在树里」的窗口关闭；`_exit_tree` 会把 `auto_accept_quit` 还原，避免污染主菜单。
  被其它进程 kill（任务管理器）不在此列。
- 未保存确认弹层是 `exclusive` 模态：弹层开着时画布不可改 —— 这就是「确认后不再复核 dirty」的替代（关闭 TOCTOU）。
- 按层适用性是**渐进披露**：另一组整块隐藏（不是只置灰）；纹理层仍能选中除渐变外的其它工具；颜色层的纹理调色板整体
  `visible=false`。渐变在纹理层被拒时给一行错误消息，不产生任何写入。
- **渐变只作用于选区**：无选区时 pointer_up 直接拒绝并提示；拖动中只画方向预览线（叠加层，不进视口图）。
- **小地图**固定在画布右上角（margin 12，最大 180×120，按图幅比例）；空图返回零尺寸不绘制；**右键**点小地图跳转，
  右键其它位置无动作；`center_on_subcell` 不夹地图边界（负坐标/环面外按原值平移），坐标跳转弹层才按格 clamp。
- **当前层的眼睛开关禁用**（画布语义：active 层恒可见）；要隐藏当前层需先切到其它层。切换层后被强制显示的开关会保持为开。
- meta 列表 `index` 是**原数组下标**（损坏条目被跳过时可能不连续），删除/改类型直接用 `meta_entries()` 返回的 `kind+index`；
  敌人类型下拉数据源 = `data/enemies.json`（旧图里未知 type 会临时加入下拉，未改动则原样保存）。
- 颜色层画笔默认色改为**不透明**（历史默认 alpha=0 会导致「画了没反应」）。
- 顶栏「保存」按钮等价 `文件→保存`（无当前路径时弹保存为）；文件名/未保存 `●` 在顶栏 `DocLabel`，长名截断只影响显示。
- 预览开着时切移动/手形会自动关预览（叠加层画在画布上、会被预览图盖住）；要边看真渲染边拖目前不支持。
- 调色板缩略图缩到 56px（源砖 64px，`INTERPOLATE_NEAREST`）以便 3 列塞进 268px 左栏；图标本身不是 16px 实拍。
- v3 文本 / 旧字母格式打开后另存为写的是 **v4**（`EditorV3` 迁移是单向的，与计划一致）。
- 画布的图集行数 = 本图去重描述符数；一张图里出现大量 hue/bri 变体会让图集体积线性增长（16×16/行），极端图可能吃显存。

## 9. 计划 P6 已执行（2026-11-09）

`level_editor/`（浏览器编辑器 146 个跟踪文件）与其四份旧文档（`editor-ui/render/io/server.md`）已删除；
`.cyrm` 只剩 GDScript 一份实现。编辑器后置项已在 §11 补齐；P6 的档 3 评审
（地图格式写盘路径 / forced map 影响面 / 两份导出的裁剪面）结论写在当次提交信息与 `docs/systems/editor/editor-core.md`。

## 10. 两份导出（P5，2026-11-09）

| 产物 | 预设 | `custom_features` | 编辑器入口 | 编辑器资源 |
|---|---|---|---|---|
| 客户端 | `Windows Desktop` / `macOS` | `editor` | 主菜单有（按钮在 Beta 之后） | 在 pck 里 |
| 服务端 | `Dedicated Server` / `macOS Server` | `serverui` | 无 | `exclude_filter` 排除 `scenes/editor/*,core/editor/*` |
| Web | `Web` | `""` | 无（计划明确不做 Godot 编辑器的 web 导出） | —— |

- 入口判定 = `OS.has_feature("editor")`：开发态（编辑器二进制）与客户端产物都建入口（2026-11-12 仓主决定）；服务端/Web 没有该 feature ⇒ 不建。
- 产物自检（`tools/build_release.py` 内置两条；开关在 `--` 之后）：
  - 客户端：`The Cyancular Ruins.exe --headless --quit-after 120 -- --editor-entry-report` ⇒ 必须打 `[editor] feature=true entry=true`；
  - 服务端：主场景是 `server_main`，冒烟脚本在同目录写 `override.cfg` 把 `run/main_scene(.serverui/.dedicated_server)` 指回
    `main_menu.tscn`（导出模板按 `disable_path_overrides=yes` 编译，**不认**命令行场景位置参数），⇒ 必须打
    `[editor] feature=false entry=false`。
- 资源层「服务端 pck 不含编辑器」只有真导出验得了（推理不可靠）：可用 `Godot --headless --export-pack <preset> <out.pck>`
  后二进制 grep `scenes/editor/` / `core/editor/`（P5 落地时实测：客户端各 11/70 条，服务端 0 条）。
- 构建/冒烟/归档的完整流程见 [`RELEASE.md`](../../../RELEASE.md)「两份产物」块；版本号仍唯一来源 `project.godot`。

## 11. 后置项补全（2026-11-09）

| 项 | 实现 | 口径 / 边界 |
|---|---|---|
| 选区 | `EditorDoc.selection`（子格 `Rect2i`，越界裁剪不回绕）+ 画布虚线框 | 只在 `_draw` 叠加层，不影响 `view_image()`；根在 `doc.set_selection` 后自己喂 `canvas.set_selection` |
| 剪贴板 | `copy_selection` / `cut_selection` / `paste_clipboard(at_cell)` / `clear_selection_cells` | 与旧 JS 同语义：类型互斥（纹理↔颜色不互转）、粘贴以**格**为左上角、环面回绕；粘贴/剪切/清除各一条 undo |
| 镜像 | `mirror_selection("h"|"v")` | **只翻选区**（不是整层）；无变化不产生 undo；非法轴返回 `{ok:false}` |
| 渐变 | `paint_gradient(a_sub, b_sub, rgba0, rgba1, clip_selection=false)` | 只对颜色层 3-6；t = 子格在 a→b 上的投影/|b−a|²（夹 0..1），逐通道四舍五入；**编辑器一律传 `clip_selection=true` 且无选区拒绝**（不再默认整层覆盖） |
| meta 可视化编辑 | `add_player/remove_player_at/add_respawn(side)/remove_respawn_at/add_enemy/remove_enemy_at/clear_meta/meta_snapshot/set_meta_position/remove_meta_at/set_meta_enemy_type/meta_entries` | 坐标是**格**；快照式 undo 条目（`kind:"meta"`）、只发 `meta_changed`；画布画 P1/P2、R1/R2、敌人红点+首字母；移动工具可拖标记；**右栏列表可单条删除/改敌人类型（2026-11-17）** |
| 真渲染预览 | `EditorPreview`（`setup/refresh/set_camera/set_active/stats`，无 class_name） | 3 个 SubViewport（世界/背景/合成）+ `TileMapLayer`×3 + `ParallaxBg` + `PostProcess`；相机公式 `Camera2D.zoom = zoom/16`、`position = origin*16 + viewport_size*0.5/(zoom/16)`；隐藏时 `set_active(false)` 停渲染 |
| 缩略图列表 | 打开弹层每张图 `MapCatalog.texture(path, 2)` + `display_name` | 复用主菜单选图同一套简图/缓存，不另做管线；不覆盖的图（如 user:// 未在 catalog 目录里）仍可打开，只是缩略图为 `MapCatalog` 的兜底图 |
| 脏区优化 | `EditorCanvas.refresh_region(sub_rect)` + `_on_doc_changed` 按 bbox 局部重画 | 环面副本 k 范围按可见世界动态算；与全量 `refresh()` **逐像素一致**由探针钉住；出现新 desc（图集行号会整体平移）时退回全量 |

- meta 编辑**不进** `changed`（没有 cells 变更），面板/标记靠 `doc.meta_changed` 刷新；保存按钮看 `doc.dirty`。
- 本次没有新增「浏览器编辑器对照」：预览/脏区/选区框都是 Godot 侧新写，headless 判据只到结构/像素一致性，观感仍需非 headless 人眼。

## 12. UI 场景化（T3，2026-11-10）

用户裁定「要用 .tscn 和 .tres，别再在 GDScript 里动态搭 UI」。落地形态：

- `scenes/editor/editor_root.tscn` = **真实场景树**（根挂 `ui/theme/menu_theme.tres`）：`Toolbar`（标题 + `FileMenu`/`EditMenu` + 保存/撤销/重做 + 文件名 + 跳转/帮助 + 视图 + 预览/返回）· **左栏** `LeftPanel`（2×5 工具网格 `ToolStrip` + 画刷 + **按层显示的颜色组或调色板** + 操作提示）· 中 `CanvasHost`（内含 `EditorCanvas` 节点）· **右栏** `RightSide`（`LayersCard` 7 层常驻 + `RightTabs` 2 Tab：**选区 / 地图事件**、校验消息；含敌人类型下拉 + meta 列表）· `StatusBar`（消息/信息/缩放）；功能节点全部 `unique_name_in_owner=true`，root 用 `%Name` 取。
- `editor_root.gd` **只做装配/接线/公开 API**（1270 → **581** 行）：静态控件不再 `new`；代码里只保留动态内容（调色板缩略图、菜单下拉项、弹层内容、预览节点、撤销/重做可用态、缩放标签）。
- 拆出两个无 `class_name` 的小组件（root `preload`）：`editor_tools.gd`（工具状态 + 画布指针 → `EditorDoc` 写入 + 选区拖拽 + meta 放置/拖动落点；只发信号）、`editor_actions.gd`（文件/编辑命令 + `ConfirmationDialog` 弹层 + 未保存拦截）。两者都不持有控件。
- 判据：`EDITOR SCENE PROBE: ALL-OK(60)`（⑦ UI 行为组 / ⑧ 未保存拦截 / ⑨ 移动工具端到端）/ `UI LAYOUT PROBE: ALL-OK(54)` / `RUN_ALL OK` / `check_naming.py` 绿；改前/改后截图 `.tmp/ui_shots/`（非 headless 人工对比）。
- 边界：`.tscn` 无法引用 `UiFactory.C_*`，所以全屏底色 `Bg` 在 tscn 里留一处字面量（全屏装饰例外），少数标签强调/弱化色由 root 在 `_ready` 按 `C_*` 覆盖 —— 不在 tscn 里另抄一套调色板。

## 13. UX 重排（2026-11-12）

用户反馈「图层和画笔放一起、没有移动拖拽」后做的一轮返工。改动面 = `scenes/editor/*` + `EditorDoc` 两个新 API + 三支守卫；
`.cyrm` 格式 / 协议 / 联机权威零改动（黄金夹具与游戏侧 `map_format_v4` 未触碰）。

- **信息架构**：旧的 4 Tab（图层 / 调色板 / 选区·meta / 校验消息）把「图层」和「画刷/纹理/颜色」塞进同一块 Tab 区，
  画图时要来回切 ⇒ 拆成「左栏 = 作画上下文（工具/画刷/颜色/调色板/操作提示）」「右栏 = 文档结构（图层常驻 + 选区·meta / 校验 2 Tab）」。
- **拖拽**：新增手形工具（H，左键平移）与移动工具（V，拖选区内容 / 拖 meta 标记）；空格/中键平移对任何工具保留。
  三处拖拽都只有一条 undo（移动落点由 `editor_tools` 写 doc），拖动过程只画预览。
- **发现性**：工具按钮悬停提示带单键快捷键；左栏底部常驻操作提示；状态栏加 `− / % / + / 适应`；校验/保存失败自动切到「校验消息」Tab。
- **按层适用性**：纹理层置灰渐变/颜色（调色板可用），颜色层置灰纹理调色板（渐变/颜色可用）；吸管在两层分别吸 desc / RGBA；
  切层后渐变自动回画笔。守卫在 `editor_scene_probe` ⑦ 组（颜色层启用、纹理层禁用、自动回画笔、T 被拒、颜色层吸管回写）。
- **安全网**：`doc.dirty` 时「新建 / 打开 / 返回」先弹确认，不再静默丢改动。
- **守卫**：`editor_doc_smoke` + `editor_doc_extras_smoke`（基础模型 / 选区与 meta 两个失败域）、`editor_canvas_probe`
  （手形 / 移动 delta 与 clamp / meta 命中 / meta 模式 / 渐变预览 / 小地图与跳转）、`editor_scene_probe`
  （UI 行为 + 未保存拦截 + 移动工具端到端 + 按层渐进披露 + meta 列表 + 保存按钮）；`ui_layout_probe` 不变。
  ★ 条数不抄:各支实际闸值以 `run_all.sh --list` 的 `GATE` 栏为准（抄过，漂过）。
  按 [`test-economy.md`](../../workflow/test-economy.md) 删掉了本轮一度加的版式/控件存在性/逐事件点断言（宽度、Tab 细节、图层常驻、
  控件条数、菜单项条数、按钮接线存在性、`history_changed` 每事件一条等）：这些答不清「去掉什么它才会红」或属于
  「版式不写」；布局观感靠截图人工验收。
- **非 headless 人工验收**：`python tools/ui_shots.py editor_root --size 1920x1440`（只截编辑器页，弹窗；不入默认批）。

## 14. UX 二次补全（2026-11-17）

针对一轮「产品设计原则」走查出的缺陷：

- **默认值安全**：颜色层画笔默认色改不透明（此前 alpha=0，画了像没反应）；渐变**只作用于选区**，无选区拒绝，
  拖动时画方向预览线（`set_gradient_preview`），不再一次拖拽覆盖整层。
- **主操作/状态可见**：顶栏加「保存」按钮、文件名 + 未保存 `●`（`DocLabel`）；状态栏拆成「消息 / 尺寸·层·工具·放置模式·
  子格·值」两段，不再一条长串被截断。
- **meta 闭环**：右栏「地图事件」加敌人类型下拉（数据源 `data/enemies.json`，不再写死非法 `"slime"`）+ 已放置列表
  （`meta_entries()` 渲染，逐条「删除」走 `remove_meta_at`，敌人可改类型走 `set_meta_enemy_type`）；删除/改类型都入 undo。
- **状态一致性**：当前层的眼睛开关禁用（画布语义 active 恒可见）；meta 放置模式下画刷框被抑制（`set_meta_mode_active`），
  点任一工具按钮自动退出放置模式（两种模式不再同时高亮）。
- **渐进披露**：左栏按当前层整块显示「颜色」或「纹理调色板」（不再把不可用那组常驻置灰）；右栏选区/地图事件加分组标题。
- **大图导航**：画布右上角小地图（图幅 + meta 点 + 视口框）+ 右键小地图跳转；顶栏「跳转」/`Ctrl+G` 按格跳转；
  调色板选中态改用按钮 pressed 样式 + 淡出非选中项，不再只靠 modulate。
- **帮助**：顶栏 `?`/`F1` 快捷键总览弹层。
- **守卫**：`EDITOR DOC SMOKE: OK(199)` / `EDITOR CANVAS PROBE: ALL-OK(56)` / `EDITOR SCENE PROBE: ALL-OK(60)`
  （新增 15 条，均按 test-economy 合并同类、只钉行为/逻辑）。
