class_name InputWire
extends RefCounted

# 输入上行线格式的编码端(S-05):位定义 + 协议常量 + 单 tick 记录 / 线上包互转;2026-10-30 从 packet_input_source.gd 逐字搬出,数值/位/时序零改动。
# 解码侧表驱动唯一来源仍是 core/net/net_codec.gd 的 INPUT_SCHEMA + encode_input/decode_input(漂移由 tests/smoke/net_wire_smoke.gd ④ 挡);
# 公共入口 = PacketInputSource 上的同名转发壳(调用点零改动)。纯 RefCounted + 全 static,可 `-s` 跑。

const BIT_UP := 1
const BIT_DOWN := 2
const BIT_CHARGE := 4
const BIT_ATTACK := 8
# ★ 换弹位(R):换弹不走 is_attack_* 那族抽象,按下边沿由服务器在权威模拟里同样触发一次装填。⚠ 加位 = 改协议,两端必须同版本。
const BIT_RELOAD := 16
# ★ 拾取(F)/丢弃(Q)是边沿语义(上行完成信号不是按住 ⇒ held 段不加这两位);加速/回溯是 held 位,是否真生效由服务器裁决。⚠ 加位 = 改协议。
const BIT_PICKUP := 32
const BIT_DROP := 64
const BIT_HASTE := 128
const BIT_REWIND := 256
const BIT_NEED_FULL := 512   # v7 起为**保留位**:差分已删 ⇒ 恒不置位(加位 = 改协议;历史见 netcode-input-uplink.md)

# ── 协议常量(两端必须同版本):一条记录 = 1 个物理 tick(60Hz 真输入、不锁存;C2 重放 1 步/记录);
#   2026-11-01 起**发包也是 60Hz**:每 tick 一包、包内一条记录(原 30Hz 一包两条的合包被撤 —— 它把输入延迟最多多压 1 tick,
#   且重传一次要补两条记录;代价是包数×2、每包头 2 B。带宽 28 B×60 ≈ 1.68 KB/s/客户端)。──
const TICKS_PER_RECORD := 1
const INPUT_BATCH_TICKS := 1   # 每包几条记录(现状 = 1:60Hz 一包一条)


# ── 编码端:组一个输入包(协议发送侧的唯一实现)──
# ★ 位打包原先在两个客户端各手抄一份、解码端只有一份;编码端分叉不报错(某键在一个模式里永远没反应)⇒ 收在这里。
# ★ seq/aim/st/ct 由调用方给;src 走公开读口 ⇒ 自动遵守 frozen(冻结期组出全中性包);st/ct 默认 0 让老调用点不用改。
#   st = 最近成功解码的服务器快照 tick(命中回放时间基准);ct = 客户端物理帧号(仍只落位)。
static func pack_record(src: PlayerInput, seq: int, aim: Vector2, snap_tick: int = 0,
		client_tick: int = 0, need_full: bool = false) -> Dictionary:
	var held := 0
	var pressed := 0
	var released := 0
	if need_full:
		held |= BIT_NEED_FULL
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
# ★ 上行键 = winst(目标那一把的 inst):本函数拿不到背包 ⇒ 这里声明 0 占位(0 = 本包无切枪请求),解析由组包处补上。
		"winst": 0,
		"aim": aim,
		"st": snap_tick,     # 两个只落位的扩展字段(本批无消费者):线格式只改这一次 ⇒ 现在就进 schema。
		"ct": client_tick,
	}


# ── 编解码端:一包一条记录(60Hz)── 记录字典与 pack_record() 的键集逐字一致,
#   由 NetCodec.encode_input 手打包、decode_input 表驱动解包;服务端收到即当作一条 tick 记录入队(不再拆包)。
