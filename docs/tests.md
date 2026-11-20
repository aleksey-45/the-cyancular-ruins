# 测试

自动化测试通过已编译的原生扩展运行 Godot 项目，源码环境见 [运行与工具](tools.md#从源码运行)。CI 在 Windows 和 macOS 上运行同一组 Godot 测试。[CI 工作流](../.github/workflows/build.yml)

```sh
python tools/run_checks.py --godot "/path/to/godot"
python tools/run_checks.py --godot "/path/to/godot" --groups net,prediction
node tests/editor_case.js
python tools/check_naming.py
```

`run_checks.py` 默认在一个无界面的 Godot 进程中运行七组测试。`--groups` 接受逗号分隔的组名。Godot 路径也可来自 `GODOT`、`GODOT_EDITOR` 或 `PATH`。断言失败、脚本错误、缺少完成标记或测试总用时超过 120 秒时，脚本返回非零退出码。

| 分组 | 覆盖内容 |
|---|---|
| `net` | 输入调度与确认、房间和就绪流程、状态差分与战斗事件编解码 |
| `transport` | 启动本地专用服务器并建房、本机 UDP 回环、16 个客户端、广播、消息顺序、大消息分块与重连 |
| `terrain` | 地图解析、子格耐久度与碰撞、跨边界查询、射线和地形回溯 |
| `simulation` | 移动、装备、弹道、伤害、队伍规则和时间回溯 |
| `prediction` | 预测状态、本地输入及 Beta 账户校正、远端角色和弹丸同步 |
| `monitor` | 统计周期、样本单位、耗时阈值、直方图及存储容量 |
| `lan` | 局域网房间广播包的编解码/校验、TTL 过期、按房号去重与刷新 |

编辑器测试覆盖 CYRM 编解码、兼容格式导入和文件保存。文件检查脚本检查目录、GDScript 类名、场景名、脚本编码和换行，也检查仓库根目录 Markdown 文件中的本地链接。

主菜单的短时加载检查使用 `godot --headless --path . --quit-after 90`，游戏运行 90 帧后退出。
