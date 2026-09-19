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
var jump := false            # "上"的**按下边沿**(读一次即清)
# ★ 垂直轴要**按住**态(不是边沿):`ClimbComponent` 的上爬速度读的是 `get_axis("up","down")`,
#   而"抓梯"读的是同一动作的**按下边沿**(`is_action_just_pressed("up")`,由 `jump` 提供)。
#   两半都得有 —— 只给边沿 = 抓上了却不动;只给按住 = 永远抓不上。
var hold_up := false
var hold_down := false

var _slot := 0               # 背包位置(1-based)的按下边沿;0 = 无
var _f_edge := false         # F(捡起)的按下边沿
var _atk_edge := false       # 开火按下边沿(整帧有效,见 _attack_just_pressed_raw)
var _atk_edge_frame := -1
var _atk_rel_edge := false   # 开火**松开**边沿(heavy_aim 枪只在这一支开火)
var _atk_rel_edge_frame := -1


func source_kind() -> int:
	return Kind.AI


# ── 观察者写口 ──

func press_jump() -> void:
	jump = true


func press_slot(i: int) -> void:
	_slot = i


func press_f() -> void:
	_f_edge = true


# ── 覆写钩子(公开读口由基类持有并对 frozen 短路)──

func _axis_raw(neg: String, _pos: String) -> float:
	# `get_axis("left","right")` → neg="left";`get_axis("up","down")` → neg="up"。
	# 后者的符号约定与 `tests/soak_bot_input.gd` 一致:返回 **down - up**(负 = 上)。
	if neg == "left":
		return axis
	return (1.0 if hold_down else 0.0) - (1.0 if hold_up else 0.0)


func _action_pressed_raw(_action: String) -> bool:
	return false


func _action_just_pressed_raw(action: String) -> bool:
	if action != "up":
		return false
	var v := jump
	jump = false
	return v


func _action_just_released_raw(_action: String) -> bool:
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
	return _atk_edge and Engine.get_physics_frames() == _atk_edge_frame


func _attack_just_released_raw() -> bool:
	return _atk_rel_edge and Engine.get_physics_frames() == _atk_rel_edge_frame


# 观察者在脉冲**上升沿 / 下降沿**各调一次(见 watcher 的 `_pulse_attack`)
func press_attack_edge() -> void:
	_atk_edge = true
	_atk_edge_frame = Engine.get_physics_frames()


func release_attack_edge() -> void:
	_atk_rel_edge = true
	_atk_rel_edge_frame = Engine.get_physics_frames()


func _weapon_slot_raw() -> int:
	var v := _slot
	_slot = 0        # 读一次即清,与真实 Input 的"本轮刚按下"语义一致
	return v


func _pickup_pressed_raw() -> bool:
	var v := _f_edge
	_f_edge = false
	return v


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
