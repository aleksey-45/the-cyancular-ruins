# tests/ — 冒烟 / 诊断(无测试框架)

没有单测框架。运行命令见根 `CLAUDE.md`「常用命令」(headless + `-s`),成功以打印 `SMOKE OK` / `... OK` 且退出 0 为准。

文件分层(四个 bucket;`smoke/` 与 `probe/` 以文件名后缀为主,`harness/` 与 `scripts/` 按角色;一个 stem 的 `.gd` / `.tscn` / `.sh` / `.log` 伴随文件同桶):

- `smoke/`——行为回归主入口。`*_smoke.gd`(`extends SceneTree`,`-s` 跑)+ `*_smoke.sh`(多进程/双端编排,内部用 `taskkill` 按 PID + 杀 7777 端口兜底,别在 Windows bash 里直接 `kill`,杀不死 headless Godot)。`enemy_logic_smoke.gd` 覆盖最广(AI/LOS/环面/武器/碰撞);`grenade_smoke.gd`、`player_contract_smoke.gd`、`move_feel_smoke.gd` 等按域细分。
- `probe/`——单点诊断与真链路探针(`*_probe.gd` / `*_probe.tscn` / `*_probe.sh`,含 `kh_l*_probe`)。
- `harness/`——被 spawn 的辅助:`*_watcher.gd`(子进程观察者)、`*_bot_input.gd`(脚本机器人输入)、`*_client.*`(裸客户端,如 `pvp_smoke_client` / `net_lag_client`)、`net_lag_proxy.py`。
- `scripts/`——三个独立诊断工具:`convert_map.gd` / `seam_analyze.gd` / `seam_screenshot.gd`。

`tests/` 顶层只留基础设施:`env.sh`(共享环境)、`lib/`(`scan_util.gd` / `probe_base.gd`,源码级探针的共享脚手架)、`path_integrity_allow.txt`(守卫的字面量常量指着它,故不随 `.gd` 搬进 `probe/`)与 `README.md`。

注意:`-s` 阶段 autoload 尚未实例化;测试脚本若静态引用会连带预加载"引用 autoload 的脚本"会在编译期失败(见 `smoke/enemy_logic_smoke.gd` 注释)。
