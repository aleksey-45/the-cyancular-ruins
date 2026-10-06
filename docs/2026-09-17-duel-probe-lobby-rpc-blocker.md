# 1v1 模式测试阻塞问题分析：大厅 RPC 通信异常排查 (2026-09-17)

> **问题概要**：在为地面网络探针（`ground_net_probe`）扩展 1v1 对战覆盖时，大乱斗模式（Royale）能够顺利完成全链路端到端通信，而 1v1 对决模式（Duel）下客户端发往服务端的大厅 RPC 请求无法被正常接收与处理。经排查，该现象在相同客户端进程环境与服务端实例下，仅通过切换大厅场景即可稳定复现。本文记录已量测的数据特征、已排除的假设及定位边界。

---

## 一、 现状与参数化改造

测试套件已完成如下底层重构（支持独立复用）：

- **参数化支持**：`tests/ground_net_probe.gd` 与 `tests/ground_net_watcher.gd` 支持 `--mode=royale|duel` 与 `--scene=<剧本名>` 配置参数（默认保持 `royale` 与 `L1`，兼容既有测试指令与断言规则）。
- **模式映射单一来源**：`ground_net_watcher.MODES` 配置表统一管理模式差异（包含大厅场景、加入方式、对局场景标识及启动动作配置）。
- **统一场景切换机制**：客户端大厅统一通过标准场景切换栈（`change_scene_to_file`）实例化，观察者挂载于场景树根节点（`root`），通过 `get_tree().current_scene` 动态识别当前大厅，与运行时导出版本行为严格对齐。
- **日志轮转配置优化**：`project.godot` 中将 `log_file_logging/max_log_files` 由 5 调整为 64，避免高频测试导致异常现场日志被过早覆盖。

---

## 二、 异常表现（1v1 模式）

在 1v1 模式下运行探针时，控制台抛出如下校验异常：

```text
PROBE[c1]: 大厅已连,建房          ← 客户端 c1 调用 create_room()
ERROR: rpc node checksum failed ... /root/NetBus   (process_confirm_path)
ERROR: rpc node checksum failed ... NetBus          (process_simplify_path)
PROBE[c1]: 等换场(...)            ← 房间创建请求未被处理，客户端持续挂起
PROBE[c2]: 等大厅连接(_connected=false) → 认出大厅 → 反复刷新房间列表(找不到房)
```

- **服务端跟踪表现**：在服务端入口及处理函数（`LobbyRooms.on_lobby_name` / `create_room` / `join_room` / `on_list_rooms`）中注入跟踪日志，整个测试生命周期内未收到任何来自 `NetBus` 的有效 RPC 调用。
- **对照组表现**：大乱斗模式下相同逻辑链路中，两端客户端发出的 `lobby_name` 均能正常到达服务端并触发响应。

---

## 三、 已排查与证伪的假设

| 假设方向 | 排查方法与实测结果 | 结论 |
|---|---|---|
| **内嵌大厅服务异常** | 切换为独立专用进程启动 `server_main.tscn` 进行测试，现象依然完全一致 | 排除宿主进程模式差异 |
| **运行时环境差异** | 两种模式均在引擎无头（headless）环境下执行，运行上下文完全相同 | 排除运行环境差异 |
| **两端方法签名表不一致** | 通过 `NetBus.get_method_list()` 比对：客户端与服务端方法总数均为 230，方法哈希值严格一致（均为 `3873843019`） | 排除全局方法声明差异 |
| **未缓存节点导致的 RPC 丢弃** | 检索 Godot 源码 `scene_rpc_interface.cpp`：未缓存路径依然会通过标准路径序列化发送，不应直接中断通信 | 排除节点路径缓存失败 |
| **客户端中断发送** | 检索客户端引擎底层日志，未发现来自 `_send_rpc` 内部断言与守卫的拦截报错 | 排除客户端主动拦截 |
| **初始化加载顺序引发的依赖缺失** | 确认 `WeaponIcons` 等静态构建仅在主动加载对应面板时触发，大厅场景 `_ready` 期间未产生副作用冲突 | 排除资源懒加载时序冲突 |

---

## 四、 确立的隔离边界

通过受控变量对比测试确认：

| 客户端进程环境 | 服务端架构 | 大厅场景配置 | 测试结果 |
|---|---|---|---|
| `--mode=royale` | 内嵌模式 | `royale_lobby.tscn` | 正常接收 2 条 `lobby_name`，测试全部通过 |
| `--mode=duel` | 内嵌模式 | `matchmaking.tscn` | 服务端未接收到任何大厅 RPC |
| `--mode=duel` | 独立进程模式 | `matchmaking.tscn` | 服务端未接收到任何大厅 RPC |
| `--mode=duel` | 内嵌模式 | 临时替换为 `royale_lobby.tscn` | **无任何校验报错，通信恢复正常** |

**核心推论**：客户端进程实例、网络底层与服务端完全一致时，**仅切换大厅场景界面即导致通信状态反转**。

---

## 五、 底层机制分析与后续排查建议

### 1. 引擎底层 RPC 校验链追踪
- **发送阶段**：调用 `rpcp()` 获取配置索引 `rpc_id = configs[name]`，通过 `_send_rpc()` 发送简化路径包与 RPC 调用。
- **接收阶段**：底层 `process_simplify_path()` 计算接收端节点的 `get_rpc_md5(node)` 并与数据包中的哈希比对。若哈希不一致，引擎仅输出警告日志并继续确认逻辑；随后进入 `_process_rpc()`，按发送方数字索引检索本地配置表，若 `!cache_config.configs.has(id)` 则直接静默退出。
- **当前瓶颈点**：1v1 场景加载后，虽然全局反射方法表一致，但特定场景树状态可能影响了节点上 `@rpc` 配置子集的注册或哈希计算，导致接收端查表失败产生静默拦截。

### 2. 建议排查步骤
1. **精确比对 RPC 配置子集**：通过 `ClassDB` 动态导出两端针对 `NetBus` 节点的 `@rpc` 注册属性表，并直接计算比对 MD5 值。
2. **启用引擎详细输出**：携带 `--verbose` 参数执行 1v1 测试，观察引擎网络层是否在底层记录了静默丢弃详情。
3. **时序与连接解耦（规避方案）**：参考 `tests/pvp_smoke_client.gd`，在测试观察者层显式调用 `NetBus.start_client(...)` 建立就绪连接，解耦大厅页面的懒加载握手时序。

---

## 六、 复现执行指令

```bash
GODOT_BIN="D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe"

# 大乱斗模式基准测试（应通过，执行前请确保 7777 端口空闲）
"$GODOT_BIN" --headless --path . --quit-after 10800 res://tests/ground_net_probe.tscn \
     -- --mode=royale --scene=L1 --test-ground-teleport

# 1v1 模式测试（复现当前阻塞现象）
"$GODOT_BIN" --headless --path . --quit-after 10800 res://tests/ground_net_probe.tscn \
     -- --mode=duel --scene=L1 --test-ground-teleport
```
