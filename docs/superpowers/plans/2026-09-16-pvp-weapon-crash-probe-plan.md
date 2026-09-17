# PvP 武器拾取崩溃：复现框架与排查方案

2026-09-16。**这份是"怎么把崩溃变成可复现的红灯"的方案，不含成因结论** —— 用户报告的
"1v1 和大乱斗里捡武器会导致游戏崩溃"目前**没有堆栈、没有复现步骤**，任何成因清单都只是猜。

## 0. 这份文档的边界

- **做**：设计一个能**确定性触发**局内拾取/丢弃全流程的探针；定判据；定拿到堆栈后的排查顺序；
  列出**待验证的高危点**（明确标注为假设，不是结论）。
- **不做**：诊断具体崩溃。那要在拿到堆栈之后，逐条走"最小复现 → 红 → 修 → 绿"。

## 1. 为什么现有探针盖不住

| 现有 | 它做什么 | 为什么盖不住这次的崩溃 |
|---|---|---|
| `tests/royale_c2_probe.tscn` | 真大厅 + 真 worker + 2 个真 `royale_game` 客户端跑一局；用"K 自杀 → 服务器复活瞬移"造一次外部事件验 rollback | 局内**从不主动捡/丢枪**。它压的是 C2 收敛，不是拾取链路 |
| `tests/royale_soak_probe.tscn` | N 个客户端 + 脚本机器人踩局内行为（追打/自杀/中途 ESC 离场） | 机器人**不捡枪**（`AiInputSource`/`soak_bot_input` 的 pickup/drop 钩子恒 false —— 那是我为了让它们别刷屏而特意返回 false 的） |
| `tests/pvp_match_smoke.sh` | 输入 → 模拟 → 快照 → 子弹广播 | 用的**不是** `pvp_game`，是个极简测试客户端；不发拾取位 |
| `tests/level0_weapon_scatter_probe.tscn` | 单机的拾取/丢弃全流程（含"丢下能再捡"） | **只跑单机**。单机没有服务器权威、没有事件下行、没有 C2 回滚 |

**结论：联机的拾取/丢弃链路，一条自动化覆盖都没有。** 崩溃"只有真机才会现形"是必然的。

## 2. 要覆盖的场景矩阵

第一阶段按**动作 × 模式 × 时机**铺满。每条都要能在探针里确定性触发。

### 2.1 动作（每条都要在 1v1 与 4 人大乱斗里各走一遍）

1. 走近 → **捡**（背包有空位）
2. 走近 → 捡 → **放不下**（容量/4 把上限）→ **替换手上那把** → 被换下的那把落地
3. 捡**被禁用闸门拒绝**的类型（应当原地不动、地面那件留着）
4. **丢**（长按满阈值）→ 落地
5. 丢完**立刻再捡**（自身冷却期内 → 应捡不到；冷却过后 → 应捡得到）
6. **两人同时抢同一把**（同 tick 各发一次 F）
7. 捡**刚被对手丢下**的那把
8. **复活**（除随机一把外全丢）后立刻捡
9. **换局**（清空重铺 + 背包重置）后立刻捡
10. 在**接缝附近**捡/丢（canonical 与渲染位置分离的那条路径）

### 2.2 时机（这些是"状态机半途"的经典出坑处）

- COUNTDOWN **冻结期**按 F/Q（输入源 `frozen`）
- **倒地中**按 F/Q
- **复活的那一帧**按 F/Q
- **换局 COUNTDOWN 开始的那一帧**按 F/Q
- **rollback 重放中**背包被权威改变（`restore_state` 频繁调用的窗口）
- 客户端**还没收到 `match_sync`** 就按 F

### 2.3 通道

- 本地玩家（客户端预测侧）
- 对手副本方向（服务器权威侧）
- AI 补位角色

## 3. 探针设计

### 3.1 骨架

新 `tests/pvp_weapon_stress_probe.tscn`（自当大厅/裁判 + 拉 headless 客户端），**照
`royale_c2_probe` 的手法**（它已经把"拉真大厅 + 拉真 worker + 等换场"这套跑通了）。

### 3.2 让机器人主动捡枪

`tests/soak_bot_input.gd` 已经是一个"脚本手柄"输入源（`extends PlayerInput`）。给它加：

```gdscript
# 脚本机器人的拾取/丢弃:由探针按剧本置位(默认 false,保持既有 soak 的安静)
var want_pickup := false
var want_drop := false

func _pickup_pressed_raw() -> bool:
    var v := want_pickup
    want_pickup = false      # 读一次即清 = 边沿
    return v

func _drop_pressed_raw() -> bool:
    var v := want_drop
    want_drop = false
    return v
```

★ **不许改成恒 true** —— 那会让 `royale_soak_probe` 的机器人无时无刻不在捡枪，
把那份压力测试的语义改掉。要捡枪就由探针显式置位。

### 3.3 让"走到枪旁边"可确定

客户端不知道服务器的枪在哪。两个办法，**优先第二个**：

1. 探针**先把枪摆在自己脚下再捡** —— 服务器侧加一个仅测试用的调试入口
   （`MatchGround.debug_teleport_ground_weapon_to(role)`），把场上某把枪挪到该玩家位置。
2. 或者客户端**直接读快照/事件**，往最近的一把枪走 —— 但要走位，慢且脆。

