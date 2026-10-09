class_name PacketInputSource
extends PlayerInput

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
# ★ 2026-09-15 新增:换弹位(R)。此前 PvP 两端**一致地**不换弹(`WeaponBase.reload_active()`
#   在 pvp_mode / 网络输入源下恒 false),所以输入包不需要它 —— 而 `_bit("R")` 原先恒返回 0,
#   意味着**服务器没有任何别的通路**能知道客户端按了 R(换弹不走 is_attack_* 那族抽象)。
#   现在换弹对全模式开放,按下的边沿必须上行,由服务器在权威模拟里同样触发一次装填。
# ⚠ 加位 = **改协议**:与旧 build 的输入包互不认(位掩码里多一位,旧端读到的 held/pressed
#   少一位、不影响其余四位)。两端必须同版本。
const BIT_RELOAD := 16
# ★ 2026-09-15 新增:拾取(F)与丢弃(Q)。两个都是**边沿**语义 ——
#   · F:按下的那一帧一次
#   · Q:客户端自己累计按住时长,满 2s 的那一刻发一次边沿(见 PlayerParams.weapon_drop_hold_time)。
#     上行的是"完成信号"而不是"按住",所以 **held 段不加这两位**(加了反而会让服务器以为
#     只要按着就该丢,而服务器没有本地计时器)。
# ⚠ 加位 = **改协议**:两端必须同版本(同 BIT_RELOAD 的注释)。
const BIT_PICKUP := 32
const BIT_DROP := 64
# ★ Beta 时间玩法(P2,2026-09-29):加速按住位。**held 段**(按住语义,非边沿)——
# 服务器据此角色进入加速态(自己 ×3,不动别人);是否真加速由服务器按颗粒账户裁决。
# ⚠ 加位 = 改协议,两端必须同版本(同 BIT_RELOAD 注释)。
const BIT_HASTE := 128
# ★ Beta 时间玩法:回溯按住位(held 段)。服务器据此进入该 role 的自身回溯态。
const BIT_REWIND := 256


# ── 编码端:组一个输入包(协议**发送侧**的唯一来源)──
# ★ 为什么必须收在这里:这段 30 行的位打包原先在 `pvp_client` 与 `royale_game` 里**各手抄一份**,
#   而**解码端**(本类的 apply_packet / _bit / get_axis)只有一份。编码端分叉不会有任何报错:
#   加一个 held 位只改一个客户端 → 该键在一个模式里永远没反应;把 CHARGE 抄成 ATTACK 也拦不住。
#   (`--` 两份此前确实只差一句注释,但在它们真分叉之前收口。)
# ★ seq / aim 由调用方给:它们来自场景(`_input_seq` 单调自增、`player.get_current_aim_dir()`),
#   不属于"协议编码"这件事。
# ★ 读 src 走公开读口 → 自动遵守 `frozen`(COUNTDOWN 冻结期组出来的是全中性包,与旧行为一致)。
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
	# 拾取/丢弃:只进 pressed(边沿),不进 held(见 BIT_PICKUP 的注释)
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
		# ★ 上行键 = winst,值是**目标那一把的 inst**。旧的 `"weapon"` 键**已删除** ——
		#   它带的是背包位置(1-based),而位置的含义由**本端背包**决定(见 weapon_component
		#   的 request_net_cycle 注释)。本函数是**编码端唯一来源**,故 inst 在这里是**空的**:
		#   `pack_record` 只拿得到 `PlayerInput`、拿不到背包 —— 解析由组包处补上
		#   (`pvp_match_client` 的 `weapons.take_uplink_switch(src.get_switch_index_pressed())`)。
		#   ★ 键**必须在这里声明**(带 0 占位):解码端(apply_packet)对 0 的语义是
		#     "本包没有切枪请求",与旧键的 0 语义逐字相同;组包处只在解析出 >0 时覆盖。
		#     (探针 `weapon_switch_inst_probe` 相① 源码级钉着这个键在**本文件**里。)
		"winst": 0,
		"aim": aim,
	}

var _axis := 0.0
var _held := 0
var _aim := Vector2.ZERO   # 注入的瞄准方向(世界坐标系)
var _switch_inst := 0      # 上行包里的权威切枪目标(**inst**);>0 = 本次有切枪请求
var _pressed := 0          # 累积的 just_pressed 边沿(玩家读取,MatchHost 每帧末清除)
var _released := 0         # 累积的 just_released 边沿

# 新包到达(服务器 RPC 回调里调用):held/axis/aim/weapon 取最新,边沿累积。
# 输入源种类(基类 PlayerInput.Kind;阶段 5.9 起接口要求实现)。
func source_kind() -> int:
	return Kind.PACKET


