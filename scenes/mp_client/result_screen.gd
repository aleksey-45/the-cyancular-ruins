class_name ResultScreen
extends RefCounted

# 结算页组合件(2026-10-22 从 PvpMatchClient 拆出;Task 6):挂载 / 每次刷新 / 离场接线。
# 形状是**组合**不是继承:PvpMatchClient 保留编排与钩子,本类只碰结算页这一个对象;
# 载荷仍由宿主的 `_build_result_payload()` 覆写决定,离场仍由宿主的 `_leave_to_main_menu` 决定
# (bind 的两个 Callable ⇒ 本类不 import NetBus / Level0,也不知道"回主菜单"怎么回)。
# ★★ 必须走场景实例化,不能用 MatchResult.new():layer = 150 只写在 ui/match_result.tscn 里(脚本不设 layer),用 .new() 会拿到 CanvasLayer 默认的 layer 1,结算页画在 HUD(130)/ 小地图(131)下面、压暗罩盖不住它们。零守卫:hud_declarative_probe 那条"出现 MatchResult.new( 即红"的扫盘断言已随该探针删除(2026-10-09)。
const RESULT_SCENE := preload("res://ui/screens/match_result.tscn")

var _client: Node = null
var _payload_builder: Callable = Callable()
var _leave_scene: Callable = Callable()
var _result: MatchResult = null             # 结算页(挂载一次,由 show() 建)


func bind(client: Node, payload_builder: Callable, leave_scene: Callable) -> void:
	_client = client
	_payload_builder = payload_builder
	_leave_scene = leave_scene


func is_shown() -> bool:
	return _result != null and is_instance_valid(_result)


# 结算页:玩家自己退(不再是 N 秒后自动回主菜单);三个模式共用,各自只覆写 _build_result_payload()。
# ★★ 挂载一次、但每次都要刷新(if _result == null 只包住"建 + 连线")。写成 if _result != null: return 会把"挂载幂等"顺手变成"更新也只一次":第二条 MATCH_OVER 载荷永远到不了屏幕,而 MatchResult.show_result 的清场重建在生产里一次都不会跑 —— 当年那条探针却直接调它、照绿 —— 探针比产品更绿(该探针已删·2026-10-09)。★ 第二条载荷可达:1v1 —— server_main 每次 reclaim 成功后重播当前 round_state,掉线重连的客户端就会收到第二条 MATCH_OVER;3v3 —— team_host._finish_match() 在战斗中直接 PLAYING→MATCH_OVER,而倒地边沿检测在 match _round_state 之前且不看状态 ⇒ MATCH_OVER 之后再死人会再广播一条终局载荷。
# payload 省略(默认 null)= 现取宿主 builder;外部想直接给现成载荷时可显式传(计划接口 show(payload))。
func show(payload: Variant = null) -> void:
	if _result == null:
		_result = RESULT_SCENE.instantiate()
		_client.add_child(_result)
		_result.leave_requested.connect(_leave_scene)
		# ★★ 挂载那一刻先用空载荷亮出来,再填真载荷 —— 顺序不可换,这是"MATCH_OVER 之后永远有出路"那条不变量的安全网。要防的故障形状是 show_result() 在它最后那句 visible = true 之前结束:那时结算页停在 _ready() 末尾那句 visible = false 上(看不见、ESC 也够不着、按钮点不到),而暂停菜单已被 MATCH_OVER 块销毁、K 键被 _match_ended 挡住 ⇒ 玩家卡死在对局里。可达形状:载荷里混进非字典的节 ⇒ _build_section 的参数类型转换当场失败。
		# ★ 空载荷抛不出错("空载荷不崩"是本页硬要求,且它只做赋文案 + 清场建节 + visible = true 三件事)⇒ 可见、ESC 生效、按钮可用,三样退路当场到手;正常路径看不到这个空态(两句之间没有 await,布局与绘制都在帧末)。
		_result.show_result({})
	if payload == null:
		_result.show_result(_payload_builder.call())
	else:
		_result.show_result(payload)