★ 调试入口要用 `OS.get_cmdline_user_args()` 的开关 gate 住（**开关必须写在 `--` 之后**，
见 CLAUDE.md），默认关闭对局外不可达。

### 3.4 抓堆栈（**这一步比造复现更容易漏**）

本仓已经吃过两次亏：

- **客户端子进程的 stdout 父进程看不到**（Windows `CreateProcess` 不继承句柄）→ spawn 时必须带 `--log-file`。
- **worker 子进程的 stdout 不随 `OS.create_process` 继承到管道** → worker 侧的崩溃/报错是**盲区**。
  大乱斗的 `RoyaleHost` 跑在 worker 里，**崩溃很可能就发生在那一侧而我们一个字都看不到**。
  → **本方案的第一条硬要求：worker 也必须 `--log-file`**（改 `worker_launcher`/`_spawn_*_worker`
  的命令行），否则排查无从谈起。

### 3.5 判据

```
PASS ⟺ 每个子进程退出码 0
      且 每份日志里没有 SCRIPT ERROR / Invalid / freed / Condition
      且 探针打印 PVP WEAPON STRESS: ALL-OK
```

★ 只判退出码不够：本仓反复验证过"中途脚本报错仍 exit 0 且不打 ALL-OK"。
★ Windows 下 bash `kill` 杀不死 headless Godot（会留僵尸占端口）→ 脚本收尾照
`pvp_match_smoke.sh` 用 `taskkill` 按 PID + `kill_port`。

### 3.6 分层

不要一次写一个巨型探针。按**能独立判红绿**分层：

| 层 | 内容 | 能不能单独判红绿 |
|---|---|---|
| L1 | 场景 1/4/5（捡、丢、丢后冷却）在 1v1 | 能 |
| L2 | 场景 2/3（替换、闸门拒绝） | 能 |
| L3 | 场景 6/7（抢、捡对手丢的） | 能（要两客户端协同） |
| L4 | 场景 8/9（复活、换局） | 能 |
| L5 | 场景 10 + 2.2 全部时机 | 能 |
| L6 | 4 人大乱斗把 L1–L5 重跑一遍 | 能 |

**先做 L1**。它能跑通，说明整条链路（客户端上行 → 服务器裁决 → 事件下行 → 客户端建/删节点）
是活的；后面几层才谈得上分辨"是哪一段炸的"。

## 4. 拿到堆栈之后的排查顺序

1. **先看堆栈落在哪个文件:行**，别按印象猜。
2. 归类。本仓反复出现的是这几族，按这个顺序排除：
   - **释放后再引用**（`queue_free` 之后仍被持有引用）—— `!= null` **挡不住**释放后的对象，
     必须 `is_instance_valid`。这几天已在本项目踩到三次。
   - **同帧 deferred 竞态** —— `call_deferred("add_child", ...)` 之后同帧再引用。
   - **权威与预测不一致** —— 客户端按自己的状态判、服务器按权威判。
   - **子进程/跨场景的生命周期**（换场窗口里的信号订阅）。
3. 每条崩溃都要有**最小复现**（一个人为置位就能触发）。做不到就先补探针，别改代码。
4. 修完在对应层里留一条**反向断言**（撤掉修复它必须变红），否则下次重构会静默复发。

## 5. 待验证的高危点（**假设，不是结论**）

下面每条都是"代码形状上像，但**没有证据**"。按这个顺序看，别当成已确诊：

1. **`capture_state`/`restore_state` 里的 `inv`（本次新加）** —— C2 下 `restore_state` 被频繁调用，
   而 `restore_state` 里 **`equip()` 会 `queue_free` 当前武器并 `call_deferred` 入树新枪**。
   若 `inv` 与 `wslot` 有任何一条路径不一致，接着的 `equip` 就会落到"没有就加"或空手；
   而刚被释放的那把仍可能被别处（`weapon_base.tick`、`player_replica` 的驱动、相机等）引用。
   **先查这里。**
2. **`MatchGround._remove_ground_weapon` 的释放时序** —— `queue_free` 之后，
   `_ground_nodes` / `_sync_ground_positions` / `_update_pickup_prompt` 在同一帧内是否还会摸到它。
3. **客户端 `_pickup_nodes` 在 `weapon_removed` 与 `match_sync` 竞争下的条目** ——
   开局那批走 `match_sync`、之后走事件；两者若重叠（同 inst 各来一次），会不会插入两次/删两次。
4. **`WeaponPickup.set_prompt_visible` 懒建 `PickupPrompt`** —— 父节点已 `queue_free` 时 `add_child`。
5. **AI 补位角色** —— `AiInputSource` 的两个钩子恒 false，但 `MatchHost._setup_ground_weapons`
   会给 AI 发枪、复活也会给它 `_drop_all_but_one`。AI 的 `weapons` 是否在所有时机都有效。

## 6. 另需先做的一件小事

**导出脚本的占用检查**：`tools/build_release.py` 在目标 exe 正被运行时，Godot 只会抛
"PCK 内嵌: 重命名临时文件失败"，看不出所以然，还会留一个 40+MB 的 `.tmp`。
加一句前置检查（目标 exe 被占用 → 直接报"请先关掉正在运行的游戏"）。**与本次崩溃无关，
但已经连撞两次。**
