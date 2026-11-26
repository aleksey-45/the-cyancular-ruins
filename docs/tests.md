# 测试

自动化测试以无头模式运行 Godot 项目，并加载预先编译的原生扩展。源码环境见 [运行与工具](tools.md#从源码运行)。CI 在 Windows 和 macOS 上运行相同的测试。[CI 工作流](../.github/workflows/build.yml)

```sh
python tools/run_checks.py --godot "/path/to/godot"
python tools/run_checks.py --godot "/path/to/godot" --groups net,prediction
python tools/check_naming.py
```

`run_checks.py` 默认在一个 Godot 进程中运行八组测试。`--groups` 接受以逗号分隔的组名。Godot 路径也可来自 `GODOT`、`GODOT_EDITOR` 或 `PATH`。断言失败、运行日志报错、缺少完成标记或 Godot 进程用时超过 120 秒时，脚本返回非零退出码。

| 分组 | 覆盖内容 |
|---|---|
| `net` | 三种玩法的本地与网络输入逐帧对照、席位调度与确认、房间就绪、完整状态、历史差分和地形编解码 |
| `transport` | 启动本地专用服务器、房主远程入口故障、入房拒绝和未确认、本机 UDP 回环、16 个客户端、广播、消息顺序、大消息分片与重连 |
| `terrain` | 地图解析、子格耐久度与碰撞、跨边界查询、射线和地形回溯 |
| `simulation` | 移动、装备、弹道、伤害、队伍规则和时间回溯 |
| `prediction` | 从完整快照恢复后继续模拟、处理乱序到达的地形更新、重放输入、按服务器状态显示倒地、在同一渲染时刻采样远端角色和弹丸 |
| `editor` | 七层 CYRM 地图的读写往返、编辑工具、撤销与重做、文件和草稿、试玩视差与选图 |
| `lan` | 局域网公告编解码、摘要和地址过期、同号选路、席位换路重连、入房拒绝与回执超时 |
| `monitor` | 统计周期、样本单位、耗时阈值、直方图及存储容量 |

文件检查脚本检查目录、GDScript 类名、场景名、脚本编码和换行，也检查仓库根目录 Markdown 文件中的本地链接。

运行脚本先独立解析一份武器资源，工作区包含联机测试工具时也检查对局驱动和时序回放的入口。

主菜单加载可用 `godot --headless --path . --quit-after 90` 做冒烟测试。Godot 运行项目的主场景，90 帧后退出。

## 图形测试

图形模式会额外执行窗口输入、字形渲染和画面采样断言。以下命令运行同一套八组测试，日志结尾应为 `CHECKS COMPLETE failures=0`。

```sh
godot --path . res://tests/run.tscn -- --no-perf
```

## 发行包

构建发行包后，可以解压 ZIP 并从解压目录启动其中的游戏，检查退出状态与 Godot 日志。

```sh
python tools/check_package.py builds/The-Cyancular-Ruins-Windows.zip
```

在 macOS 上传入 `builds/The-Cyancular-Ruins-macOS.zip`。
