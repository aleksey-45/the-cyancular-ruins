class_name TimeRules
extends RefCounted

# PvP 时间玩法参数总表(2026-09-28,P2 线):**建房页可自定义**的全部数值 + 服务器侧钳制。
#
# ★ 与单机 `TimeParams` 的分工:
#   · `TimeParams` 是**单机**用的 const 表 —— 单机行为逐位不变,本类不碰它;
#   · `TimeRules` 是**每局可调**的实例数据:房主在 Beta 建房页改 → `player_options` 上报 →
#     服务器 `clamp_self()` 后写进对局状态 → 随 `match_start` / `match_sync` 下发,全员同一份规则。
# ★ 本类零 autoload / 零场景依赖:服务器与客户端共用,-s 探针可直接测。
# ★ 客户端上报的数值**不可信** —— 一切以服务器 clamp 后的那份为准。

# ── 默认配置（PvP 时间玩法基准数值）──
const DEF_INITIAL := 1000.0
const DEF_CAP := 1800.0
const DEF_REWIND_BURN := 150.0     # 时空回溯消耗速率（粒子/秒）
const DEF_HASTE_BURN := 70.0       # 时间加速消耗速率（粒子/秒）
const DEF_WINDOW := 250.0          # 短期使用额度
const DEF_REGEN := 50.0            # 短期额度恢复速率（粒子/秒）
const DEF_KILL_RATIO := 0.5        # 击杀获取比例 = 目标账户总额度 × 此比例（目标自身余额不扣除）
const DEF_BLOCK_GAIN := 10         # 瓦片破坏奖励：每摧毁一个 16px 子格获取的粒子数
const DEF_DAMAGE_GAIN := 4         # 伤害奖励：每造成 1 点伤害获取的粒子数（仅限敌方，自伤/友伤不奖励粒子）
const DEF_HASTE_MULT := 3.0        # 加速倍率（固定为 3.0×，不在房间创建面板开放调节）

# ── 钳制范围(服务器侧防越界;建房页滑条也用同一套)──
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


## 透支上限：等于短期额度（启用透支机制，但透支仅限短期额度内，账户总余额不为负）。
func loan_limit() -> float:
	return window


## 服务端与房间设置共用的数值钳制范围。限制顺序：先钳制 window（透支上限由此推导），再钳制 cap ≥ initial。
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


## 构建本规则对应的时间粒子账户（初始值、上限、短期窗口、恢复率、透支额度均按此规则配置）。
func make_account() -> GrainAccount:
	return GrainAccount.new(initial, cap, window, regen, loan_limit())


## 状态回溯环形缓冲区所需覆盖的秒数 = 从满额消耗至空所需时间（上限 / 回溯消耗速率），上限为 15s。
func rewind_buffer_seconds() -> float:
	if rewind_burn <= 0.0:
		return 0.0
	return minf(cap / rewind_burn, 15.0)
