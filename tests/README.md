# tests/ — 冒烟 / 诊断(无测试框架)

没有单测框架。运行命令见根 `CLAUDE.md`「常用命令」(headless + `-s`),成功以打印 `SMOKE OK` / `... OK` 且退出 0 为准。

文件分层:

- `*_smoke.gd`——`extends SceneTree` 的行为回归主入口,`-s` 跑。`enemy_logic_smoke.gd` 覆盖最广(AI/LOS/环面/武器/碰撞);`water_probe.gd`、`tile_destroy_probe.gd`、`climb_probe.gd`、`grenade_smoke.gd`、`player_contract_smoke.gd` 等按域细分。
- `*_probe.gd` / `*_probe.sh`——单点诊断与临时探针(可跑可不跑,非回归)。
- `*.sh`——多进程/双端编排(`pvp_room_smoke.sh` / `pvp_match_smoke.sh` 等),内部用 `taskkill` 按 PID + 杀 7777 端口兜底,别在 Windows bash 里直接 `kill`(杀不死 headless Godot)。
- `.tscn` / `.uid` 等——测试 fixture 与辅助资源。

注意:`-s` 阶段 autoload 尚未实例化;测试脚本若静态引用会连带预加载"引用 autoload 的脚本"会在编译期失败(见 `enemy_logic_smoke.gd` 注释)。
