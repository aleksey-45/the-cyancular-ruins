# CLAUDE.md

## 项目概览

Godot 4.7.1(标准版,非 mono)做的 2D 横版(平台跳跃)射击 demo「The Cyancular Ruins」。1920×1440 视口、`rendering/mobile`。核心特色:

- **环面世界**:地图左右 / 上下无缝回绕,敌人 / 子弹 / 镜头跨接缝连续。
- 单关卡(Level0)从 `maps/*.cyrm` 加载(现行 = **v4 二进制**,见 [`docs/eng/world.md`](docs/eng/world.md));**每次会话随机取一份地图文件**,不做运行时地形生成。
- 玩法:单机 + PvP(1v1 / 3v3 / 大乱斗)+ 时间玩法(回溯 / 加速)。

## 常用命令

Godot 不在 PATH,用绝对路径。**两个二进制不能混用**:`GODOT`(console 版,跑测试 / 服务端)与 `GODOT_EDITOR`(标准编辑器,导出用)。两者都可用环境变量覆盖,未设时回落本机默认路径(每个入口只留一处默认值:[`tests/env.sh`](tests/env.sh) / `start_server.bat` / [`tools/build_release.py`](tools/build_release.py)):

```bash
# 冒烟测试(SceneTree 脚本;通过时打印该支自己的 OK 文本)
"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . -s res://tests/smoke/net_wire_smoke.gd

# headless 启动游戏 90 帧后退出(看脚本报错)
"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . --quit-after 90

# PvP 服务端(headless,监听 7777;保持终端开着 = 运行中)。更省事:双击仓库根 start_server.bat。
"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . res://server/server_main.tscn

# 导出单 exe 发布版
"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64.exe" --headless --path . --export-release "Windows Desktop" "The Cyancular Ruins.exe"
```

测试清单、聚合入口与跑批纪律见 [`tests/README.md`](tests/README.md) 与 [`docs/eng/tests.md`](docs/eng/tests.md);发布 / 裁剪模板 / 版本号见 [`RELEASE.md`](RELEASE.md)。

## 架构(索引)

各域细节在 `docs/eng/*.md` 下,按需要读那一份(域的真相源 = `ls docs/eng/*.md`):

| 什么时候读 | 文件 |
|---|---|
| 改地图格式(cyrm)、环面几何 / 寻路、参数体系、砖块属性与破坏、水、碰撞层 | [`docs/eng/world.md`](docs/eng/world.md) |
| 加 / 改敌人、AI 状态机、寻路、精英与掉落 | [`docs/eng/enemies.md`](docs/eng/enemies.md) |
| 加 / 改武器与子弹、弹道与命中、背包容量、地面拾取、武器注册表 | [`docs/eng/weapons.md`](docs/eng/weapons.md) |
| 移动 / 跳跃 / 冲刺 / 下蹲、姿态碰撞箱、输入注入、残弹与换弹 | [`docs/eng/player.md`](docs/eng/player.md) |
| Level0 渲染管线、图集、后处理、补间形变 | [`docs/eng/render.md`](docs/eng/render.md) |
| 调色板与 UiFactory、菜单语汇、HUD、小地图、大厅版式 | [`docs/eng/ui.md`](docs/eng/ui.md) |
| 大厅 / worker、匹配进图、房间与回合、回到大厅、重连、RPC 归属 | [`docs/eng/netplay.md`](docs/eng/netplay.md);重连 → [`netplay-reconnect.md`](docs/eng/netplay-reconnect.md)、房间寿命与回局 → [`netplay-rooms.md`](docs/eng/netplay-rooms.md)、RPC 通道号单一来源 → [`netplay-rpc-channels.md`](docs/eng/netplay-rpc-channels.md) |
| 快照管线、输入上行、插值与输入、增量与量化、16 人局读数、tick 率、playout 时钟、抖动缓冲 | `docs/eng/netcode-*.md`(快照那份:[`netcode-snapshots.md`](docs/eng/netcode-snapshots.md)) |
| 3v3、结算页、大乱斗及其已知差异 | [`docs/eng/modes.md`](docs/eng/modes.md) |
| 时间玩法(回溯 / 加速 / 颗粒账户 / 怀表 / 世界重绕)、它的不变量与常量来源 | [`docs/eng/time.md`](docs/eng/time.md) |
| 探针怎么跑 / 怎么判、真链路纪律、守卫边界;测试该不该写、写哪一档(桶划分与不写清单) | [`docs/eng/tests.md`](docs/eng/tests.md)、[`docs/eng/test-economy.md`](docs/eng/test-economy.md) |
| 浏览器地图编辑器(怎么开、怎么打包成单文件)、sync-*.js、导入 / 导出工具 | [`docs/eng/tools.md`](docs/eng/tools.md);编辑器各层:[core](docs/eng/editor-core.md) / [ui](docs/eng/editor-ui.md) / [render](docs/eng/editor-render.md) / [io+worker](docs/eng/editor-io.md) / [server](docs/eng/editor-server.md) |
| 注释怎么写(含**注释额度**:>100 行的 `.gd` ≤15%)、守卫幻觉怎么标 | [`docs/eng/comment-style.md`](docs/eng/comment-style.md) |
| 房间 / 端口生命周期约定(回收梯、超龄扫、端口池) | [`docs/eng/room-lifecycle-conventions.md`](docs/eng/room-lifecycle-conventions.md) |
| **动手前必看**:既有红 / 待还的债 / 已裁定不做 | [`docs/eng/registered-debt.md`](docs/eng/registered-debt.md) |
