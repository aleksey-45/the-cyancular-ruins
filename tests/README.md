# tests/ — 冒烟 / 诊断(无测试框架)

没有单测框架。运行命令见根 `CLAUDE.md`「常用命令」(headless + `-s`),成功以打印 `SMOKE OK` / `... OK` 且退出 0 为准。

文件分层（同一 stem 的脚本与场景放在同目录）：

- `smoke/`——行为回归主入口。`*_smoke.gd`（`extends SceneTree`，用 `-s` 跑）与少量 shell 编排。测试只结束自己记录的 PID，不按端口或名称扫描、结束其他进程。`enemy_logic_smoke.gd` 覆盖 AI、环面、武器和碰撞；其余按域细分。
- `probe/`——单点诊断与真链路探针(`*_probe.gd` / `*_probe.tscn` / `*_probe.sh`,含 `kh_l*_probe`)。
- `harness/`——被 spawn 的辅助:`*_watcher.gd`(子进程观察者)、`*_bot_input.gd`(脚本机器人输入)、`*_client.*`(裸客户端,如 `pvp_smoke_client` / `net_lag_client`)、`net_lag_proxy.py`。
- `scripts/`——三个独立诊断工具:`convert_map.gd` / `seam_analyze.gd` / `seam_screenshot.gd`。
- `network/`——三条数据流、权威模拟、预测、真实对局、官方 EasyTier 和 Windows Job 生命周期测试。完整入口见 [测试说明](../docs/eng/tests.md)。

`tests/` 顶层只留基础设施:`env.sh`(共享环境)、`lib/`(`scan_util.gd` / `probe_base.gd`,源码级探针的共享脚手架)、`path_integrity_allow.txt`(守卫的字面量常量指着它,故不随 `.gd` 搬进 `probe/`)与 `README.md`。

注意:`-s` 阶段 autoload 尚未实例化;测试脚本若静态引用会连带预加载"引用 autoload 的脚本"会在编译期失败(见 `smoke/enemy_logic_smoke.gd` 注释)。
