# 行为检查

Godot 检查使用已编译的原生扩展和已导入的项目。环境准备见 [运行与工具](tools.md)。

```sh
python tools/run_checks.py --godot "/path/to/godot"
python tools/run_checks.py --godot "/path/to/godot" --groups net,prediction
node tests/editor_case.js
python tools/check_naming.py
```

`run_checks.py` 默认在一个无头进程中运行六组检查，超时为 30 秒。脚本错误、断言失败或缺少完成标记均返回失败。引擎路径也可以来自 `GODOT`、`GODOT_EDITOR` 或 `PATH`。

| 分组 | 覆盖行为 |
|---|---|
| `net` | 输入调度和确认、房间和 READY、STATE 差分与战斗事件编解码 |
| `transport` | 动态端口、10 客户端 UDP 回环、广播与顺序、分块和大载荷、断线重连 |
| `terrain` | 地图解析、子格 HP 和碰撞、环面接缝、射线与地形回溯 |
| `simulation` | 移动、装备与弹道、命中与爆炸、队伍规则及玩法回溯 |
| `prediction` | 本地检查点、输入与 Beta 账户校正、远端代理及弹丸复制 |
| `monitor` | 指标单位、阈值、直方图、统计窗口和容量 |

编辑器检查覆盖 CYRM 编解码、旧图导入和文件保存。命名脚本检查目录、类名、场景名和编码，也检查仓库根 Markdown 文档中的本地链接。

主场景可通过 `godot --headless --path . --quit-after 90` 启动 90 帧。它覆盖主菜单加载，实际多人对局和可见画面分别通过联机运行及客户端窗口观察。
