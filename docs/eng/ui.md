# UI(调色板 / 菜单语汇 / HUD / 小地图 / 大厅版式)

> 与源码冲突时以源码为准,读前先 `grep` 复核。

## 调色板与 UiFactory

- `ui/factory/ui_factory.gd` 是 UI 的唯一工厂与唯一调色板;颜色只在那里定义,各页面一律引用,不写 `Color(...)` 字面量;色值统一写 hex(`Color("#RRGGBB")`)。
- token:基础 `C_BG` / `C_SURFACE` / `C_ROW` / `C_FIELD` / `C_BTN_FILL(_HI/_DN)` / `C_BORDER(_DIM)` / `C_ACCENT` / `C_DANGER` / `C_TEXT(_DIM)` / `C_WHITE` / `C_WARN`;HUD `C_PLATE` / `C_SLOT_EMPTY` / `C_SLOT_FILLED` / `C_SLOT_ACTIVE` / `C_TEAM_A` / `C_TEAM_B` / `C_GRACE` / `C_MODE_TEAM` / `C_MODE_ROYALE`;菜单 `C_HEADER` / `C_INNER` / `C_EDGE` / `C_GOLD` / `C_TEXT_MUTE`。
- 字号必须是 16 的倍数(16 / 32 / 48 / 128…),`style_control` 会 assert;`separation` / `custom_minimum_size` 这类布局度量不要求 16 对齐。
- 字体:拉丁 `assets/fonts/less_perfect_dos_vga.ttf`(8×16 DOS 位图);汉字 `assets/fonts/unifont-17.0.05.otf`(Unifont,SIL OFL 1.1)。两者都套 `PixelFont.shared()`(关抗锯齿 / 微调 / 子像素);换字体只改 `core/present/pixel_font.gd` 的 `CJK_FONT_PATH`,并重算 `max_units` / `BOARD_W` / `NAME_UNITS`。
- 菜单语汇:`menu_panel()`(两层嵌套 PanelContainer:外深线 + 内亮线,内容加进 `Body`,默认 padding 64/46)、`menu_button()`、`header_strip()`(内边距 右/上/下 40/20/20、左 0)。`_btn_box` 内容边距 40/20 ⇒ 32 号字按钮最低高度 72,绝对定位的调用方(`scenes/mp_lobby/room_list.gd`)必须自己把行高抬到 72;大厅页左右留白 `PAGE_MARGIN = 76`。
- 菜单 token 只给菜单系(主菜单 / 设置 / 信息 / 统一大厅 / Beta / 结算页 / 暂停菜单)用;HUD 读的 `C_ACCENT` / `C_TEXT` / `C_TEXT_DIM` / `C_SURFACE` / `C_BORDER` / `C_PLATE` / `C_SLOT_*` / `C_TEAM_*` / `C_GRACE` / `C_MODE_*` 不许改。
- 按钮 = 暗填充 + 2px 亮描边、直角(`style_button(b, variant)`,`variant="quiet"` 是弱化项);描边对页面底与对填充都 ≥ 3:1。其余工厂方法:`panel_box()`(**不透明**)、`row_box()` / `style_row_button()`、`style_line_edit()`、`style_check()`(自绘开关图标)、`style_slider()`。
- 开关 / 勾选框行 = 定宽标签列 + 紧邻开关(`HBoxContainer`,标签 `custom_minimum_size.x` 固定);裸 `CheckButton` 塞进宽容器会被拉到全宽。
- 生成物:改过 `UiFactory` 的菜单系样式后必须重跑 `tools/gen_menu_theme.gd` 重建 `ui/theme/menu_theme.tres`。

## HUD

