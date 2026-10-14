# 联机进程生命周期验证记录

测试环境基于 64 位 Windows 10、Godot 4.7.1 与官方 EasyTier v2.7.0。重点验证联机子进程生命周期管理、Windows Job 作业对象资源回收机制以及发布包独立运行稳定性。

---

## 一、 架构机制与验证边界

- **Windows Job 作业对象机制**：[NetSession](../../core/net/net_session.gd) 持有一个配置了 `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` 的 Windows 作业对象。[原生扩展](../../native/process_group/process_group.cpp) 在创建子进程时原子性地将其加入该作业对象中，父进程客户端独占持有该句柄（禁止句柄继承）。
- **生命周期安全回收**：当客户端正常离开对局时，显式关闭该句柄；若客户端被任务管理器强杀或意外崩溃，Windows 操作系统会自动回收作业对象句柄。在这两种情况下，操作系统均会自动强制终止所属的专用服务端、EasyTier 核心及 CLI 工具等全部后台子进程。
- **生命周期自动化测试**：[生命周期测试](../../tests/network/run_process_lifecycle.py) 通过 Windows 进程句柄直接检测子进程的存活状态，覆盖游戏正常退出、关闭窗口、离开房间后重新创建、场景切换以及主进程被强制结束等多种边界情况。同时验证了命令行包含 Unicode 字符、空参数、引号转义、反斜杠及大体积 UTF-8 输出等兼容性测试。

---

## 二、 自动化测试命令入口

```powershell
python tests/network/run_process_lifecycle.py --godot $env:GODOT
python tools/run_regression.py --godot $env:GODOT --scenes --kind unit --jobs 2
python tools/run_regression.py --godot $env:GODOT --scenes --kind network
python tests/network/run_easytier.py --godot $env:GODOT
python tools/build_release.py
```

---

## 三、 验证结果汇总

| 验证项目 | 测试结果 | 说明 |
|---|---|---|
| **子进程生命周期回收** | 连续两轮 6/6 全部通过 | 主客户端退出或终止后，所属所有后台子进程均被操作系统安全终止，未残留孤儿进程；外部独立的 EasyTier 进程不受影响正常运行 |
| **网络协议与探针** | 7/7 全部通过 | 协议往返、时序调度与权威世界模拟正常 |
| **单元与场景回归** | 60/61 通过 | 仅已登记的精英掉落探针在退出时存在底层访问冲突异常（详见 [已知问题](registered-debt.md)） |
| **视觉效果回归** | 8/8 全部通过 | 界面渲染与图标对比完全一致 |
| **全脚本语法与加载** | 228/228 全部通过 | 语法解析无报错，类名与 UID 映射正常 |
| **官方 EasyTier 兼容性** | 验证通过 | UDP 直连与强制本机中继均通过测试；256 KiB 可靠基线传输与断线重连正常 |
| **网络高压真实对局** | 验证通过 | 包含双向丢包、750ms 突发积压与 250ms 完全断流，客户端顺利恢复同步并完成对局 |
| **Windows 发布包独立运行** | 验证通过 | 发布构建、独立目录解压启动、包内服务端实测两回合对战、Token 重连与无缝返回大厅全流程正常 |
| **工程命名与路径规范** | 全部通过 | 目录小写、文件名 snake_case、文档引用路径有效性检查全部通过 |

发布包命名为 `The-Cyancular-Ruins.zip`，解压后目录为 `The-Cyancular-Ruins-<时间戳>/`。实测原始数据及 DLL SHA-256 记录见 [结果数据文件](process_lifecycle_results.json)。

## 四、 macOS 验证入口

macOS 采用[生命期管道与进程组](../../native/process_group/process_group_macos.cpp)管理会话子进程。测试使用同一 Godot 生命周期探针，在正常 quit、窗口关闭、会话重建、场景切换、SIGKILL 以及启动期间 SIGKILL 后，逐个检查本次记录的 PID 已退出，并确认独立 EasyTier 仍运行。嵌套 Godot 通过 NetSession 创建自己的 EasyTier 会话。

```bash
python tests/network/run_macos.py --godot "$GODOT" --archive builds/macos/The-Cyancular-Ruins.zip
```

该命令同时校验包内 arm64 与 x86_64 架构、签名、权限、注册表、导出服务端、网络探针、真实对局及 EasyTier UDP 直连和中继。CI 在两种 CPU 的运行器上执行，结果以工作流与测试日志为准；本节列出验证流程。
