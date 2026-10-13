# 玩家角色系统

本文档说明玩家角色的运动学控制、姿态碰撞管理、组件化拆分架构、输入源抽象及弹药预测同步机制。

---

## 一、 角色运动与操作手感 (`CharacterBody2D`)

### 1. 移动与跳跃机制
- **水平移动**：采用平滑插值加速与减速，提供敏捷的急停和启步操控感。
- **跳跃系统**：集成土狼时间（离开平台边缘后短暂窗口内仍允许起跳）、跳跃输入缓冲（落地前预输入起跳）以及可变跳跃高度机制（松开跳跃键可提前截断上升速度）。
- **冲刺技能**：持续 0.4 秒，沿移动朝向快速位移；空中冲刺期间垂直重力大幅降低（乘以系数 `charge_air_gravity_mult = 0.35`）。

### 2. 下蹲与下冲
- **下蹲判定**：在地面且按住下蹲键（默认 S）时进入下蹲姿态，支持蹲伏移动；空中松开按键落地后不会误锁下蹲。
- **空中下冲**：在空中按住下蹲键可触发下冲，加速向下俯冲砸向地面。

### 3. 姿态碰撞多边形
- 角色维护站立、移动、下蹲、空中冲刺与倒地等多套碰撞多边形（`CollisionPolygon2D`）。
- 运行时根据当前状态仅启用对应的碰撞形状，保证不同姿态下的碰撞盒轮廓准确。

### 4. 受击、无敌帧与倒地
- **受击与击退**：受到非爆炸伤害时进入短暂无敌帧；受到爆炸伤害时计算独立的冲击速度（`knock_velocity`），在后续帧中指数衰减。
- **倒地状态**：生命值归零时进入倒地状态。此时物理引擎依然正常模拟（继续受重力与击退影响），仅屏蔽玩家的操作输入。
- **单人模式原地重置**：按 R 键调用 `Level0.restart_single()`，还原破坏瓦片、重置敌人与弹药，并将满状态玩家放回出生点。

---

## 二、 组件化架构拆分

为了降低玩家主脚本（[`scenes/player/player.gd`](../../scenes/player/player.gd)）的复杂度，将具体业务拆分为子组件节点，各组件不自行运行 `_physics_process`，完全由玩家根节点统一调度：

```text
Player (CharacterBody2D；物理根节点)
 ├─ Visuals (角色与武器的共同表现偏移)
 │   ├─ AnimatedSprite2D
 │   └─ WeaponSlot
 ├─ ClimbComponent (梯子与铁链攀爬逻辑)
 ├─ CombatComponent (受击伤害结算、击退、无敌帧与复活)
 ├─ WeaponComponent (背包武器管理、开火与弹药状态)
 └─ SwimComponent (水体浮力、游泳与氧气消耗)
```

- **执行顺序**：输入记录交给共享 ActorStep，推进武器、游泳、攀爬、移动与碰撞，返回动作；初次预测、单人或服务端执行这些动作。预测恢复与重放只推进玩法状态，完成后由 Player.present_tick 更新动画、预瞄线、闪烁和 HUD。
- **位置边界**：CharacterBody2D 始终保持实际玩法位置；Visuals 的世界校正误差在 50 ms 内衰减，角色与武器一起平滑。shot_origin 剔除该视觉偏移，保证弹道不受表现校正影响。
- **受击边界**：CombatComponent 更新 HP、倒地、击退和无敌帧；Player.play_hit_feedback 为单人受击和联机 HIT 提供音效、挤压、后处理和镜头反馈。恢复状态不重新触发死亡或受击表现。
- **接口契约**：对外统一提供 `take_hit()`、`is_downed()`、`apply_recoil()` 等方法及 `hp_changed` 信号，契约由 `tests/smoke/player_contract_smoke.gd` 保证。

---

## 三、 输入抽象接口与网络注入

### 1. 输入源统一抽象 (`core/net/player_input.gd`)
- 抽象基类 `PlayerInput` 定义了 `get_axis()`、`is_held()`、`is_just_pressed()`、`is_just_released()` 等标准输入方法。
- 具体实现类通过 `source_kind()` 区分：
  - `LocalInputSource`：本地玩家输入，直接采集键盘与鼠标操作。
  - `PacketInputSource`：服务端使用，解析客户端上传的网络输入包。
  - `AIInputSource`：人机 AI 行为驱动源。

### 2. 输入冻结与瞄准覆盖
- 开局倒计时（`COUNTDOWN`）阶段将 `frozen` 设为 `true`，所有移动与开火输入返回中性零值，锁定角色行动。
- 通过 `get_aim_dir_override()` 钩子支持网络同步瞄准方向。

---

## 四、 弹药权威状态与预测回滚同步

1. **弹药赋值通道 (`WeaponComponent.apply_mag`)**：
   - 武器节点已在场景树中时，直接写入 `mag_ammo`；未进入场景树时暂存至 `pending_mag`，待武器节点的 `_ready()` 触发时消费。
   - 弹药变化直接同步写回库存。
2. **武器就绪标记 (`WeaponBase._mag_ready`)**：
   - 武器节点初始化完成时将 `_mag_ready` 置为 `true`。开火逻辑中的空弹判定依赖该标记，确保弹药数据初始化完成前不会误触发换弹动作与音效。
3. **库存恢复与通知**：切换权威手持武器前先卸下旧武器，再写入新库存，避免旧弹药回写污染新背包。inventory_changed 只在表现更新时合并发送，HUD 使用最终状态。

源码参考、预测调用顺序及断流处理见 [架构参考](architecture_references.md)。