- 对局内 HUD 元素一律垫半透明深底板,源 = `UiFactory.C_PLATE`(黑 0.1)。四个 `.gd` 落点是别名 / 引用:`ui/hud/hud.gd`、`ui/hud/weapon_slots.gd`、`ui/factory/world_label.gd` 的 `PLATE_COLOR`,`ui/hud/royale_hud.gd` 的 `_plate_box()`。两个 `.tscn`(`pvp_hud.tscn` / `team_hud.tscn` 的 `Plate`)结构上引用不到 GDScript const,保留字面量,必须与 `C_PLATE` 逐位相等;改底板色 = 调色板 + 两处 `.tscn`。
- 例外一:大乱斗排行榜 `royale_hud._board_bg` = 0.25。例外二:右上角击杀计数器(青色 `000`)不垫底板,三个模式一起生效。
- 不垫底板只能靠 `draw_center = false`:`StyleBoxFlat` 默认底色是不透明灰 (0.6, 0.6, 0.6, 1),只删 `bg_color` 会变成实心灰板。氧条那组底板与条 / 空槽同一 tween 淡入淡出,满氧时整组不出现。
- `C_WARN` 只表「弹夹见底」一个语义:满弹用中性色、装填进度用强调青、丢弃进度用 `C_DANGER`。
- 武器槽位 `ui/hud/weapon_slots.gd`(`WeaponSlots`):左下角 4×2,三态 `C_SLOT_EMPTY` / `C_SLOT_FILLED` / `C_SLOT_ACTIVE`,三档 alpha 0.5;`WeaponSlots.attach_to(...)` 生产里只有 `ui/hud/hud.gd` 一个调用点(单机 / 1v1 / 大乱斗都实例化 `level_0.tscn`)。浅底上「越暗越醒目」:未占贴底板 → 已占中 → 手持最跳;空格必须看得见但后退。
- 对局内 HUD(`pvp_hud.tscn` + `royale_hud.gd` + `team_hud.gd`)直接压在地图上,同样一律垫深底板;记分条用 `ScoreWrap`(PanelContainer)按内容撑开。
- 大乱斗排行榜一行五段定宽:昵称走 `UiFactory.fit_name(名字, 14)`(按显示宽度截断 + 补满);单位宽度 = 半角 8px / 汉字 16px。

## 小地图

- `ui/hud/minimap.gd` + `ui/hud/minimap_circle.gdshader`:以玩家为中心的圆形视野,`CanvasLayer` layer 131;挂载点只有三个 —— `scenes/pvp_game.gd`(1v1)、`scenes/royale_game.gd`、`scenes/team_game.gd`。单机 `level_0` 没有小地图。
- `setup_multi` 的四个参数全必填;要恒 `ENEMY_COLOR` 就显式传空 `Callable()`。生产调用点只有 `royale_game` / `team_game`;1v1 走另一个函数 `setup`。
- `RANGE_CELLS = 50` 决定圆形范围,`RADIUS_PX = 140` 决定屏幕半径,`PX_PER_CELL = RADIUS_PX / RANGE_CELLS`(2.8);单独改 `RANGE_CELLS` 只换缩放、圆的大小不变。
- 地形贴图 cols×rows、四周无留白,采样器开 `repeat_enable` ⇒ 环面免费,不铺 3×3 副本。点位走 `GridPathfinder.toroidal_delta_px(玩家, 目标, W, H)`(注意 a→b 的参数顺序),超过 `RADIUS_PX` 不显示。
- 开关:`Settings.pvp_show_minimap`(是否挂载)、`pvp_minimap_show_enemy`(是否显示他人点;3v3 下连队友点一起关)。
- 两个颜色提供器必须共用同一套过滤 `_minimap_entries()`:按下标取色,各写一份 `for` 会在副本 `queue_free` 窗口错位一格。
- 大乱斗他人点走头顶 ID 同源的 `ROLE_COLORS[(role - 1) % size]`。「我」那个点:1v1 / 大乱斗用 `SELF_COLOR`(无描边);3v3 用队色 + 一圈白描边(`RING_SELF_PX = 4`);队色必须每帧求值(由 `match_sync` 下发,比小地图建立晚)。
- 留白 `EDGE = 24` / `EDGE_BOTTOM = 72`:右下角是延迟条(`font_size` 32,矩形上沿 y = 1367、左沿 x = 1784),小地图 layer 131 画在 PvpHud(130)之上,不可盖住它。
- `_ready` 时 `current_grid` 为空会 `set_process(false)`,没有重建路径。

## 大厅与菜单

