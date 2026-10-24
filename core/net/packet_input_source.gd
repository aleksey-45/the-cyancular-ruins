class_name PacketInputSource
extends PlayerInput

# 网络注入输入(服务器权威模拟的唯一消费方):从输入包取轴/按键/边沿/切枪/瞄准。
# held/axis/aim/weapon 新记录到达即覆盖(紧跟客户端);边沿累积(|=)不覆盖 ⇒ 一次到多条记录也不丢边沿(抓梯/跳跃/开火都靠边沿)。
# 缺包时(无新记录)held 保持上一条,边沿在记录消费后由 MatchHost 的 clear_edges() 清空 ⇒ 第二条 tick 沿用 held。

const BIT_UP := 1
const BIT_DOWN := 2
const BIT_CHARGE := 4
const BIT_ATTACK := 8
# ★ 换弹位(R):换弹对全模式开放后,按下的边沿必须上行(换弹不走 is_attack_* 那族抽象),由服务器在权威模拟里同样触发一次装填。⚠ 加位 = 改协议,两端必须同版本。
const BIT_RELOAD := 16
# ★ 拾取(F)与丢弃(Q)都是边沿语义:F = 按下那一帧一次;Q = 客户端累计按住满阈值那一刻发一次(见 PlayerParams.weapon_drop_hold_time)。上行的是完成信号不是按住 ⇒ held 段不加这两位。
const BIT_PICKUP := 32
const BIT_DROP := 64
# ★ 加速按住位(held 段):服务器据此让该 role 进入加速态(自己 ×3,不动别人);是否真加速由服务器按颗粒账户裁决。⚠ 加位 = 改协议。
const BIT_HASTE := 128
# ★ Beta 时间玩法:回溯按住位(held 段)。服务器据此进入该 role 的自身回溯态。
const BIT_REWIND := 256


# ── 编码端:组一个输入包(协议发送侧的唯一来源)── ★ 必须收在这里:这段位打包原先在两个客户端各手抄一份,而解码端只有一份;
# 编码端分叉不报错(某键在一个模式里永远没反应)。★ seq/aim/st/ct 由调用方给(来自场景);★ 读 src 走公开读口 ⇒ 自动遵守 frozen(冻结期组出全中性包)。
# ★ st/ct 带默认值 0:老调用点(-s 冒烟/探针手工组包)不用改;只有真客户端(PvpMatchClient)传真实值。
#   st = 本端**最近成功解码**的服务器快照 tick(增量批的基线来源);ct = 本帧客户端物理帧号。本批只落位,无消费者。
static func pack_record(src: PlayerInput, seq: int, aim: Vector2, snap_tick: int = 0,
		client_tick: int = 0) -> Dictionary:
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
	if src.is_pickup_pressed():
		pressed |= BIT_PICKUP
	if src.is_drop_pressed():
		pressed |= BIT_DROP
	return {
		"seq": seq,          # 单调输入序号(服务器按序消费并回带 ack,rollback 用)
		"ax": src.get_axis("left", "right"),
		"held": held,
		"pressed": pressed,
		"released": released,
# ★ 上行键 = winst(目标那一把的 inst):pack_record 只拿得到 PlayerInput、拿不到背包,故键必须在这里声明带 0 占位
# (0 = 本包没有切枪请求,与旧键 0 语义逐字相同),解析由组包处补上。
		"winst": 0,
		"aim": aim,
		# 两个只落位的扩展字段(见本函数头注释):本批无消费者,但线格式只改这一次 ⇒ 现在就进 schema。
		"st": snap_tick,
		"ct": client_tick,
	}

var _axis := 0.0
var _held := 0
var _aim := Vector2.ZERO   # 注入的瞄准方向(世界坐标系)
var _switch_inst := 0      # 上行包里的权威切枪目标(**inst**);>0 = 本次有切枪请求
var _pressed := 0          # 累积的 just_pressed 边沿(玩家读取,MatchHost 每帧末清除)
var _released := 0         # 累积的 just_released 边沿

func source_kind() -> int:
	return Kind.PACKET


# ★★ 轴是归一体但协议上无界(ax=50 在服务端约等于 35000px/s,全图才 9600px):不可信入口收口为 非有限(NAN/±INF)→ 0,否则钳到 [-1,1]。
# ★ 先判有限性再钳(不能假设 clampf 对 NaN 的行为);动机是协议健壮性、不是反作弊;合法输入(|ax| <= 1)逐位不变 ⇒ 不动手感。
# ── 输入队列:自适应抖动缓冲上限。原先写死 MAX_PENDING_INPUT = 8,而它同时是上限又是稳态(生产 1 条/2 tick 与消费 1 条/2 tick 是两个独立时钟)
# ⇒ 队列长度是带反射壁的零漂移随机游走,长期停在壁附近、没有任何回复力 ⇒ 那层输入延迟是永久的(ack 永久落后)。
# 现在上限跟着实测抖动包络走:peak = 最近一次轮询到过几条记录(丢之前的原始深度,每 tick 衰减 1)⇒ 上限 = peak + 1,钳在 [QUEUE_CAP_MIN, QUEUE_CAP_MAX];
# 网络一安静缓冲就自己缩回去。★ 常量口径:QUEUE_CAP_MAX 即原硬顶(不改最坏情况);QUEUE_CAP_MIN >= 2(1 意味着"一对 tick 到两条就丢",而抖动本身就会)。
# ★ 代价照实说:每丢一条记录 = 服务器少模拟 2 个 tick ⇒ 客户端靠 C2 回滚纠正一次(有界)。详见 docs/eng/netcode-snapshots.md §4.2。
const QUEUE_CAP_MIN := 2
const QUEUE_CAP_MAX := 8
const QUEUE_CAP_MARGIN := 1

# ── 一条输入记录覆盖几个物理 tick(协议约定,两端必须同版本)── 采样 30Hz / 物理 60Hz ⇒ 每条 2 tick。
# 服务端每条消费一次、连跑 2 个物理步;客户端本地预测与 C2 重放也按同一分组走(两端输入流必须逐 tick 相同,否则永久分歧)。
# ★ 别在客户端另抄一个数:采样/上行/C2 重放都读这一处。
const TICKS_PER_RECORD := 2


static func adapted_cap(peak: int) -> int:
	return clampi(peak + QUEUE_CAP_MARGIN, QUEUE_CAP_MIN, QUEUE_CAP_MAX)


# 入队 + 有界化(静态纯函数):丢谁 = 最旧那一包,并把它的边沿并进新的队首(pressed/released/winst 走可靠通道就是为了不丢边沿)。
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
