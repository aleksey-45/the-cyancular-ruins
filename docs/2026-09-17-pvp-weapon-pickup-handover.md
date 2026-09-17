# 交接：局内捡枪/丢枪（2026-09-16 ~ 09-17）

**一句话**：联机拾取链路上**两个真 bug** 已定位、修复、提交并加了守卫；联机拾取此前
**零自动化覆盖**，现在有三层探针且**能在导出 exe 上跑**；但用户报的**硬崩溃没有复现**。

---

## 1. 交付物（已提交，工作区干净）

```
ab0aa79 fix(c2): 预测被证实时也回灌权威背包(拾取/丢弃在客户端不再静默失效)
19c858e feat(ui): 左下角容量格子跟随武器面板的实际顶边
dbec56f test: 局内捡枪/丢枪探针(服务器侧 / 客户端侧 / 真链路)+ 仅测试用的喂枪入口
```

配套文档（也是设计/根因记录）：
`docs/superpowers/plans/2026-09-16-pvp-weapon-pickup-inventory-sync.md`
—— 根因、实测证据、修法取舍、三个 TDD 任务。**先读它**，本文件不重复那些推导。

姊妹文档：`docs/superpowers/plans/2026-09-16-pvp-weapon-crash-probe-plan.md`
（更早、由另一条线写的**复现框架**方案，§2 的场景矩阵 L1–L6 **大部分仍未跑**）。

---

## 2. 修了什么（都有红→绿守卫）

### 2.1 捡枪在客户端静默失效（本轮的主发现）

`core/net/prediction_rollback.gd` 的 `_handle_ack` 在"预测被证实"那一支**直接 return**，
不应用权威态；而 `_close_enough` 是**显式白名单**（只比 `down/hp/pos/vel`），
`inv`/`wslot` **刻意不在内**（防每帧判分歧 → 无限回滚，这条纪律本身是对的）。

问题在于：`restore_state` 是 `restore_inventory` 的**唯一**调用者
（`grep -rn "restore_inventory\|restore_state(" --include=*.gd .` 可验），于是

> **只要本地预测与权威逐位一致，客户端就永远不应用权威背包。**
> 而 C2 的常态恰恰是"逐位一致"。

实测（`ground_net_probe`，一局 90s）：`rollback_count()==0`、客户端背包恒空，
同一时刻服务器侧丢弃/拾取**全都成功**。表现就是"枪从地上没了、手上也没多、还开不了火"，
且**一条报错都没有**。只在联机模式出现，因为单机没有快照下行 + C2 回滚。

**修法**：在"预测被证实"那一支补一次**只同步、不重放**的软回灌（`Player.sync_soft_state`）。
位置/速度是预测出来的，拿权威覆盖它们才是橡皮筋；背包不是。
带结构指纹守卫，**只比 `(type, inst)`** —— 比 `mag` 是连续量，会让守卫每帧失效、
每帧重建 HUD 武器框。

### 2.2 幽灵枪

`weapon_component.restore_inventory` 的"清空手持"分支只清索引、**不释放武器实例**，
而 `tick()`/`fire()` 只判 `_player_ok()`（player 非空且没倒地）、**不看索引** ——
于是手上留一把索引 `-1` 却照常开火的枪。早先这条路径要等一次回滚才走得到，
软回灌之后是常路（权威说空手 = 你把自己最后一把丢了）。

---

## 3. 探针怎么跑

### 3.1 三条线

| 探针 | 覆盖 | 判据 |
|---|---|---|
| `tests/ground_action_probe.tscn` | 服务器权威侧（无网络）：捡 / 替换 / 丢 / 自身冷却 / 40 轮连打 / 复活掉枪 | `GROUND ACTION PROBE: ALL-OK` |
| `tests/ground_client_probe.tscn` | 客户端侧（无网络）：`weapon_removed` 删节点、权威背包变化后 restore、幽灵枪 | `GROUND CLIENT PROBE: ALL-OK` |
| `tests/ground_net_probe.tscn` | **真链路**：真大厅 + 真 worker + N 个真 `royale_game` 客户端 | `PROBE: ALL-OK` |

```bash
G="D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe"
"$G" --headless --path . --quit-after 3600 res://tests/ground_action_probe.tscn
"$G" --headless --path . --quit-after 3600 res://tests/ground_client_probe.tscn
"$G" --headless --path . --quit-after 10800 res://tests/ground_net_probe.tscn -- --test-ground-teleport   # 跑前确认 7777 空闲
```