- 主菜单只有一颗「多 人 模 式」→ `scenes/mp_lobby.tscn`。`LobbyPage`(`scenes/lobby_page.gd`)是统一大厅基类:`mp_lobby` 只留版式与三模式分派,「连大厅 → 列房间 → 配对了转连 worker」的状态机、字段、两个设置区块、回局路径、超时梯都在基类。
- 模式差异收在 `_mode`(筛选)与 `_current_mode`(所在房)两个量上;页内按 `全部 / 1v1 / 3v3 / 大乱斗` 筛选,建房时才选模式。
- 列表并发调三次现有列房入口(`on_list_rooms` / `royale_list` / `team_list`),前端合并打标;载荷扩 5 个键 `is_public` / `host` / `map` / `match_time`(大乱斗)/ `team_counts`(3v3),另有 `Wire.room_map`(仅列表展示)。`map` 与 `player_options.map` 是两个真值。
- 房卡可点性次序:先 `can_rejoin_to(code, mode)`,再「对局中 ⇒ 禁用」;对局中的卡整体压暗 + 不接 handler 也不吃焦点。
- 创建弹层:1v1 隐藏「公开/私密 + 邀请码」整行(`create_room` 是冻结签名、服务端永远建公开房);3v3 隐藏禁用武器行(那两个勾选框写 `Settings.pvp_disabled_weapons`,会影响另两个模式)。
- 等待室一个面板按模式渲染三种形态(1v1 名单+退出 / 大乱斗 名单+开始+退出 / 3v3 两队+未选边+选边+开始+退出);进房置 `_in_room` 并收起「＋创建房间」「加入房间」两颗入口。
- 1v1 不上报 `time`:`PvpSession.beta_mode` 是会话级,而 1v1 房无法被 beta 隔离。

## 主菜单背景

- 背景 = `TerrainAtlas.bake_map_image()` 烘出的真实地形图(`BG_CELL_PX = 32`,与 `Level0` 同一份图集)+ `core/present/menu_fisheye.gdshader` 的逐像素鱼眼重映射(`repeat_enable` 让采样越界绕到地图另一头)。运动学在脚本里,每帧喂 `view_center` / `rot_angle`:随机路径段 + 缓入缓出 + 0°↔`SEG_TURN_DEG`(120°)来回摆。`SEGMENT_SEC = 48.0`。
- 取景 `BG_VIEW_CELLS = 26.6667`(1920 宽 ⇒ 72 屏幕像素/格,玩家镜头是 48px/格);`blur_radius = BG_BLUR_RADIUS_PX`(4.0)。
- shader 默认值:`fisheye = 0.85` / `dim = 0.60` / `vignette = 0.30` / `desat = 0.20` / `breathe_amp = 0.012` / `aberration = 0.020`。`dim` 的语义是「压暗多少」(`col = mix(col, vec3(0.0), dim)`),0 = 不压、1 = 全黑;脚本不覆盖它。
- 本 shader 只服务主菜单背景,改它不碰任何一局游戏的一个像素。

## 显示设置

- 基准 1920×1440 是逻辑空间;`window/stretch/aspect="keep"` + `mode="viewport"`(硬边)⇒ 窗口尺寸 ≠ 基准时逻辑空间仍是 1920×1440(等比缩放 + 黑边)。`mp_lobby.tscn` 的绝对定位、`minimap.gd` 的 `1920.0 - …`、`main_menu.gd` 的 `BG_VIEW_CELLS` 都不用改。
- `Settings.DISPLAY_RESOLUTIONS` 四档:1280×960 / 1600×1200 / 1920×1440 / 2560×1920;`display_res_index` / `display_fullscreen` 由 `Settings.apply_display()` 应用(headless 早退);默认窗口在 2560×1600 屏上 1:1。
- `apply_display()` 启动时按存档设窗口 ⇒ `--resolution` 会被它顶掉;要指定尺寸得先改 `user://settings.cfg` 的 `display/res_index`。

## 对局内状态横幅(`ui/hud/status_banner.gd`)

- 层位 140 只写在 `ui/hud/status_banner.tscn` 里;必须高于 130(对局 HUD)与 131(小地图),低于 145(暂停菜单)与 150(结算页)。
- 纵向三带互不重叠:1v1 记分条 `y ∈ [16, 68]`(高 52);其下 `GraceWrap` `y ∈ [72, 124]`(高 52);状态横幅 `y ∈ [128, 204]`(高 76 = 标签 36 + 上下各 20)⇒ `TOP_OFFSET := 128.0`。
- `Label` 行高 = `max(字体在该字号的 get_height, ascent + descent)`,随内容变:纯拉丁行(`PingWrap` 的 `24ms`)33 ⇒ 面板 49;含 CJK 的行 36 ⇒ 面板 52。
- 横向不固定:面板宽 = 文字宽 + 左右各 28px,居中占 `x ∈ [960 - w/2, 960 + w/2]`,由 `_center_panel()` 在入树后按 `get_combined_minimum_size()` 现算(未入树时偏移量会全塌成 0)。
- 大乱斗排行榜底板左缘 `x = 1184`,最长状态文案面板宽 568px ⇒ 右端 1244,横幅右侧侵入排行榜 60px(只有大乱斗看得见)。不可下挪 `TOP_OFFSET`,否则落进屏幕中部。