# ★★ 2026-10-08(closeout 批 Task 4):轴是**归一化**量,但协议上**无界** —— `ax=50` 在服务端
#   约等于 35000px/s(全图才 9600px)。这里把**不可信入口**收口:非有限(NAN / ±INF)→ 0,
#   否则钳到 [-1,1]。
#   ★ 为什么**先判有限性再钳**:不能假设 `clampf` 对 NaN 的行为(它可能原样返回 NaN)。
#   ★ 动机是**协议健壮性**(版本不匹配的客户端 / 有 bug 的客户端 / 单机壳里跑出来的包),
#     **不是反作弊** —— 伪造**合法范围内**的包不在此列的防护目标(用户已裁定不承担)。
#   ★ 合法输入(`|ax| ≤ 1`)**逐位不变** ⇒ 不动手感。
#   ★ 它是**静态纯函数**:判据可以 headless 直调,不需要真服务器
#     (见 `tests/smoke/server_input_sanitize_smoke.gd`)。
## ── 输入队列:自适应抖动缓冲上限(2026-10-09,债单 §六.29 落地)──
##
## **原来是什么**:一个写死的 `MAX_PENDING_INPUT = 8`,超了就把最旧那包丢掉(边沿并入队首)。
## 问题不在"8 这个数",而在**它同时是上限、又是稳态**:生产恰好 1 包/tick、消费恰好 1 包/tick
## (后者是 C2 回滚要的 1:1 同序),两边是两个独立时钟 ⇒ 队列长度是**带反射壁的零漂移随机游走**
## ⇒ 长期停在壁附近、**没有任何机制把它拉回 0**。于是那一层 133ms 的输入延迟是**永久**的
## (ack 永久落后 ⇒ 客户端重放窗口永久变长)。详见 `docs/eng/netcode-snapshots.md` §4.2。
##
## **现在是什么**:上限改成**跟着实测抖动包络走**的抖动缓冲 ——
##   · `peak` = 最近"一 tick 内到过几包"的**原始**深度(丢包**之前**的数,见 `push_pending` 的返回值),
##     每 tick 衰减 1 ⇒ 网络一安静,缓冲就自己缩回去(**这就是那个缺失的回复力**);
##   · 上限 = `peak + 1`,钳在 `[QUEUE_CAP_MIN, QUEUE_CAP_MAX]`。
## ⇒ 稳态深度 ≈ 最近的抖动幅度(典型 1~3 tick = 17~50ms),而不是永远顶在 8(133ms);
##   只有**超出包络**(真突发)才丢,且丢的永远是**最旧**那包、边沿并入下一包 ⇒ 玩家的按键不丢。
##   ★ 代价照实说:每丢一包 = 服务器少模拟一个 tick 的输入 ⇒ 客户端**靠 C2 回滚**纠正一次
##     (有界、单 tick 量级)。这是"低延迟换偶发小纠正",与今天"零纠正、永久 133ms 延迟"相反。
##
## ★ 常量口径:`QUEUE_CAP_MAX` = 原 `MAX_PENDING_INPUT`(硬顶,不改今天的最坏情况);
##   `QUEUE_CAP_MIN` ≥ 2 —— 1 意味着"一 tick 到两包就丢",而**抖动本身就是会一 tick 到两包**
##   (客户端物理追赶时成串发,见 `pvp_match_client._netstat_tick` 的注释)。
const QUEUE_CAP_MIN := 2
const QUEUE_CAP_MAX := 8
const QUEUE_CAP_MARGIN := 1


## 由"最近见过的原始深度"推出本 tick 的上限(纯函数,`-s` 可直接判)。
static func adapted_cap(peak: int) -> int:
	return clampi(peak + QUEUE_CAP_MARGIN, QUEUE_CAP_MIN, QUEUE_CAP_MAX)


## 入队 + **有界化**(静态纯函数)。丢谁 = **最旧那一包**,并把它的**边沿**并进新的队首 ——
## `pressed`/`released`/`winst` 走可靠通道就是为了"不丢边沿"(见本文件头),丢掉它 = **偶发丢一跳**。
## 返回值 = **丢之前**的原始深度(调用方拿它更新抖动包络 `peak`;只看丢完的深度学不到东西 ——
## 它永远 ≤ 上限)。
static func push_pending(q: Array, pkt: Dictionary, cap: int = QUEUE_CAP_MAX) -> int:
	q.append(pkt)
	var raw := q.size()
	while q.size() > cap:
		var old: Dictionary = q.pop_front()
		var nxt: Dictionary = q[0]
		nxt["pressed"] = int(nxt.get("pressed", 0)) | int(old.get("pressed", 0))
		nxt["released"] = int(nxt.get("released", 0)) | int(old.get("released", 0))
		# 切枪请求:>0 才覆盖(`apply_packet` 同款语义)⇒ 只在新队首没有请求时承接旧的。
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

# Beta 时间玩法:该 role 此刻是否按着加速(held 位直读;服务器的时间态裁决用)。
func haste_held() -> bool:
	return (_held & BIT_HASTE) != 0


func rewind_held() -> bool:
	return (_held & BIT_REWIND) != 0


# 每帧末清除已消费边沿与切枪(玩家 _physics_process 之后)。held/axis/aim 保留(缺包沿用)。
func clear_edges() -> void:
	_pressed = 0
	_released = 0
	_switch_inst = 0

# 全量复位(COUNTDOWN/局间冻结等权威停顿时用):连 held/axis 一起清,玩家彻底静止。
# 单清边沿不够——上一包若带着方向,倒计时里玩家会照旧漂移(服务器渲染路径被快照掩盖,
# C2 预测路径下=分歧源)。
func reset_state() -> void:
	_axis = 0.0
	_held = 0
	_aim = Vector2.ZERO
	_switch_inst = 0
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

# ★ 网络输入源**没有"背包位置"这个量**(上行传的是 inst)⇒ 位置读口恒 0。
#   服务器取切枪目标走 `_switch_inst_raw()`(见 `PlayerInput.consume_switch_inst`)。
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

# 网络注入 → 服务器/远端模拟的玩家武器瞄准不读宿主机鼠标(注入 ZERO 用朝向兜底)。
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