### 3.2 `--test-ground-teleport`（仅测试用，生产不可达）

`ground_net_probe` **必须**带这个开关，否则机器人得自己走位 —— 实测那条路走不通：
只会"水平走 + 卡住跳"的机器人在**每进程随机选一份 `.cyrm`** 的地图上会永久卡死
（`走到目标超时` 的距离越拉越大，直到全场武器被拉黑）。

打开后服务器每帧保证"每个站着的玩家脚下 64px 内有一把**捡得动**的枪"
（`MatchGround._debug_keep_weapon_within_reach`）。Gate 链：
`static var test_ground_teleport := false` → `server_main.gd` 解析 worker 的
`--test-ground-teleport` → `worker_launcher.spawn_royale_worker` **只在大厅自己也带了**
该开关时才转发。真实大厅/真实对局里恒为 false。

★ 开关**必须写在 `--` 之后**（读的是 `OS.get_cmdline_user_args()`；写在前面会被 Godot
丢掉、静默失效 —— 与 `--worker` 同一个坑）。

★ 代价：客户端不知道枪被挪过，那件武器的**视觉位置**在客户端是错的。别拿这个模式的截图
验收画面。

### 3.3 在**导出 exe** 上跑（本轮新建的通道）

导出用的裁剪模板编译时带了 `disable_path_overrides=yes`，所以
`<exe> res://x.tscn` 会被引擎**当场拒绝**：

```
ERROR: Scene path was specified on the command line, but this Godot binary was compiled
       without support for path overrides. Aborting.
```

绕法：借主菜单那条既有通道（`tests/menu_autotest.gd` 新增的 `--autotest-ground/<场景名>`，
读 `OS.get_cmdline_user_args()`，且 `tests/` 已在 `export_filter="all_resources"` 里）。

导出形态下**没有裁判进程**（`ground_net_probe.gd` 里的 orchestrator 分支），所以形状变了
—— 服务端 exe 自己当大厅，客户端各自独立拉起：

```bash
./_crashtest/CyancularServer.exe --log-file _crashtest/server.log -- --test-ground-teleport &
./_crashtest/CyancularClient.exe --log-file _crashtest/c1.log -- --autotest-ground/ground_net_probe --role=c1 &
./_crashtest/CyancularClient.exe --log-file _crashtest/c2.log -- --autotest-ground/ground_net_probe --role=c2 &
```

为此补了三处**只有导出形态才暴露**的洞（都改在 `ground_net_watcher.gd`）：

1. **房号交接**：`ground_net_probe_go.txt` 是裁判写的，导出形态没有裁判 → c2 改从大厅
   自己拉到的房间列表里挑第一个公开房加入（读 lobby 渲染出来的按钮文本）。
2. **那份列表要主动催刷新**：大厅只在 `_ready` 和玩家点刷新时拉，而 c1 建房在那之后 ——
   不催就守着空列表等到超时（实测卡了一整轮）。
3. **没人按「开始游戏」** → 房主 c1 自己按（`btn.pressed.emit()`，走游戏自己的路径）。

★ 客户端 exe 是 GUI 子系统，**stdout 回不到终端**，`--log-file` 不能省。
★ 服务端 exe 同样是 GUI 子系统且**日志是缓冲的**（`--log-file` 会攒着不 flush），
所以**不能靠 tail 服务端日志做实时编排**。要那个能力得先跑 `tools/make_server_console.py`。

---

## 4. 已验证 / 未验证

**验证过的**（2026-09-17）：

```
GROUND ACTION PROBE: ALL-OK
GROUND CLIENT PROBE: ALL-OK
SMOKE_TWIN OK: 640 ticks, max pos dev 0.1035 px, 0 字段发散
SMOKE_RECONCILE OK: 640tick 内 rollback×1, ..., 事件后已收敛
```

导出 exe（`custom_build` + Vulkan，真开窗）：

- **2 人**：`c1 OK 丢=8 捡=10 轮=4 背包=2` / `c2` 同 —— `PROBE: ALL-OK`
- **3 人**：`c1 OK 丢=12 捡=14 轮=4 背包=1` / `c2 OK ... 背包=2` / `c3 OK ... 背包=2`
- 两次都**没有崩溃**，进程 exit 0

**没验证的**：

