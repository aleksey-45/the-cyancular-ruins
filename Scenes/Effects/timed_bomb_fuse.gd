class_name TimedBombFuse
extends Node

# 计时爆炸团(卡 pr_731505,槽 11)的引信节点:按下开火=点燃,挂在世界上(不随切枪消失),
# 倒计时走完仍未掷出 → 在持弹者原地起爆(卡特殊要求)。掷出后 armed_in_hand=false,
# 起爆移交投掷物(prop_launcher 的 _lit_fuse → BulletBase.light_fuse 把剩余时间带过去),
# 本节点只剩「倒计时显示」职责到 0 为止——手持段与飞行段是同一根引信。
# 持弹者离树/被释放(回主菜单/R 重载=世界退役)或倒地阵亡 → 引信作废自撤:
# 不在真空中起爆,也不给 PvP 同节点复活的玩家补刀(阵亡掉雷)。
# 屏幕中央的像素倒计时由 CountdownHud 承担:扫本组取最先到 0 的那颗显示,组空自毁;
# headless(专用服务器/冒烟测试)无屏幕,不建 UI。

const HUD_LAYER := 132   # 盖单机 HUD(129)/PvpHud(130)/打击反馈(131):倒计时是保命信息

var total := 6.0            # 倒计时全长(秒)
var remaining := 6.0        # 剩余(秒);掷出时被读走注入投掷物
var holder: Node2D = null   # 持弹者(原地自爆的位置参考)
var armed_in_hand := true   # true=还在手里(到点原地自爆);false=已掷出(只管显示)
var blast_radius := 260.0
var blast_damage := 50      # 满伤=满血(PlayerParams.player_max_hp)
var blast_knockback := 2600.0
var falloff_mode: int = Explosion.Falloff.LINEAR   # 卡:与爆心距离成线性衰减
var visual_scene: PackedScene = null

var _last_pos := Vector2.ZERO   # 持弹者最后有效位置(holder 失效前每帧刷新)


func _ready() -> void:
	add_to_group("timed_bomb_fuse")
	_ensure_hud()


func _process(delta: float) -> void:
	remaining -= delta
	if holder != null and is_instance_valid(holder) and holder.is_inside_tree():
		_last_pos = holder.global_position
		# 持弹者倒地/阵亡:燃烧弹随之脱落作废(不死不掉的雷会跟着 PvP 同节点复活
		# 挪到出生点,变成「复活点补刀」;阵亡掉雷 = 干净且符合直觉)
		if armed_in_hand and holder.has_method("is_downed") and holder.is_downed():
			queue_free()
			return
	elif armed_in_hand:
		queue_free()   # 持弹者没了(场景退役/释放):引信作废,不在真空中起爆
		return
	if remaining > 0.0:
		return
	if armed_in_hand:
		_detonate(_last_pos)
	queue_free()


## 原地自爆:结算/视效规则与 BulletBase._explode 完全同款——PvP 客户端不裁决(等服务器
## 广播 NetBusExt.explosion_event 驱动视效),单机/服务器本地结算。shooter=null:
## 自爆不归因(大乱斗自杀不计分、不播「击杀」播报,与溺水等环境死同类)。
func _detonate(pos: Vector2) -> void:
	var peer := multiplayer.multiplayer_peer
	var in_net: bool = peer != null and not (peer is OfflineMultiplayerPeer)
	if in_net and not multiplayer.is_server():
		return
	Sfx.play("explosion")
	if visual_scene != null:
		var fx: Node = visual_scene.instantiate()
		fx.global_position = pos
		get_viewport().add_child(fx)
	if in_net:
		NetBusExt.s2c_all("explosion_event", {"pos": pos, "radius": blast_radius})
	Explosion.apply_aoe(pos, blast_radius, blast_damage, blast_knockback, null, falloff_mode)


func _ensure_hud() -> void:
	if DisplayServer.get_name() == "headless":
		return   # 专用服务器/冒烟:无屏幕,不建倒计时 UI
	var tree := get_tree()
	if tree == null or tree.root == null:
		return
	if tree.get_first_node_in_group("prop_countdown_hud") != null:
		return   # 已有 HUD(第二颗弹):共用同一个显示
	tree.root.add_child.call_deferred(CountdownHud.new())


## 屏幕中央像素倒计时:大号深描边数字(与 CombatFeedback 播报同款描边风格),
## 最后 2 秒转红催促;组空(全部爆完/随场景退役)自撤。
class CountdownHud extends CanvasLayer:
	var _label: Label
	var _warn := false

	func _ready() -> void:
		layer = 132   # = HUD_LAYER(盖单机 HUD/PvpHud/打击反馈);内联:内层类不引外层常量
		add_to_group("prop_countdown_hud")
		var root := Control.new()
		root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		root.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(root)
		_label = Label.new()
		_label.text = "6"
		_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_label.add_theme_font_size_override("font_size", 76)
		_label.add_theme_color_override("font_color", Color(0.96, 0.96, 0.92))
		_label.add_theme_constant_override("outline_size", 16)
		_label.add_theme_color_override("font_outline_color", Color(0.05, 0.08, 0.12, 0.95))
		_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		root.add_child(_label)

	func _process(_delta: float) -> void:
		var best := INF
		for f in get_tree().get_nodes_in_group("timed_bomb_fuse"):
			var v = f.get("remaining")
			if v != null:
				best = minf(best, v)
		if best == INF:
			queue_free()   # 组里没引信了:HUD 自撤
			return
		_label.text = str(maxi(ceili(best), 0))
		var warn := best <= 2.0
		if warn != _warn:
			_warn = warn
			_label.add_theme_color_override("font_color",
					Color(0.92, 0.30, 0.22) if warn else Color(0.96, 0.96, 0.92))
