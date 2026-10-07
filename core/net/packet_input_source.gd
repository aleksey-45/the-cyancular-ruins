class_name PacketInputSource
extends PlayerInput

# 网络数据包输入源（服务端权威模拟与回滚推演的输入消费者）。
# 从网络输入包中解析轴向移动、按键状态、触发边沿、切枪请求及瞄准方向。
#
# 同步策略：
# - 持续状态（held、axis、aim）：每当新数据包到达即更新为最新值，紧跟客户端状态。
# - 触发边沿（pressed、released）：采用按位或累积，避免批量到达时丢失边沿动作。
# - 缺包处理：未到达新包时保持上一包的持续状态，边沿状态在物理帧末通过 clear_edges() 清除。

const BIT_UP := 1
const BIT_DOWN := 2
const BIT_CHARGE := 4
const BIT_ATTACK := 8
# 动作按键位掩码定义（对应输入数据包中的 held / pressed / released 字段）
const BIT_RELOAD := 16   # 换弹（按键 R）
const BIT_PICKUP := 32   # 拾取地面武器（按键 F，单帧边沿）
const BIT_DROP := 64     # 丢弃手持武器（按键 Q，长按达成触发边沿）
const BIT_HASTE := 128   # 时间加速（持续按住）
const BIT_REWIND := 256  # 时空回溯（持续按住）


# 将本地输入打包为网络传输格式。
# seq 携带单调递增序号，aim 携带世界坐标瞄准向量。
# 冻结期间由基类统一返回中性输入。
static func pack_record(src: PlayerInput, seq: int, aim: Vector2) -> Dictionary:
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
	if src.is_action_pressed("R"):
		held |= BIT_RELOAD
	if src.is_action_pressed("haste"):
		held |= BIT_HASTE
	if src.is_action_pressed("rewind"):
		held |= BIT_REWIND
	if src.is_action_just_pressed("up"):
		pressed |= BIT_UP
	if src.is_action_just_pressed("down"):
		pressed |= BIT_DOWN
	if src.is_action_just_pressed("charge"):
		pressed |= BIT_CHARGE
	if src.is_action_just_pressed("attack"):
		pressed |= BIT_ATTACK
	if src.is_action_just_pressed("R"):
		pressed |= BIT_RELOAD
	if src.is_action_just_released("up"):
		released |= BIT_UP
	if src.is_action_just_released("down"):
		released |= BIT_DOWN
	if src.is_action_just_released("charge"):
		released |= BIT_CHARGE
	if src.is_action_just_released("attack"):
		released |= BIT_ATTACK
	if src.is_action_just_released("R"):
		released |= BIT_RELOAD
	# 拾取与丢弃仅记录单次触发边沿
	if src.is_pickup_pressed():
		pressed |= BIT_PICKUP
	if src.is_drop_pressed():
		pressed |= BIT_DROP
	return {
		"seq": seq,          # 输入自增序号（服务端按序消费并返回确认序列号）
		"ax": src.get_axis("left", "right"),
		"held": held,
		"pressed": pressed,
		"released": released,
		# 切换目标武器实例 ID（winst），0 表示本帧无切枪请求
		"winst": 0,
		"aim": aim,
	}

var _axis := 0.0
var _held := 0
var _aim := Vector2.ZERO   # 注入的瞄准方向（世界坐标系）
var _switch_inst := 0      # 切枪目标武器实例 ID，大于 0 表示当前有切枪请求
var _pressed := 0          # 累积的按下触发边沿掩码
var _released := 0         # 累积的松开触发边沿掩码

# 输入源类型标识。
func source_kind() -> int:
	return Kind.PACKET


# 应用网络输入数据包：持续状态覆盖为最新，边沿状态按位或累积。
func apply_packet(pkt: Dictionary) -> void:
	_axis = pkt.get("ax", 0.0)
	_held = pkt.get("held", 0)
	_aim = pkt.get("aim", Vector2.ZERO)
	var inst: int = pkt.get("winst", 0)
	if inst > 0:
		_switch_inst = inst
	_pressed |= pkt.get("pressed", 0)
	_released |= pkt.get("released", 0)

# 读取当前是否按住时间加速键。
func haste_held() -> bool:
	return (_held & BIT_HASTE) != 0


# 读取当前是否按住时空回溯键。
func rewind_held() -> bool:
	return (_held & BIT_REWIND) != 0


# 清除当前物理帧已消费的边沿与切枪请求。持续状态保留以供缺包时沿用。
func clear_edges() -> void:
	_pressed = 0
	_released = 0
	_switch_inst = 0

# 全量重置输入状态（对局倒计时或暂停时调用，避免持续输入导致角色滑移）。
func reset_state() -> void:
	_axis = 0.0
	_held = 0
	_aim = Vector2.ZERO
	_switch_inst = 0
	_pressed = 0
	_released = 0

# 覆写底层输入接口，公开接口统一由基类管理冻结逻辑。

func _axis_raw(neg: String, pos: String) -> float:
	# 垂直轴由 held 位掩码推导，避免爬梯等逻辑因缺少垂直输入而产生分歧
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

# 网络输入源通过实例 ID 切枪，位置索引恒返回 0。
func _switch_index_raw() -> int:
	return 0


func _switch_inst_raw() -> int:
	return _switch_inst

func _pickup_pressed_raw() -> bool:
	return _pressed & BIT_PICKUP != 0

func _drop_pressed_raw() -> bool:
	return _pressed & BIT_DROP != 0

func get_aim_dir_override() -> Vector2:
	return _aim

# 网络输入源驱动的角色瞄准不读取宿主机鼠标。
func is_network_driven() -> bool:
	return true

static func _bit(action: String) -> int:
	match action:
		"up": return BIT_UP
		"down": return BIT_DOWN
		"charge": return BIT_CHARGE
		"attack": return BIT_ATTACK
		"R": return BIT_RELOAD
	return 0
