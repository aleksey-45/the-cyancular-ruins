# 玩家角色系统

> 本文档属于 [`CLAUDE.md`](../../CLAUDE.md) 架构分域文档。
> 涵盖范围：角色基础运动物理 · 姿态碰撞箱管理 · 组件化架构拆分 · 输入源抽象接口 · 弹药状态与回滚预测同步。

---

## 一、 角色运动与操作手感 (`CharacterBody2D`)

1. **移动与跳跃机制**：
   - 水平运动采用指数平滑缓动算法，确保精准的急停与启步操作手感。
   - 跳跃系统集成了土狼时间（Coyote Time）、跳跃输入缓冲（Jump Buffer）以及可变跳跃高度机制（松开跳跃键提前衰减垂直速度）。
   - 冲刺技能（持续 0.4s）：沿角色最近移动朝向快速位移，空中冲刺期间垂直重力大幅衰减（乘 `charge_air_gravity_mult = 0.35`）。
2. **下蹲与下冲**：
   - 下蹲采用逐物理帧推导判定：仅当角色处于地面且持续按住下蹲键（默认为 S）时处于下蹲姿态，在空中松开按键后落地不锁死下蹲，支持蹲伏移动。
   - 空中按住下蹲键触发空中下冲，加速向下砸向地面。
3. **姿态碰撞多边形切换**：
   - 角色维护站立、移动、下蹲、空中冲刺与倒地等多套姿态碰撞多边形（`CollisionPolygon2D`），运行时仅激活当前姿态对应的碰撞体，确保各姿态下的物理轮廓准确。
4. **受击、无敌帧与倒地**：
   - 受到非爆炸伤害时触发无敌帧（iframes）；受到爆炸伤害时计算独立的冲击速度向量（`knock_velocity`）并在后续帧中衰减。
   - 生命值归零进入倒地状态：倒地状态下不禁用物理模拟（仍受重力与击退影响），仅屏蔽玩家常规输入。
   - **单人模式原地复位**：单人模式中按 R 键调用 `Level0.restart_single()` 执行原地复位重置（瓦片与可破坏物还原为建图基线、清理弹药与敌人并重新生成、玩家满血满氧回到出生点），替代直接重载场景以避免引擎底层资源析构异常。

---

## 二、 组件化架构拆分

为了降低根节点脚本复杂度，玩家实体将功能拆分为独立子组件节点，各组件不重写自身的 `_physics_process`，完全由根节点每帧按固定顺序编排调用：
```text
Player (scenes/player/player.gd)
 ├─ ClimbComponent (攀爬判定、梯子/锁链逻辑)
 ├─ CombatComponent (受击结算、击退向量、无敌帧与复活)
 ├─ WeaponComponent (背包武器管理、开火与弹药状态维护)
 └─ SwimComponent (水体浮力、游泳与氧气呼吸逻辑)
```
- 根节点负责统一编排帧执行流：`ClimbComponent.update()` → 水平/垂直移动计算 → `CombatComponent.apply_knock()` → `move_and_slide()`。
- 根节点对外暴露 `take_hit()`、`is_downed()`、`apply_recoil()` 接口及 `hp_changed` 信号，接口契约由 `tests/smoke/player_contract_smoke.gd` 持续守护。

---

## 三、 输入抽象接口与网络注入

1. **输入源统一接口 (`core/net/player_input.gd`)**：
   - 抽象基类 `PlayerInput`，对外暴露 `get_axis()`、`is_held()`、`is_just_pressed()`、`is_just_released()` 等标准化方法。
   - 三种实现类通过 `source_kind()` 枚举区分：
     - `LocalInputSource`（`LOCAL`）：本地玩家输入，直接读取真实物理按键与鼠标准星。
     - `PacketInputSource`（`PACKET`）：服务端注入源，由客户端上传的网络输入包解码驱动。
     - `AIInputSource`（`AI`）：单人或对战人机 AI 行为驱动源。
2. **冻结与瞄准覆盖**：
   - 当对局处于开局倒计时（COUNTDOWN）状态时，通过设置 `frozen = true` 使所有输入读口返回中性零值，彻底锁死移动与开火。
   - 提供 `get_aim_dir_override()` 钩子，支持网络同步瞄准方向。

---

## 四、 弹药权威状态与客户端预测回滚

1. **弹药写入统一入口 (`WeaponComponent.apply_mag`)**：
   - 当武器实例已添加进场景树时，同步写入 `mag_ammo`；未入树实例写入 `pending_mag`，并在武器进入场景树调用 `_ready()` 时一次性消费。
   - 彻底废除帧末延迟写回机制（`call_deferred`），避免在客户端预测回滚过程中捕获旧弹药值覆盖重放开火消耗的问题。
2. **实例状态就绪标志 (`WeaponBase._mag_ready`)**：
   - 武器实例新增 `_mag_ready` 状态位，初值为 `false`，仅在 `_ready()` 流程末尾置为 `true`。开火逻辑中的空弹夹判定依赖该标志，确保在弹药量落定前不误触发自动换弹，避免动作丢失与声音误播。
