# 测试

默认检查运行成本低、能挡住实际回归的核心行为。关联修改按需运行额外行为测试；涉及网络时运行一次真实对局，不重复扫描人数与网络参数组合。删减理由与覆盖限制见[测试精简记录](test_cleanup_20261028.md)。

```powershell
python tools/run_regression.py --godot $env:GODOT --scenes
python tools/run_regression.py --godot $env:GODOT --scenes --all
python tools/run_regression.py --godot $env:GODOT --scenes --only terrain_history_probe
python tools/run_regression.py --godot $env:GODOT --scenes --kind network
python tools/check_naming.py
```

默认 9 项覆盖脚本加载、资源路径、输入、地图格式、预测复用、本地预测范围、事件影响、原生地形与单人地形历史。`--all` 扩展到保留的规则、背包、碰撞、爆炸、回溯和日志行为测试。`perf_probe` 是手动诊断，不在自动批次内。

测试通过必须满足：退出码为 0，输出明确成功标记，且没有脚本错误。只有日志出现 OK 而进程崩溃不算通过；脚本执行提前中断也不能视为成功。

测试优先通过输入、碰撞、状态和网络消息观察结果。新增测试需能指出它会挡住的真实缺陷；避免对源码拼写、文案、可变参数、引擎自带行为和同一事实重复断言。不为薄适配方法逐一建立测试。

对局切换按结算界面可见、返回同一房间大厅、旧世界回收完成的条件等待，各限时 2 秒，超时报告具体阶段并退出。[`process_frame`](https://docs.godotengine.org/en/stable/classes/class_scenetree.html#class-scenetree-signal-process-frame) 在节点 `_process()` 之前发出，不能用固定一两帧代替这些完成条件。

## 真实对局

```powershell
python tests/network/run_matches.py --godot $env:GODOT --count 8 --mode royale --battle-seconds 90 --tunnel relay --relays udp://et.lctn.cc.cd:2059 udp://183.230.36.171:11010 --pin-client-relays --frame-trace
```

中继模式禁用 P2P；指定两条中继并绑定客户端后，客户端分组固定各自的中继，主机连接两条。地址与服务可用性以当次日志为准。用 `--help` 查看延迟、丢包、重连和卡顿注入选项；只在排查相关问题时使用。

测试占用动态本地端口，子进程按本轮记录的 PID 关闭；不能按进程名全局强杀。项目脚本和工具共用入口，避免另建一套接线。

## 性能记录

开启 `--frame-trace` 才采集逐帧细节。`interval_us` 是两个 process_frame 信号之间的墙钟间隔，包含等待和调度；不能直接解释成玩家看到的画面停顿或纯计算耗时。span 可以嵌套，不能相加。

`terrain_collision_commit` 只计最终提交调用。角色和弹丸可能提前提交碰撞，所以原生层累计实际处理的 `terrain_collision_us` 与 `terrain_chunks`，在明确边界取出，避免漏记。时间单位为微秒；显示毫秒只除以 1000 一次。
