class_name TimeRules
extends RefCounted

# 多人对战时间玩法参数配置：支持建房时自定义设置并在服务端校验钳制。
#
# - 与单人模式 TimeParams 的分工：
#   - TimeParams：单人模式常量表，保持单人玩法行为稳定；
#   - TimeRules：每局动态配置的实例数据。房主在建房页配置 -> 随选项上报 ->
#     服务端 clamp_self() 校验后写入对局状态 -> 广播给所有客户端生效。
# - 本类无外部场景与 Autoload 依赖，客户端与服务端通用。
# - 客户端上报的数值不可信，统一以服务端校验后的数值为准。

# ── 默认数值 ──
const DEF_INITIAL := 1000.0
const DEF_CAP := 1800.0
const DEF_REWIND_BURN := 150.0     # 回溯消耗速率：颗粒/秒
const DEF_HASTE_BURN := 70.0       # 加速消耗速率：颗粒/秒
const DEF_WINDOW := 250.0          # 短期额度
const DEF_REGEN := 50.0            # 短期自动回复速率：颗粒/秒
const DEF_KILL_RATIO := 0.5        # 击杀获取比例（被击杀者账户总额度 × 此比例）
const DEF_BLOCK_GAIN := 10         # 每摧毁一个 16px 子格获取颗粒数
const DEF_DAMAGE_GAIN := 4         # 每造成 1 点伤害获取颗粒数（仅对敌方有效）
const DEF_HASTE_MULT := 3.0        # 加速倍率（固定 3.0 倍）

# ── 钳制范围（服务端防越界与建房滑条共用）──
const R_INITIAL := Vector2(0.0, 5000.0)
const R_CAP := Vector2(100.0, 9999.0)
const R_BURN := Vector2(10.0, 500.0)
const R_WINDOW := Vector2(0.0, 1000.0)
const R_REGEN := Vector2(0.0, 300.0)
const R_RATIO := Vector2(0.0, 1.0)
const R_BLOCK := Vector2(0.0, 200.0)
const R_DAMAGE := Vector2(0.0, 50.0)
const R_HASTE := Vector2(1.0, 10.0)

var initial := DEF_INITIAL
var cap := DEF_CAP
var rewind_burn := DEF_REWIND_BURN
var haste_burn := DEF_HASTE_BURN
var window := DEF_WINDOW
var regen := DEF_REGEN
var kill_ratio := DEF_KILL_RATIO
var block_gain := DEF_BLOCK_GAIN
var damage_gain := DEF_DAMAGE_GAIN
var haste_mult := DEF_HASTE_MULT


## 透支上限：等于短期额度。允许短期额度透支，但账户总额本身不透支。
func loan_limit() -> float:
	return window


## 规则数值范围限制：先约束短期额度，再保证容量上限不低于初始总额。
func clamp_self() -> void:
	window = clampf(window, R_WINDOW.x, R_WINDOW.y)
	initial = clampf(initial, R_INITIAL.x, R_INITIAL.y)
	cap = clampf(maxf(cap, initial), maxf(R_CAP.x, initial), maxf(R_CAP.y, initial))
	rewind_burn = clampf(rewind_burn, R_BURN.x, R_BURN.y)
	haste_burn = clampf(haste_burn, R_BURN.x, R_BURN.y)
	regen = clampf(regen, R_REGEN.x, R_REGEN.y)
	kill_ratio = clampf(kill_ratio, R_RATIO.x, R_RATIO.y)
	block_gain = int(clampf(float(block_gain), R_BLOCK.x, R_BLOCK.y))
	damage_gain = int(clampf(float(damage_gain), R_DAMAGE.x, R_DAMAGE.y))
	haste_mult = clampf(haste_mult, R_HASTE.x, R_HASTE.y)


static func from_dict(d: Dictionary) -> TimeRules:
	var r := TimeRules.new()
	r.initial = float(d.get("initial", DEF_INITIAL))
	r.cap = float(d.get("cap", DEF_CAP))
	r.rewind_burn = float(d.get("rewind_burn", DEF_REWIND_BURN))
	r.haste_burn = float(d.get("haste_burn", DEF_HASTE_BURN))
	r.window = float(d.get("window", DEF_WINDOW))
	r.regen = float(d.get("regen", DEF_REGEN))
	r.kill_ratio = float(d.get("kill_ratio", DEF_KILL_RATIO))
	r.block_gain = int(d.get("block_gain", DEF_BLOCK_GAIN))
	r.damage_gain = int(d.get("damage_gain", DEF_DAMAGE_GAIN))
	r.haste_mult = float(d.get("haste_mult", DEF_HASTE_MULT))
	r.clamp_self()
	return r


func to_dict() -> Dictionary:
	return {
		"initial": initial,
		"cap": cap,
		"rewind_burn": rewind_burn,
		"haste_burn": haste_burn,
		"window": window,
		"regen": regen,
		"kill_ratio": kill_ratio,
		"block_gain": block_gain,
		"damage_gain": damage_gain,
		"haste_mult": haste_mult,
	}


## 根据本规则创建颗粒账户实例（初始额度、上限、短期窗口、回复速率及透支上限均按规则配置）。
func make_account() -> GrainAccount:
	return GrainAccount.new(initial, cap, window, regen, loan_limit())


## 回溯缓冲区覆盖时长：满额持续回溯至耗尽所需时间（上限 / 回溯速率），最大上限 15 秒。
func rewind_buffer_seconds() -> float:
	if rewind_burn <= 0.0:
		return 0.0
	return minf(cap / rewind_burn, 15.0)
