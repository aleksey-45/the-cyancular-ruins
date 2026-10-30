class_name PacketInputSource
extends PlayerInput

# 网络注入输入(服务器权威模拟的唯一消费方):从输入包取轴/按键/边沿/切枪/瞄准。held/axis/aim/weapon 新记录到达即覆盖(紧跟客户端);
# 边沿累积(|=)不覆盖 ⇒ 一次到多条记录也不丢边沿(抓梯/跳跃/开火都靠边沿);缺包时 held 保持上一条,边沿在记录消费后由 MatchHost 的 clear_edges() 清空。
# ★ 本类只留队列/边沿/latch 语义 + PlayerInput 实现:线格式(位定义/协议常量/pack_*/unpack_pair)已搬 core/net/input_wire.gd;下面别名与转发壳保住原公共 API(同名同签名)。

# ── 线格式转发壳:数值与实现的唯一来源 = InputWire;别名只为保住 `PacketInputSource.BIT_*` 等既有引用 ──
const BIT_UP := InputWire.BIT_UP
const BIT_DOWN := InputWire.BIT_DOWN
const BIT_CHARGE := InputWire.BIT_CHARGE
const BIT_ATTACK := InputWire.BIT_ATTACK
const BIT_RELOAD := InputWire.BIT_RELOAD
const BIT_PICKUP := InputWire.BIT_PICKUP
const BIT_DROP := InputWire.BIT_DROP
const BIT_HASTE := InputWire.BIT_HASTE
const BIT_REWIND := InputWire.BIT_REWIND
const BIT_NEED_FULL := InputWire.BIT_NEED_FULL
const TICKS_PER_RECORD := InputWire.TICKS_PER_RECORD
const INPUT_BATCH_TICKS := InputWire.INPUT_BATCH_TICKS


# ── 线格式函数转发壳(公共 API 同名同签名;实现 = InputWire)──
static func pack_record(src: PlayerInput, seq: int, aim: Vector2, snap_tick: int = 0,
		client_tick: int = 0, need_full: bool = false) -> Dictionary:
	return InputWire.pack_record(src, seq, aim, snap_tick, client_tick, need_full)


static func pack_pair(lo_rec: Dictionary, hi_rec: Dictionary, aim: Vector2, snap_tick: int = 0,
		client_tick: int = 0) -> Dictionary:
	return InputWire.pack_pair(lo_rec, hi_rec, aim, snap_tick, client_tick)


# 服务端拆包:还原成两条"逐 tick 记录"(键集与 pack_record 一致,供队列/apply_packet 直接用)。
static func unpack_pair(pkt: Dictionary) -> Array:
	return InputWire.unpack_pair(pkt)

var _axis := 0.0
var _held := 0
var _aim := Vector2.ZERO   # 注入的瞄准方向(世界坐标系)
var _switch_inst := 0      # 上行包里的权威切枪目标(**inst**);>0 = 本次有切枪请求
var _pressed := 0          # 累积的 just_pressed 边沿(玩家读取,MatchHost 每帧末清除)
var _released := 0         # 累积的 just_released 边沿


func source_kind() -> int:
	return Kind.PACKET


# ── 输入队列:自适应抖动缓冲上限。队列单位 = **一条 tick 记录**(不是包;一包进两条)。──
# 原先写死 MAX_PENDING_INPUT = 8,而它同时是上限又是稳态(生产与消费是两个独立时钟)⇒ 队列长度是带反射壁的零漂移随机游走,没有回复力
# ⇒ 那层延迟永久(ack 永久落后)。现在上限跟实测抖动包络走:peak = 丢之前的原始深度(每 tick 衰减 1)⇒ cap = peak + MARGIN,钳在 [MIN,MAX]。
# ★ 口径:U1 后一条记录 = 1 tick ⇒ MIN/MAX/MARGIN 翻倍以保住同样的**时间**缓冲 [4,16] 条 = [66,266] ms;每丢一条 = 服务器少模拟 1 tick ⇒ C2 回滚纠正一次(有界)。
const QUEUE_CAP_MIN := 4
const QUEUE_CAP_MAX := 16
const QUEUE_CAP_MARGIN := 2


