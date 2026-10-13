# 联机进程生命周期验证

环境：Windows x64、Godot 4.7.1、官方 EasyTier 2.7.0。验证联机子进程所有权、CLI 等待、Job 终止和 Windows 发布。

## 设计与测试边界

[NetSession](../../core/net/net_session.gd) 持有一个启用 kill-on-close 的 Windows Job。[原生扩展](../../native/process_group/process_group.cpp) 在创建子进程时原子加入 Job，父客户端独占不继承的句柄。正常关闭会话显式关闭句柄，客户端被强制结束时由系统关闭句柄；两者都由 Job 终止服务端、EasyTier、CLI 及后代进程。组件重启可以单独停止一个进程。Job 终止不执行子进程的退出回调。

[生命周期测试](../../tests/network/run_process_lifecycle.py) 通过 Windows 进程句柄直接检查进程退出，覆盖正常 quit、窗口关闭、离开后重新建房、场景切换、强制终止和启动期间终止。实际启动的进程包含服务端、官方 EasyTier、等待中的 CLI 夹具，以及通过 Godot 原生接口创建的后代 EasyTier。独立 EasyTier 在每项测试后必须仍运行。夹具还验证 Unicode、空参数、引号、尾部反斜杠、72,000 字节 UTF-8 输出和退出码 7。

生命周期矩阵使用编辑器加载完整项目，Windows 导出程序执行独立目录启动与实际服务端对局。

客户端与服务端日志追加保存，EasyTier 临时配置按 RPC 端口命名；进程所有权由 Job 句柄管理。

## 执行入口

```powershell
python tests/network/run_process_lifecycle.py --godot $env:GODOT
python tools/run_regression.py --godot $env:GODOT --scenes --kind unit --jobs 2
python tools/run_regression.py --godot $env:GODOT --scenes --kind network
python tests/network/run_easytier.py --godot $env:GODOT
python tools/build_release.py
```

精英掉落探针退出故障按失败计入，见 [已知缺陷](registered-debt.md)。

## 验证结果（2026-10-13）

| 项目 | 结果 |
|---|---|
| 进程生命周期 | 连续两轮 6/6；所有子进程和后代退出，独立 EasyTier 保持运行 |
| 网络探针 | 7/7 |
| 单元与场景回归 | 60/61；仅已有精英掉落探针访问冲突，退出码 3221225477 |
| 视觉回归 | 8/8 |
| 全脚本加载 | 228/228 |
| 官方 EasyTier | UDP 直连与强制本机中继均通过；256 KiB 基线及重连正常 |
| 真实双人对战 | 含断线重连、750 ms 积压、250 ms 断流，通过 |
| Windows 发布 | 完整构建、导出、独立目录启动与归档通过；实际包内服务端完成两局、重连及原房间返回 |
| 命名、路径、UID、shell 语法 | 通过 |

发布目录包含客户端、服务端、原生 DLL、THIRD_PARTY_NOTICES.txt 和 EasyTier 联机组件。原始结果与 DLL SHA-256 见 [结果 JSON](process_lifecycle_results.json)。
