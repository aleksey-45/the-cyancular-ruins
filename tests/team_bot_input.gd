extends PlayerInput

# 3v3 真链路探针(`tests/team_match_probe.*`)的脚本手柄:**一根哑手柄**。
# 它自己不做任何决策 —— 只把观察者(`team_match_watcher.gd`)每物理帧写进来的
# `axis` / `aim` / `attack` / 一次性边沿(jump / slot / F)报给输入读口。
#
# ★ 为什么决策不放这儿:决策要读**真 team_game 的运行时状态**(快照里别人的位置、自己的
#   背包、地面武器表、A* 世界网格),而观察者本来就挂在 root 上、跨换场存活、能直接读那些
#   生产对象。手柄自持状态的话,那份"该不该开火"的知识就要在两个文件之间对不上
#   (与 `tests/ground_bot_input.gd` 逐字同款的理由)。
#
# ★ 无 `class_name`:新建全局类要刷 `--import` 全局类缓存(本仓踩过这个坑),由观察者 preload。
#
# ★ 本手柄**故意不覆写 `frozen` 的判定**:基类 `PlayerInput` 的公开读口对 `frozen` 短路,
#   本类只覆写 `_*_raw()` 钩子 → COUNTDOWN/结算期的"禁移动禁开火"由基类负责。观察者那边
#   只管自己的相位推进(见 watcher 的 `_tick_bot`)。

var axis := 0.0              # 水平轴(-1 左 / +1 右)
var aim := Vector2.RIGHT     # 瞄准方向(世界向量;观察者按环面最短向量算)
var attack := false          # 持续开火(按住左键同理)
# ★★ 边沿一律**按帧打标**,不做"读一次即清":同一个物理帧里**有两处**会读它们 ——
#    ① 客户端组上行包(`PacketInputSource.pack_record`,它问的是**带参**钩子)
#    ② 玩家自己的本地判定(问的是**无参**钩子:`is_attack_pressed()` 等)
#    读一次即清 ⇒ 总有一处拿到 false ⇒ **本地与服务器分叉**(一个跳/开火、另一个不跳/不开火)——
#    而 C2 会每帧把客户端拉回权威态,表现成"机器人走不动、打不出子弹",**且不报错**。
# ★★ **整条输入链依赖一条序前提**:观察者(以及它驱动的本手柄)**必须先于游戏场景
#    被 `_physics_process` 处理** —— 观察者是用 `root.add_child` 在换场**之前**挂上的
#    (树序在前),所以它每帧先写字段、同帧晚些时候玩家/组包再读。
#    改挂载时机(例如改到游戏场景 _ready 之后再 add_child)⇒ 所有边沿**再次静默消失**
#    (表现又回到"服务器侧不开火/不跳"),而不会有任何报错。观察者侧有对应断言。
var _edges: Dictionary = {}  # 边沿名 -> 该边沿所属的物理帧号(整帧内有效)

func _set_edge(name: String) -> void:
	_edges[name] = Engine.get_physics_frames()


func _edge_now(name: String) -> bool:
	return int(_edges.get(name, -1)) == Engine.get_physics_frames()

# ★ 垂直轴要**按住**态(不是边沿):`ClimbComponent` 的上爬速度读的是 `get_axis("up","down")`,
#   而"抓梯"读的是同一动作的**按下边沿**(`is_action_just_pressed("up")`,由 `jump` 提供)。
#   两半都得有 —— 只给边沿 = 抓上了却不动;只给按住 = 永远抓不上。
var hold_up := false
var hold_down := false

var _slot := 0               # 背包位置(1-based)的按下边沿;'0 = 无'(整帧有效,见 _weapon_slot_raw)


func source_kind() -> int:
	return Kind.AI


# ── 观察者写口 ──

func press_jump() -> void:
	_set_edge("jump")


func press_slot(i: int) -> void:
	_slot = i
	_set_edge("slot")


# ★ 本探针**从不调用它**(机器人不捡枪)。留着是因为"拾取"是输入面的一部分,删了会让
#   这一族手柄看起来只支持一半动作;但**别误以为它是必需的** —— PvP 客户端里本地拾取读口
#   被 `not Level0.pvp_mode` 关掉了(`player.gd` 的 `_poll_pickup_drop`),`pack_record` 是**唯一**读者,
#   所以这里"两处读者"的理由**不成立**,它只是照 `soak_bot_input` 的形状补齐。
func press_f() -> void:
	_set_edge("pickup")


# ── 覆写钩子(公开读口由基类持有并对 frozen 短路)──

