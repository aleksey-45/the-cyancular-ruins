class_name CreatePanel
extends RefCounted

# 大厅页的「建房弹层」面板(2026-10-22 Task 10 纯搬移自 scenes/mp_lobby.gd)。
# 本文件负责:弹层显隐(压暗罩 + 本体)、三颗模式分段按钮(= 模式切换)、按模式变形(_apply_create_form 的显隐那一半、
# 建房载荷组装)、报到选项(player_options)的组装。★ RPC 一律留在页里(scenes/mp_lobby.gd)—— 本文件只产出载荷。
# ★ 节点路径(%语义名)、信号、文案逐字未动:弹层本体 / 压暗罩 / 标题行 / 双列版式 / 左列五行与右列两条区块标题都在 .tscn 里。
# ★ 建房弹层:压暗罩与弹层本体是两个节点 —— 罩子铺满整页(拦下背后的点击),本体居中。

var page: MpLobby = null
var form: OptionsForm = null
var panel: PanelContainer = null
var mask: ColorRect = null
# 三颗模式分段按钮(mode -> Button;ButtonGroup 互斥,模式色在骨架里)。★ 必须登记:apply() 靠它把当前项置灰。
var mode_btns := {}


func setup(p: MpLobby, f: OptionsForm) -> void:
	page = p
	form = f


# 接骨架:压暗罩 / 弹层本体 / 三颗模式按钮 / 关闭·取消·确定,并建出动态的三块(禁用武器网格 / 地图选择器 / Beta 时间参数行)。
# ★ 控件的信号在这里接(不挪进页 _ready):"按钮画在屏上、按下去毫无反应"没有任何运行时信号可观测。
func register(root: Node) -> void:
	# ★ 压暗罩铺满整页 + mouse_filter = STOP(拦下背后的点击 = 点弹层外不会误触房卡)在骨架里;它的颜色是调色板纪律的已知例外(全屏遮罩不属于 C_PLATE 那条「HUD 底板 0.1」家族,见 docs/eng/ui.md):Color(0,0,0,0.55) 与 ui/screens/match_result.gd 的 MASK_COLOR、暂停菜单逐字同值 —— 改一处就要一起改(值现在住在 .tscn 里)。
	mask = root.get_node("%CreateMask") as ColorRect
	mask.visible = false
	panel = root.get_node("%CreatePanel") as PanelContainer
	panel.visible = false
	(root.get_node("%CreateCloseBtn") as Button).pressed.connect(func() -> void: set_visible(false))
	(root.get_node("%CreateCancelBtn") as Button).pressed.connect(func() -> void: set_visible(false))
	(root.get_node("%CreateOkBtn") as Button).pressed.connect(page._on_create_pressed)

	# 三颗模式分段按钮(ButtonGroup 互斥;模式色在骨架里)。★ 必须登记进 mode_btns:_apply_create_form 靠它把当前项置灰。
	mode_btns = {PvpSession.MODE_PVP: root.get_node("%CreateModePvp"),
			PvpSession.MODE_TEAM: root.get_node("%CreateModeTeam"), PvpSession.MODE_ROYALE: root.get_node("%CreateModeRoyale")}
	for m: String in [PvpSession.MODE_PVP, PvpSession.MODE_TEAM, PvpSession.MODE_ROYALE]:
		(mode_btns[m] as Button).pressed.connect(func() -> void: apply(m))

	# 「禁用武器」网格:行 = WeaponRegistry(每台武器一颗勾选框),故留代码。★ 回调把 cb 与 type_id 都收进 form.weapon_checks。
	page._add_weapon_grid(root.get_node("%WeaponsBlock"), 20, form.on_weapon_cell)
	# 地图选择器(基类 _add_map_picker 写 Settings.mp_map_path):整块在代码里建 —— 缩略图是 MapCatalog 现烘的,放进骨架只会是一份死重量(且运行时会变成两个选择器)。
	page._add_map_picker(root.get_node("%MapBlock") as VBoxContainer)
	# Beta 时间参数行(仅 Beta 会话;块显隐在 form.register)。
	page._add_time_params(root.get_node("%BetaBlock") as VBoxContainer)


# 点「＋ 创建房间」只显示弹层。★ 每次打开都重刷模式相关行显隐(apply),不挪进页 _ready —— 面板建好之后玩家仍可能改筛选模式,那时这条链必须再跑一次。
func open() -> void:
	apply(page._mode if page._mode != "" else PvpSession.MODE_PVP)
	set_visible(true)


# 弹层与压暗罩一起显隐(罩子单独隐藏会留下一层吃掉点击的全屏黑)。★ 两个节点都启动即建(骨架里就有)⇒ 这里没有 null 可判。
func set_visible(v: bool) -> void:
	panel.visible = v
	mask.visible = v


func is_open() -> bool:
	return panel.visible


# 按模式变形 —— 本弹层唯一的分支。★★ 置灰要迭代 mode_btns 的值:for m in dict 拿的是键(String)—— 写成 for b in mode_btns 会在每个键上取到 null,当场报错、函数在置灰那一行断掉。
# ★ 模式值同时记在页上(_create_mode):页的「确定」那条 RPC 分派读它(测试注释与页里都按这个名字认状态),本文件不另存一份。
func apply(mode: String) -> void:
	page._create_mode = mode
	form.apply_rows(mode)
	for m in mode_btns:
		(mode_btns[m] as Button).disabled = false
	(mode_btns[mode] as Button).disabled = true   # 当前模式置灰(与等待室的选边同款)


# 按模式给三套 payload 的公共部分 + 各自的私有键。★ map 三个模式都上发:1v1 的 create_room 签名冻结、塞不进 payload,故地图一律走 room_map 那条独立的 RPC(建房成功后由本端补发);3v3 不带 disabled_weapons,那一项从 player_options 走,与建房载荷无关。
func build_payload(mode: String) -> Dictionary:
	var d := {
		"is_public": form.is_public(),
		"invite_code": form.invite_code(),
		"map": Settings.mp_map_path,
	}
	if mode == PvpSession.MODE_ROYALE:
		d["max_players"] = form.max_players()
		d["match_time"] = form.match_time()
		d["round_full_heal"] = false
		d["disabled_weapons"] = form.checked_weapons()
	elif mode == PvpSession.MODE_PVP:
		d["disabled_weapons"] = form.checked_weapons()
	return d


# 报到选项(player_options)的组装:键集由 ModeDefs.OPTION_KEYS 决定(2026-10-22 统一)—— 3v3 不再上发禁用武器/回合回血,大乱斗不再上发回合回血(它没有回合),1v1 不再上发 match_time。
# ★★ 取值仍在页里(scenes/mp_lobby.gd 的 _options_snapshot):`"match_time": int(Settings.royale_match_min * 60.0)` 那一行是 ROYALE_MATCH_TIME_CEILING 上界链的第二环,tools/room_sweep_lint.gd 钉着它必须住在页的源码里 ⇒ 快照由页读 Settings / time_rules 后传进来,本函数只做 ModeOptions.build 的组装。
func player_options(mode: String, snapshot: Dictionary) -> Dictionary:
	return ModeOptions.build(mode, snapshot)