- **崩溃没复现。** 见 §5。
- 那份 crash-probe-plan §2 的场景矩阵（替换、闸门拒绝、抢枪、接缝附近、
  冻结期/倒地中/换局那一帧……）**绝大部分仍未跑**。本轮只交付了 L1（捡/丢/冷却）。
- `ground_action_probe` / `ground_client_probe` 是在改动**之后**补跑的，不是 TDD 的红→绿；
  真正红→绿的是 `pvp_reconcile_smoke`（新事件）与 `ground_client_probe` 的幽灵枪那条。

---

## 5. 崩溃：仍未定位（**这是最要紧的未完项**）

用户原话：「1v1 和大乱斗里捡武器会导致游戏崩溃」。**无堆栈、无复现步骤。**

现场证据（`user://logs/godot2026-09-16T22.18.41.log`，进程是 **`custom_build` = 导出 exe**）：

```
进入大乱斗:角色 3 出生点 (140, 10)
[CollisionBuilder] WallCollision shapes: 4734
NetBus: 玩家断开 peer=537689426
ERROR: Trying to call an RPC while no multiplayer peer is active.
   at: rpcp (modules/multiplayer/scene_rpc_interface.cpp:475)
   ← 日志到此为止
```

**同一条 ERROR 在探针里复现到了**（掉线后 `pvp_match_client.gd:113` 继续
`NetBus.rpc_id(1, "send_input", pkt)`），但**进程活着继续跑** —— 所以它**不必然**是崩溃原因。

已知的差异（本轮导出实机都**没**覆盖到的）：

1. 用户是**从主菜单点「大乱斗」**正常进去的；探针走的是 `--autotest-ground/...` **直切场景**。
2. 地图是**每进程随机选一份 `.cyrm`**（`MazeGenerator.map_file_path()`），三次跑到的图未必是同一张。
3. 崩溃是"有些时候"的 —— 三次没崩不等于没有，只等于"这个场景 + 这几张图不崩"。

**下一步建议（按性价比排）**：

- ★ **问用户要更多上下文**比再跑十轮值钱：当时是刚开局还是打到一半？几个人？有没有同时
  按什么键？是闪退到桌面还是卡死？有没有"对手已离开"之类的提示？
- 把探针改成**走主菜单那条路**（`--autotest-royale` 已有雏形，`menu_autotest` 里按
  「大乱斗」按钮 → 大厅 → 建房/加入），补上差异 1。
- 换图多跑（补差异 2）：`ground_net_probe` 多跑几轮，或临时钉一张图。
- 本仓有先例：**"只在导出 exe 上现形"** 的那一类（CLAUDE.md 记着 RID 泄漏 →
  渲染器析构段错误）。**量的必须是发布产物**，编辑器二进制的绿不算数。

---

## 6. 本轮踩到并值得固化的坑

- **7777 僵尸**：导出服务端被 `taskkill //F //PID $SRV` 杀掉后，端口仍可能被另一个 pid 占着
  —— 收尾要**按端口找 pid 再杀**（`netstat -ano | grep :7777` → `taskkill //F //PID`）。
  本轮杀漏过一次，下一轮直接 `WorkerLauncher` 拉起 worker 会撞端口。
- **`_crashtest/` 不入库**：`.gitignore` 已覆盖（`git status` 里不出现）。
- **`test_ground_teleport` 的喂枪位置要反着减 `visual_offset`**：拾取判定比的是**视觉中心**
  对玩家位置的距离，直接把 canonical 设成玩家位置会让可见的枪偏出约 60px，正好卡在 64px
  半径边缘 —— 时灵时不灵且不报错。
- **别用 `get_node_or_null("PickupPrompt")` 找脚本建的节点**：`Script.new()` 建出来的节点
  **不叫** 类名，按名字找必然 null（探针假红过一次）。
- **探针里的事件计数基线必须按"相"取，不能按"帧"取**：RPC 事件在 `multiplayer.poll()` 里到达
  （早于 `_physics_process`），同一帧读两次不会变 —— 按帧比会**永远不成立**（探针静默空转）。

---

## 7. 环境

- 分支 `cleanup/stage1-bugs-and-hygiene`，工作区干净，4 个 commit（含更早那条 docs）。
- `_crashtest/` 下是**本轮临时导出**的两个 exe（客户端 + 服务端，各约 43MB），
  复现 §3.3 用；不需要了可以直接删。
- 收尾时已确认：7777 已释放、无残留 `Cyancular*` 进程。
