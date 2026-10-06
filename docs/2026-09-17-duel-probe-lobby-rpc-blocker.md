# 1v1 探针卡点：大厅 RPC 全部到不了服务器（2026-09-17）

**一句话**：给 L1 探针加 1v1 覆盖时，**大乱斗侧一次跑绿、1v1 侧一条大厅 RPC 都到不了服务器**。
症状已夹到最小（同一个客户端进程、同一个大厅，只换大厅页就复现/消失），但**成因未定**。
本文只记录**已证实的读数**与**已排除的假设**，不含结论。

---

## 1. 已交付（可独立保留）

`tests/ground_net_probe.gd` + `tests/ground_net_watcher.gd` 的模式/剧本参数化：

- `--mode=royale|duel`、`--scene=<剧本名>`；默认 `royale` / `L1` ⇒ **现有命令与判据逐字不变**。
- `ground_net_watcher.MODES` 表是**唯一的**模式差异来源；差异只有 4 处（大厅场景 / 加入方式 /
  对局场景名 / 要不要按「开始游戏」）。
- 客户端大厅改为**走游戏自己的换场景栈**（`change_scene_to_file`），观察者挂 `root` 上、
  用 `get_tree().current_scene` 认大厅 —— 与导出形态（无裁判进程）同一条路。
- `project.godot` 的 `log_file_logging/max_log_files` 5 → 64（原先会把崩溃现场轮转吃掉）。

**回归**：`--mode=royale --scene=L1 --test-ground-teleport` 仍然 `PROBE: ALL-OK`
（两端 `丢=8 捡=10 轮=4 背包=2`，且服务端确认收到两条 `lobby_name`）。

---

## 2. 症状（duel）

```
PROBE[c1]: 大厅已连,建房          ← c1 调 create_room
ERROR: rpc node checksum failed ... /root/NetBus   (process_confirm_path)
ERROR: rpc node checksum failed ... NetBus          (process_simplify_path)
PROBE[c1]: 等换场(...)            ← 然后永远等下去(房间没建出来)
PROBE[c2]: 等大厅连接(_connected=false) → 认出大厅 → 反复刷新房间列表(找不到房)
```

服务端插桩（`LobbyRooms.on_lobby_name` / `create_room` / `join_room` / `on_list_rooms`）
在整轮里**一条都没打印** —— **没有任何 NetBus RPC 到达服务器**。

而**大乱斗模式下同一条 `lobby_name` 会到达两次**（两端各一次）。

---

## 3. 已排除的假设（都做过测量）

| 假设 | 怎么否掉的 |
|---|---|
| 嵌入式大厅（探针进程里跑 `RoomManager`）有问题 | 换成真 `server_main.tscn` 独立进程，**照样失败** |
| 导出/编辑器差异 | 两组都在编辑器 headless 下跑 |
| 客户端方法表与服务端不一致 | `NetBus.get_method_list()`：客户端与服务端**都是 230 个方法、hash 都是 `3873843019`** |
| RPC 被 `_send_rpc` 的节点未缓存分支丢掉 | 读引擎源码 `scene_rpc_interface.cpp:305`：未缓存时**照样发送**（只是不压缩节点 id） |
| 客户端主动放弃了发送 | 客户端引擎日志**没有** `_send_rpc` 的任何守卫报错 |
| 是「主菜单先加载武器子系统」的生产顺序 | `main_menu` 的 `WeaponIcons.silhouette` 在 `_build_sp_panel()` 里，**只在点「单人模式」时才建**，主菜单 `_ready` 不碰它 |
| `_add_weapon_grid` 是触发者 | **曾一度以为二分到了，但下一轮同样的命令没有复现 ⇒ 是时序噪声，结论已撤回** |

## 4. 夹到的边界（这条是稳的）

| 客户端（同一探针进程） | 大厅 | 结果 |
|---|---|---|
| `--mode=royale` | 嵌入式 | ✅ 服务器收到 2 条 `lobby_name`，整局 ALL-OK |
| `--mode=duel` | 嵌入式 | ❌ 服务器收到 **0** 条 |
| `--mode=duel` | 真 `server_main.tscn` | ❌ 同样 |
| `--mode=duel` + 临时把 `MODES["duel"]["lobby_scene"]` 换成 `royale_lobby.tscn` | 嵌入式 | ✅ **报错 0 行** |

⇒ **客户端进程相同、服务器相同，只换大厅场景页就翻转。**

## 5. 仍未解释的一处矛盾（下一个人的入口）

引擎侧看清了链路：

- 发送：`rpcp()` 用自己的表取 `rpc_id = configs[name]` → `_send_rpc()` 发 SIMPLIFY + RPC。
- 接收：`process_simplify_path()` 用**自己**的 `get_rpc_md5(node)` 比对包里的 md5（不一致只**打印**，
  仍然登记节点并回 CONFIRM）→ `_process_rpc()` 按**发送方的数字 id** 在自己表里查，
  `ERR_FAIL_COND(!cache_config.configs.has(id))` **静默 return**。

duel 下：SIMPLIFY 到了（所以有校验和报错）、RPC 包也发了（无守卫报错），
但处理器没执行 ⇒ 看形状是**卡在 `_process_rpc` 那句静默早退**（发送方 id 在接收方表里查不到）。

**矛盾在于**：`get_rpc_md5` 的输入是**节点 RPC 配置表**（节点级 + 脚本级），
而我只比对了 `get_method_list()`（**全部** 230 个方法），**不是 RPC 子集** ——
所以「方法表一致」并不能推出「RPC 配置表一致」，我那条推断是**不成立的**。
真正要比的是 `@rpc` 子集，而它在脚本里是静态的、GDScript 也没暴露读口。

**下一个可做的测量**（按性价比排）：
1. 给 `net_bus.gd` 临时加一条 `@rpc` 回读方法（或在 `server_main`/探头里调
   `multiplayer.get_rpc_md5`）—— 引擎没把 `get_rpc_md5` 绑给脚本，但**可以自己用
   `ClassDB` 反射拿到 `@rpc` 名单**，两端各算一次 md5 直接比。
2. 用 `--verbose` 跑一次 duel，看引擎有没有把 RPC 派发失败打出来（现在被静默）。
3. 对比 `matchmaking` 与 `royale_lobby` 两条路径里**第一次 NetBus RPC 发生的时刻**
   （`_push_lobby_name` 都在 `_on_lobby_connected` 里，但两页 `_ready` 的开销差很多）。

## 6. 绕过方案（不依赖成因，未验证）

`tests/pvp_smoke_client.gd` 是**唯一跑通过的 1v1 客户端**，它的做法不同：
**在 `_ready` 里显式 `NetBus.start_client(...)`，不依赖大厅页的懒连接**。
把探针客户端改成同款（观察者自己连、连上再驱动大厅页），可以绕开大厅页那条时序。

---

## 7. 跑法

```bash
G="D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe"
# 大乱斗 L1(应 ALL-OK;跑前确认 7777 空闲)
"$G" --headless --path . --quit-after 10800 res://tests/ground_net_probe.tscn \
     -- --mode=royale --scene=L1 --test-ground-teleport
# 1v1 L1(当前必然失败,见上)
"$G" --headless --path . --quit-after 10800 res://tests/ground_net_probe.tscn \
     -- --mode=duel --scene=L1 --test-ground-teleport
```
