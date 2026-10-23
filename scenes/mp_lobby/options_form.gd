class_name OptionsForm
extends RefCounted

# 大厅页建房弹层的「选项表单」面板(2026-10-22 Task 10 纯搬移自 scenes/mp_lobby.gd)。
# 本文件只负责两件事:①表单行显隐(_form_rows 那张表 + 按模式显隐)②这些控件的值读写(灌值 / 写回 Settings / 建房时读值)。
# ★ 节点路径(%语义名)、信号、文案逐字未动:行显隐靠 .tscn 里的名字对上,错一个不报错,只是那一行永远不隐藏。
# ★ 谁改变可见性、谁读控件值,两条都收在这里 —— 建房弹层的编排(create_panel.gd)只问本文件要值,不再直接碰这些节点。

# ★ 键名固定:_apply_create_form 按这几个键显隐,max_players / match_time / weapons / privacy 按模式显隐,map 三模式都可见,beta 由 PvpSession.beta_mode 在建面板那一刻定。
var rows := {}
var public_check: CheckButton = null
var invite_edit: LineEdit = null
var max_slider: HSlider = null
var time_slider: HSlider = null
var weapon_checks: Array[CheckButton] = []   # 建房时读勾选态(与旧大乱斗页同款)


# 接骨架:按语义名取到表单行与控件 + 接信号 + 灌初值。★ 控件的信号在这里接(不挪进页 _ready):"按钮画在屏上、按下去毫无反应"没有任何运行时信号可观测。
# ★ 先灌值再 connect(别调换):button_pressed / value 赋值都会发信号,先连上就会在建树那一刻把值写回 Settings 并播一次音效。
func register(root: Node) -> void:
	rows = {
		"privacy": root.get_node("%PrivacyRow"), "max_players": root.get_node("%MaxPlayersRow"),
		"match_time": root.get_node("%MatchTimeRow"), "full_heal": root.get_node("%FullHealRow"),
		"weapons": root.get_node("%WeaponsBlock"), "map": root.get_node("%MapBlock"),
		"beta": root.get_node("%BetaBlock"),
	}

	public_check = root.get_node("%PublicCheck") as CheckButton
	invite_edit = root.get_node("%InviteEdit") as LineEdit
	public_check.button_pressed = true
	invite_edit.visible = false
	public_check.toggled.connect(func(on: bool) -> void:
		invite_edit.visible = not on)

	max_slider = root.get_node("%MaxPlayersSlider") as HSlider
	max_slider.value_changed.connect(func(v: float) -> void:
		(root.get_node("%MaxPlayersLabel") as Label).text = "%d 人" % int(v))

	# 一局限时(分钟;仅大乱斗可见)。★ 上界 15 是 ROYALE_MATCH_TIME_CEILING 那条上界链的第三环(Settings.royale_match_min 的写入端),别在这里改数值(见 docs/eng/modes.md);值从 Settings 灌。
	time_slider = root.get_node("%MatchTimeSlider") as HSlider
	time_slider.value = Settings.royale_match_min
	(root.get_node("%MatchTimeLabel") as Label).text = "%d 分钟" % int(Settings.royale_match_min)
	time_slider.value_changed.connect(func(v: float) -> void:
		Settings.royale_match_min = v
		Settings.save()
		(root.get_node("%MatchTimeLabel") as Label).text = "%d 分钟" % int(v))

	# 「每回合开始回满血」房主选项(仅 1v1 可见)。★★ 它必须留在创建弹层里:Settings.pvp_round_full_heal 的写入方只有这一颗勾选框,而它仍被 _player_options() 读取并上报 —— 移走就等于玩家再也打不开它。
	# ★ 它是房主 / 服务器规则(大乱斗恒 false、3v3 压根不发),故归属创建弹层。
	var full_heal: CheckButton = root.get_node("%FullHealCheck") as CheckButton
	full_heal.button_pressed = Settings.pvp_round_full_heal
	full_heal.toggled.connect(func(on: bool) -> void:
		Settings.pvp_round_full_heal = on
		Settings.save())

	# Beta 时间参数块只在 Beta 会话里出现(建面板那一刻定,不随后续切换变)。
	(rows["beta"] as Node).visible = PvpSession.beta_mode


# 按模式显隐表单行 —— 本弹层唯一的分支(模式层那一半在 create_panel.apply)。★ 3v3 关掉禁用武器不只是"规则里没有":那两个勾选框写的是 Settings.pvp_disabled_weapons,在 3v3 页勾一下会连带改掉另两个模式(功能缺陷,不是审美)。
func apply_rows(mode: String) -> void:
	var is_royale := mode == PvpSession.MODE_ROYALE
	var is_team := mode == PvpSession.MODE_TEAM
	var is_pvp := mode == PvpSession.MODE_PVP
	rows["max_players"].visible = is_royale
	rows["match_time"].visible = is_royale
	rows["full_heal"].visible = is_pvp
	rows["weapons"].visible = not is_team
	# ★ 1v1 下那一行是骗人的控件:create_room(caller) 是原版 NetBus 的冻结签名、收不了 opts ⇒ 服务端永远建公开房(1v1 载荷里 is_public 恒 true)。
	# 让玩家取消勾选"公开"、填了邀请码,建出来仍是人人可见、无需码就能进的房 —— 比不给这个选项更坏。
	rows["privacy"].visible = not is_pvp


# ── 值读取(建房载荷用)──

func is_public() -> bool:
	return public_check.button_pressed


func invite_code() -> String:
	return invite_edit.text.strip_edges()


func max_players() -> int:
	return int(max_slider.value)


# 建房载荷里的 match_time 是秒(滑块是分钟)。★ 与页 _player_options() 那一行 `Settings.royale_match_min * 60.0` 不是同一个量:那条是报到选项、被 tools/room_sweep_lint.gd 钉在页里;这条是建房载荷。
func match_time() -> int:
	return int(time_slider.value) * 60


# 禁用武器网格的勾选结果 → type_id 数组。★ 与 LobbyPage._add_weapon_grid 的 on_cell 回调配对:那个回调负责把 cb 与 type_id 一起收进 weapon_checks(见 on_weapon_cell)。
func checked_weapons() -> Array:
	var out: Array = []
	for cb in weapon_checks:
		if cb.button_pressed:
			out.append(int(cb.get_meta("type_id", 0)))
	return out


# LobbyPage._add_weapon_grid 的 on_cell 回调。★ 少收 type_id 那半,checked_weapons() 会永远返回 [0] 且不报错。
func on_weapon_cell(cell: Node, type_id: int) -> void:
	var cb: CheckButton = cell.get_meta("cb")
	cb.set_meta("type_id", type_id)
	weapon_checks.append(cb)