func _axis_raw(neg: String, _pos: String) -> float:
	# `get_axis("left","right")` → neg="left";`get_axis("up","down")` → neg="up"。
	# 后者的符号约定与 `tests/soak_bot_input.gd` 一致:返回 **down - up**(负 = 上)。
	if neg == "left":
		return axis
	return (1.0 if hold_down else 0.0) - (1.0 if hold_up else 0.0)


# ★★★ **带参钩子必须真实现** —— 这是本手柄最要命的一处(复审抓出来的):
#    上行包问的是**带参**的 `is_action_pressed("attack"/"up"/…)`(`packet_input_source.gd:40-80`),
#    而本类原先三个带参钩子全是**恒 false 的桩** ⇒ `BIT_ATTACK`/`BIT_UP` 的 held/pressed/released
#    **从未进过输入包** ⇒ **服务器侧的那名玩家从来不跳、不开火**(本地照样动,因为本地走无参钩子)。
#    后果是双向的:① 相③ 的 `near` 结构性恒 0(服务器根本不生成子弹);
#    ② 每一次跳跃都是"客户端跳了、服务器没跳"的**分歧** ⇒ C2 每帧回滚把客户端拉回去
#      ⇒ 观感就是"机器人走不动"(与枪种无关)。
#    ★ 对照样板:`tests/soak_bot_input.gd` 老实实现了这三个带参钩子,所以大乱斗 soak 的机器人
#      在服务器侧是真能开火的;**本手柄是该族里唯一没接上的**。
func _action_pressed_raw(action: String) -> bool:
	match action:
		"attack":
			return attack
		"up":
			return hold_up
		"down":
			return hold_down
	return false


func _action_just_pressed_raw(action: String) -> bool:
	match action:
		"attack":
			return _edge_now("atk")
		"up":
			return _edge_now("jump")
	return false


func _action_just_released_raw(action: String) -> bool:
	if action == "attack":
		return _edge_now("atk_rel")
	return false


func _attack_pressed_raw() -> bool:
	return attack


# ★★ **开火的三个边沿都得给,一个都不能省** —— `WeaponBase` 按枪种选边沿:
#    · `full_auto`        → `_attack_pressed()`(按住)
#    · 半自动(手枪等)   → `_attack_just_pressed()`
#    · `heavy_aim`(m82a1 **与榴弹发射器**)→ `_attack_just_released()`("按住预瞄、松开发射")
#    早先本手柄只给"按住"、两个边沿恒 false ⇒ **重型枪只进预瞄、永不发射**;而相③ 的判决
#    依赖"甲真的开火了",于是**抽到重狙(1/6)必然判成"没开火"** —— 判决被**枪种**污染。
# ★ 边沿在**整帧内为真**(不是"读一次即清"):真实 `Input.is_action_just_pressed` 就是这样,
#    而同一帧里**有两处**会读它 —— 客户端组输入包(`PacketInputSource.pack_record`)与玩家自己
#    的开火判定。读一次即清会让其中一处拿到 false(包里有边沿但本地不开火,或反过来)。
func _attack_just_pressed_raw() -> bool:
	return _edge_now("atk")


func _attack_just_released_raw() -> bool:
	return _edge_now("atk_rel")


# 观察者在脉冲**上升沿 / 下降沿**各调一次(见 watcher 的 `_pulse_attack`)
func press_attack_edge() -> void:
	_set_edge("atk")


func release_attack_edge() -> void:
	_set_edge("atk_rel")


func _weapon_slot_raw() -> int:
	# ★ 同样整帧有效(理由见文件头那一段):`get_weapon_slot_pressed()` 一帧里被**本地装备**
	#   与**上行包**各读一次 —— 读一次即清会让其中一处丢边沿(表现:切枪在服务器侧不生效)。
	return _slot if _edge_now("slot") else 0


func _pickup_pressed_raw() -> bool:
	return _edge_now("pickup")


# Q 长按满阈值那一次边沿由 **player.gd** 判(它有确定的物理 delta),判满了它调
# `mark_drop_edge()` 打标 —— 本手柄必须像 `LocalInputSource` 那样把标记读走并清掉。
# 本探针不用丢弃(它不验证背包),但**恒返回 false 是静默失效**,照实实现更省事。
func _drop_pressed_raw() -> bool:
	var v := _drop_edge
	_drop_edge = false
	return v


# 不读宿主 OS 鼠标(headless 下是垃圾值),用观察者写的方向。
func get_aim_dir_override() -> Vector2:
	return aim


# 必须 true:否则 `WeaponBase` 的瞄准会回落到读宿主 OS 鼠标(headless 下是 (0,0) 之类的垃圾值),
# 开火方向会乱(与 `tests/soak_bot_input.gd` 覆写它的理由同款)。
func is_network_driven() -> bool:
	return true
