class_name NetworkInputSource
extends InputSource

# 网络注入输入(服务器权威模拟的唯一消费方):从输入包取轴/按键/边沿/切枪/瞄准。
# 设计(修正版):
# - held/axis/aim/weapon:每次新包到达即覆盖为最新 → 服务器紧跟客户端,几乎无滞后。
# - just_pressed/just_released 边沿:累积(|=)不覆盖 → 即使两包批量到达也不丢边沿
#   (抓梯/跳跃/开火都靠边沿,丢了服务器模拟就与客户端脱节,是回拉的真正根因)。
# - 缺包时(无新包到达)held 保持上一包,边沿由 MatchHost 每帧末 clear_edges() 清空 → 沿用上一 tick 输入。

const BIT_UP := 1
const BIT_DOWN := 2
const BIT_CHARGE := 4
const BIT_ATTACK := 8


# ── 编码端:组一个输入包(协议**发送侧**的唯一来源)──
# ★ 为什么必须收在这里:这段 30 行的位打包原先在 `pvp_client` 与 `royale_game` 里**各手抄一份**,
#   而**解码端**(本类的 apply_packet / _bit / get_axis)只有一份。编码端分叉不会有任何报错:
#   加一个 held 位只改一个客户端 → 该键在一个模式里永远没反应;把 CHARGE 抄成 ATTACK 也拦不住。
#   (`--` 两份此前确实只差一句注释,但在它们真分叉之前收口。)
# ★ seq / aim 由调用方给:它们来自场景(`_input_seq` 单调自增、`player.get_current_aim_dir()`),
#   不属于"协议编码"这件事。
# ★ 读 src 走公开读口 → 自动遵守 `frozen`(COUNTDOWN 冻结期组出来的是全中性包,与旧行为一致)。
static func pack_record(src: InputSource, seq: int, aim: Vector2) -> Dictionary:
	var held := 0
	var pressed := 0
	var released := 0
	if src.is_action_pressed("up"):
		held |= BIT_UP
	if src.is_action_pressed("down"):
		held |= BIT_DOWN
	if src.is_action_pressed("charge"):
		held |= BIT_CHARGE
	if src.is_action_pressed("attack"):
		held |= BIT_ATTACK
	if src.is_action_just_pressed("up"):
		pressed |= BIT_UP
	if src.is_action_just_pressed("down"):
		pressed |= BIT_DOWN
	if src.is_action_just_pressed("charge"):
		pressed |= BIT_CHARGE
	if src.is_action_just_pressed("attack"):
		pressed |= BIT_ATTACK
	if src.is_action_just_released("up"):
		released |= BIT_UP
	if src.is_action_just_released("down"):
		released |= BIT_DOWN
	if src.is_action_just_released("charge"):
		released |= BIT_CHARGE
	if src.is_action_just_released("attack"):
		released |= BIT_ATTACK
	return {
		"seq": seq,          # 单调输入序号(服务器按序消费并回带 ack,rollback 用)
		"ax": src.get_axis("left", "right"),
		"held": held,
		"pressed": pressed,
		"released": released,
		"weapon": src.get_weapon_slot_pressed(),
		"aim": aim,
	}

var _axis := 0.0
var _held := 0
var _aim := Vector2.ZERO   # 注入的瞄准方向(世界坐标系)
var _weapon := 0
var _pressed := 0          # 累积的 just_pressed 边沿(玩家读取,MatchHost 每帧末清除)
var _released := 0         # 累积的 just_released 边沿

# 新包到达(服务器 RPC 回调里调用):held/axis/aim/weapon 取最新,边沿累积。
func apply_packet(pkt: Dictionary) -> void:
	_axis = pkt.get("ax", 0.0)
	_held = pkt.get("held", 0)
	_aim = pkt.get("aim", Vector2.ZERO)
	var w: int = pkt.get("weapon", 0)
	if w > 0:
		_weapon = w
	_pressed |= pkt.get("pressed", 0)
	_released |= pkt.get("released", 0)

# 每帧末清除已消费边沿与切枪(玩家 _physics_process 之后)。held/axis/aim 保留(缺包沿用)。
func clear_edges() -> void:
	_pressed = 0
	_released = 0
	_weapon = 0

# 全量复位(COUNTDOWN/局间冻结等权威停顿时用):连 held/axis 一起清,玩家彻底静止。
# 单清边沿不够——上一包若带着方向,倒计时里玩家会照旧漂移(服务器渲染路径被快照掩盖,
# C2 预测路径下=分歧源)。
func reset_state() -> void:
	_axis = 0.0
	_held = 0
	_aim = Vector2.ZERO
	_weapon = 0
	_pressed = 0
	_released = 0

# ── 覆写钩子(公开读口由基类持有并对 frozen 短路;本类不再各自处理冻结)──

func _axis_raw(neg: String, pos: String) -> float:
	# 垂直轴由 held 位推导:输入包只传水平 ax,up/down 已并入 held 位掩码。
	# 原实现一律返回水平 _axis → climb_component 的 get_axis("up","down") 在服务器上恒为 0,
	# 服务器玩家攀附后挂梯不动、客户端正常上爬 → 大分歧 → 快照回拉(梯子回拉根因)。
	if neg == "up" and pos == "down":
		if _held & BIT_UP != 0:
			return -1.0
		if _held & BIT_DOWN != 0:
			return 1.0
		return 0.0
	if neg == "down" and pos == "up":
		if _held & BIT_DOWN != 0:
			return -1.0
		if _held & BIT_UP != 0:
			return 1.0
		return 0.0
	return _axis

func _action_pressed_raw(action: String) -> bool:
	return _held & _bit(action) != 0

func _action_just_pressed_raw(action: String) -> bool:
	return _pressed & _bit(action) != 0

func _action_just_released_raw(action: String) -> bool:
	return _released & _bit(action) != 0

func _attack_pressed_raw() -> bool:
	return _held & BIT_ATTACK != 0

func _attack_just_pressed_raw() -> bool:
	return _pressed & BIT_ATTACK != 0

func _attack_just_released_raw() -> bool:
	return _released & BIT_ATTACK != 0

func _weapon_slot_raw() -> int:
	return _weapon

func get_aim_dir_override() -> Vector2:
	return _aim

# 网络注入 → 服务器/远端模拟的玩家武器瞄准不读宿主机鼠标(注入 ZERO 用朝向兜底)。
func is_network_driven() -> bool:
	return true

static func _bit(action: String) -> int:
	match action:
		"up": return BIT_UP
		"down": return BIT_DOWN
		"charge": return BIT_CHARGE
		"attack": return BIT_ATTACK
	return 0
