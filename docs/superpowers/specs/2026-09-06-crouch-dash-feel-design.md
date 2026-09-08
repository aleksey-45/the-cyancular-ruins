# 下蹲 & 冲刺手感优化 — 设计

日期:2026-09-06
范围:`scenes/player/player.gd`(下蹲/冲刺段)+ `core/player_params.gd`(const)+ 可选一个 headless 冒烟。不涉及动画/碰撞盒/地图/网络协议。

## 背景与用户反馈

真机(单机与 PvP 同感)反馈:

- **下蹲**:①蹲下后不能移动(一蹲就钉死);②"S 明明是松开状态依然在下蹲"。
- **冲刺**:①不可控 / 不能取消(0.6s 固定 1500px/s≈900px 冲满,方向锁死,像发射出去);②空中冲刺受重力影响太大(抛物线坠地,跨沟难)。

现状代码事实(已核对):

- `is_squat` 由 `down` 的 `just_pressed`/`just_released` **边沿**切换,且 `just_released` 分支套在 `if is_on_floor()` 里 → **空中松开 S 不会站起**,落地后仍蹲(用户②根因)。`player.gd:259-271`。
- 姿态碰撞盒 stand≈43 / squat≈37(仅矮 ~6px,非钻缝用途);下蹲价值 = 缩小受击轮廓 + 停身。
- 冲刺:`charge_duration=0.6`、`charge_velocity=1500`;结束 `velocity.x -= 1500*0.5` 突变半刹;冲刺中 `set_facing` 锁向;空中全额吃重力。`PlayerParams:22-25`、`player.gd:273-304`。

## 目标手感

### 1. 下蹲
- **修复卡蹲**:`is_squat` 改为**逐帧由输入态推导**(按住 `down` + `is_on_floor()` + 非 latched/in_water),不再靠 just_pressed/released 边沿。空中松开不再残留;落地时若仍按住 `down` 自动保持蹲(下冲落地→蹲,自然)。
- **蹲走**:蹲下可小碎步左右走,新增 `crouch_walk_speed`(≈0.35×move_speed=245);蹲态横移目标是该低速(正常 accel 缓动逼近),进蹲不再 `velocity.x=0` 硬刹。`is_squat` 作为每帧推导结果继续供 climb/姿态/武器/碰撞盒读取(接口不变)。
- **下冲保留**:空中按 `down` 仍下冲(不受推导影响;空中不满足 is_on_floor → 不会误判为蹲)。
- 不做"低矮通道钻洞"机制(squat 盒只矮 6px,地图无此缝,收益低、改动大)。

### 2. 冲刺
- **时长**:`charge_duration` 0.6 → **0.4**(×1500 = 600px,约 9 身位)。方向判定、锁向逻辑不变。
- **跳跃打断**:冲刺中触发跳跃(`up` just_pressed)即结束冲刺(`is_charge=false`、`charge_timer=0`),保留当前水平速度作为动量(落地/空中由正常 accel/air-brake 平滑接管),转跳。手感"冲→跳→惯性继续"而非钉住。
- **撞墙自然停**:`is_charge` 且本帧 `move_and_slide` 撞到水平墙(normal.x≠0)→ 立即结束冲刺(不再顶着墙冲满)。
- **空中重力削减**:空中冲刺期间垂直重力累加 ×`charge_air_gravity_mult=0.35`(仅 is_charge 且非地面那几帧);结束恢复全额。`player.gd` 垂直逻辑段按此折算。
- **收尾平滑**:删掉 `is_charge` 结束时的 `velocity.x -= charge_velocity*facing*0.5` 突变;结束时速度交回水平 accel/brake 分支自然过渡(冲刺惯性由 `brake_ground`/`brake_air` 指数收)。

## 参数(PlayerParams)
```
# ── 冲刺 ──
charge_down_velocity: 2000   (不变)
charge_velocity: 1500        (不变)
charge_duration: 0.4         # 0.6 → 0.4(600px)
charge_air_gravity_mult: 0.35  # 空中冲刺重力倍率(新)
# ── 下蹲 ──
crouch_walk_speed: 245       # 蹲走速度(≈0.35×700,新)
```
删除 `velocity.x -= charge_velocity*facing*0.5` 那行。

## 数据流 / 确定性与兼容

- 仅改 `player.gd` 下蹲/冲刺/垂直重力几段 + `PlayerParams` const。`is_squat`/`is_charge`/`charge_timer`/`_last_move_*` 已被 `capture_state/restore_state` 覆盖(player.gd:410-489),新增逻辑不新增状态字段(蹲走速度、重力倍率、动量均为 const/局部)→ **C2/PvP 孪生不受影响**(两端同参、同分支)。
- `is_squat` 从"边沿赋值"改为"每帧推导赋值"——仍是 `capture_state` 的 `squat` 字段,网络整态照旧。
- 冲刺打断/撞墙结束都只写 `is_charge=false`(已有字段),无协议变更。

## 测试

新增 headless 冒烟 `tests/move_feel_smoke.gd`(SceneTree 或 scene 模式,手动喂 `NetworkInputSource` 记录,复用 twin/reconcile 的建世界方式),断言:
1. 地面按 `down` → `is_squat` true;**空中松开 down 再落地 → is_squat false**(回归②卡蹲)。
2. 蹲态喂水平轴 → x 速度被限到 ≈crouch_walk_speed 且不超 move_speed。
3. 冲刺触发后按 `up` → `is_charge` false 且 velocity.x 仍 >0(动量保留)。
4. 冲刺撞水平墙 → `is_charge` 立即 false。
5. 空中冲刺:垂直向速度增量按 0.35 重力折算(与不冲对比)。
6. 冲刺时长 ≤0.4 时自动结束。

回归:`enemy_logic_smoke` + 三个 PvP 冒烟(twin/reconcile/match)须保持绿(尤其 twin 断言 capture/restore 字段不新增发散)。

## 不做(范围外)
- 不新增冲刺次数/冷却/资源(保留现状一键一段)。
- 不改冲刺方向判定模型(仍走最近移动方向/朝向),除非实测方向感仍差。
- 不做下蹲钻矮缝、蹲跳、冲刺转向。