static func adapted_cap(peak: int) -> int:
	return clampi(peak + QUEUE_CAP_MARGIN, QUEUE_CAP_MIN, QUEUE_CAP_MAX)


# 入队 + 有界化(静态纯函数):丢谁 = 最旧那一条,并把它的边沿并进新的队首(pressed/released/winst 走可靠通道就是为了不丢边沿)。
# 返回值 = 丢之前的原始深度(调用方拿它更新抖动包络 peak;只看丢完的深度学不到东西 —— 它永远 <= 上限)。
static func push_pending(q: Array, pkt: Dictionary, cap: int = QUEUE_CAP_MAX) -> int:
	q.append(pkt)
	var raw := q.size()
	while q.size() > cap:
		var old: Dictionary = q.pop_front()
		var nxt: Dictionary = q[0]
		nxt["pressed"] = int(nxt.get("pressed", 0)) | int(old.get("pressed", 0))
		nxt["released"] = int(nxt.get("released", 0)) | int(old.get("released", 0))
		if int(nxt.get("winst", 0)) <= 0 and int(old.get("winst", 0)) > 0:
			nxt["winst"] = int(old.get("winst", 0))
		q[0] = nxt
	return raw


# ★★ 轴是归一体但协议上无界(ax=50 在服务端约等于 35000px/s,全图才 9600px):不可信入口收口为 非有限(NAN/±INF)→ 0,否则钳到 [-1,1]。
# ★ 先判有限性再钳(不能假设 clampf 对 NaN 的行为);动机是协议健壮性、不是反作弊;合法输入(|ax| <= 1)逐位不变 ⇒ 不动手感。
static func sanitize_axis(v: float) -> float:
	if not is_finite(v):
		return 0.0
	return clampf(v, -1.0, 1.0)


func apply_packet(pkt: Dictionary) -> void:
	_axis = sanitize_axis(float(pkt.get("ax", 0.0)))
	_held = pkt.get("held", 0)
	_aim = pkt.get("aim", Vector2.ZERO)
	# 与旧 `_weapon` 同款语义:>0 才覆盖(0 = 本包没有切枪请求),由 clear_edges() 清空。
	var inst: int = pkt.get("winst", 0)
	if inst > 0:
		_switch_inst = inst
	_pressed |= pkt.get("pressed", 0)
	_released |= pkt.get("released", 0)

func haste_held() -> bool:
	return (_held & BIT_HASTE) != 0


func rewind_held() -> bool:
	return (_held & BIT_REWIND) != 0


# 每帧末清除已消费边沿与切枪(玩家 _physics_process 之后)。held/axis/aim 保留(缺包沿用)。
func clear_edges() -> void:
	_pressed = 0
	_released = 0
	_switch_inst = 0

# 全量复位(COUNTDOWN/局间冻结等权威停顿时用):连 held/axis 一起清 —— 单清边沿不够,上一包若带着方向,倒计时里玩家会照旧漂移。
func reset_state() -> void:
	_axis = 0.0
	_held = 0
	_aim = Vector2.ZERO
	_switch_inst = 0
	_pressed = 0
	_released = 0

# ── 覆写钩子(公开读口由基类持有并对 frozen 短路;本类不再各自处理冻结)──

func _axis_raw(neg: String, pos: String) -> float:
# 垂直轴由 held 位推导(输入包只传水平 ax):原实现一律返回 _axis ⇒ 服务器玩家攀附后挂梯不动、客户端正常上爬 ⇒ 大分歧与快照回拉(梯子回拉根因)。
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

# ★ 网络输入源没有"背包位置"这个量(上行传的是 inst)⇒ 位置读口恒 0;服务器取切枪目标走 _switch_inst_raw()。
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
