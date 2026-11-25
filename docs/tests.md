# 测试

自动化测试通过已编译的原生扩展运行 Godot 项目，源码环境见 [运行与工具](tools.md#从源码运行)。CI 在 Windows 和 macOS 上运行同一组 Godot 测试。[CI 工作流](../.github/workflows/build.yml)

```sh
python tools/run_checks.py --godot "/path/to/godot"
python tools/run_checks.py --godot "/path/to/godot" --groups net,prediction
python tools/check_naming.py
```

`run_checks.py` 默认在一个无界面的 Godot 进程中运行八组测试。`--groups` 接受逗号分隔的组名。Godot 路径也可来自 `GODOT`、`GODOT_EDITOR` 或 `PATH`。断言失败、脚本错误、缺少完成标记或测试总用时超过 120 秒时，脚本返回非零退出码。

| 分组 | 覆盖内容 |
|---|---|
| `net` | 输入调度与确认、房间和就绪流程、完整状态、历史差分和地形编解码 |
| `transport` | 启动本地专用服务器并建房、本机 UDP 回环、16 个客户端、广播、消息顺序、大消息分块与重连 |
| `terrain` | 地图解析、子格耐久度与碰撞、跨边界查询、射线和地形回溯 |
| `simulation` | 移动、装备、弹道、伤害、队伍规则和时间回溯 |
| `prediction` | 从完整快照恢复后继续模拟、处理乱序到达的地形更新、重放输入、按服务器状态显示倒地、在同一渲染时刻采样远端角色和弹丸 |
| `editor` | 七层 CYRM 往返、地图工具、撤销与重做、文件和草稿、试玩视差与选图 |
| `lan` | 局域网广播包编解码、字段校验、房间过期、按房间号去重与刷新 |
| `monitor` | 统计周期、样本单位、耗时阈值、直方图及存储容量 |

文件检查脚本检查目录、GDScript 类名、场景名、脚本编码和换行，也检查仓库根目录 Markdown 文件中的本地链接。

主菜单的短时加载检查使用 `godot --headless --path . --quit-after 90`，游戏运行 90 帧后退出。

## 手动回归

- 对局表现回归覆盖单人和联机进出场、加载失败后的返回、动作形变与残影、武器挂点。按两种窗口尺寸分别截取加载中、就绪和错误画面。 [界面视觉验收](construction/ui-visual-qa.md)
- 检查录屏时长、音画同步、退出对局后的文件完整性，以及未安装 ffmpeg 时的 AVI/WAV 输出。单人倒地后分别验证播完和跳过能重开，并检查画面缓存不足时的模拟倒带。 [录屏与死亡倒带](render.md#录屏与死亡倒带)
- 上游迁移仍待逐字段对照 `main` 的八份武器资源，并用两台设备验证 LAN 发现、直连、房间从列表移除、关闭广播后凭房间号加入以及断线重连。 [武器资源](weapons.md) · [局域网发现](netplay.md#局域网发现)

## 发行包

构建发行包后，可以解压 ZIP 并从解压目录启动其中的游戏，检查退出状态与 Godot 日志。

```sh
python tools/check_package.py builds/The-Cyancular-Ruins-Windows.zip
```

在 macOS 上传入 `builds/The-Cyancular-Ruins-macOS.zip`。
