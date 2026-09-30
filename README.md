# The Cyancular Ruins

> 2D 横版(平台跳跃)射击 demo · Godot 4.7 · 环面(Torus)无缝世界 · 单人 + 联机

A side-view 2D shooter-platformer demo built in Godot 4.7, with a seamless wrap-around
(torus) world. Single-player, plus networked 1v1 / 3v3 / free-for-all — joined with a
5-digit room code.

---

## 运行

- **引擎**:Godot **4.7.1 标准(非 mono)**编辑器打开 `project.godot` 直接跑(F5)。
- **单人**:主菜单 →「单人」。
- 视口 1920×1440,`rendering/mobile`。

### 控制(以 `project.godot` 输入映射为准)
- 左右移动、上=跳跃/爬梯、下=下蹲/下落/下潜;水中上浮下潜
- 鼠标瞄准,左键开火(按住=持续/蓄力重型武器)
- `1`~`6` 切枪(手枪/步枪/重狙 M82A1/霰弹 S686/榴弹发射器/激光枪)
- PvP 倒下后按游戏规则自动复活;单机 `R` 重载场景

---

## PvP 联机

四种玩法:**1v1**、**3v3 团队**、**大乱斗**(主菜单直接进),以及带时间玩法的
**错乱大乱斗 / 时空 3v3**(主菜单「Beta」)。房主在自己机器上开一局,对手用 **5 位房间号**进来。

```
玩家 A ──建房──►( A 的机器:大厅与对局同进程、同端口 )◄──加入── 玩家 B
                        ▲
                  5 位房间号经 EasyTier 隧道把两端接上
```

- **房主即服务器**:点「建房」时客户端自动拉起同目录的 `Cyancular Ruins Server.exe`,大厅与对局全程同进程、同端口。
- **端口由客户端挑**(20000–59999 中的空闲号),同一台机器可以同时开好几局。
- **房间号就是隧道网络名**:两端配同一个初始节点(中继),玩家之间跨公网 P2P 直连,开局延迟取决于你俩之间的线路。
- **开箱可用**:发布包自带 EasyTier 四件套(`easytier/` 下的 `easytier-core.exe` / `easytier-cli.exe` / `Packet.dll` / `wintun.dll`),拷走整个目录即可开打。初始节点地址写在 `easytier/relay.txt`;客户端与服务端的日志在 `log/` 下(细节见 `docs/netplay.md` §1.1)。

### 开发时手跑服务端
双击 `start_server.bat`(= `Server.exe -- --port 7777`),窗口开着即运行中。用来在一台固定端口的服务器上联调大厅。

### 开一局
1. 主菜单 →「1 v 1」/「3 v 3 团 队」/「大 乱 斗」/「Beta」
2. 房主点「建房」——**房间号直接出现在「房间号」框里**,报给对手
3. 对手把房间号填进自己的「房间号」框,点「加入」
4. 对局开始:1v1 回合制——每局先到 **5 击杀**赢,三局两胜,局间换边

---

## 规则要点(PvP)
- 玩家之间**物理碰撞**
- 每发子弹**只结算一次**(霰弹逐丸生效)
- 每局开赛**砖块还原 + 清空场上子弹**;COUNTDOWN **3 秒冻结**
- 可破坏地形由**服务器权威**拆,客户端同步显示
- 头顶显示昵称(大厅页输入,默认 `Anon`)、延迟按阈值绿/黄/橙/红

---

## 构建 / 发布

详见 `RELEASE.md`。一键打包(客户端 + 控制台服务端,并把服务端打回控制台):

```bash
python tools/build_release.py
```

产物在仓库根(`The Cyancular Ruins.exe` / `Cyancular Ruins Server.exe`,给开发与 `start_server.bat` 用);
**可分发的一份**在 `builds/The Cyancular Ruins <版本号> <时间戳>/` —— 两个 exe 平铺 + 一个 `easytier/`
子目录(四件套),拷走整个目录即可玩。`builds/` 里**只留最新那一份**。

---

## 测试

无单测框架;`tests/` 下是 `-s` 冒烟/诊断脚本:

```bash
# 敌人/武器/环面逻辑主冒烟
Godot_console --headless --path . -s res://tests/enemy_logic_smoke.gd
# PvP 链路(起服务端 → 建房 / 加入 → 开局)
bash tests/pvp_room_smoke.sh
bash tests/pvp_match_smoke.sh
```

> 用 4.7.1 **console** 版跑;开发/冒烟约定见 `CLAUDE.md`。

---

## 目录

```
scenes/   场景(页面与对局场景;.tscn 与脚本一律 snake_case)
core/     autoload + 静态工具(MazeGenerator/TileDefs/NetBus/Water…)
server/   服务端:入口(server_main)、大厅与房间(lobby_rooms)、对局会话与权威(match_session / match_host / royale_host / team_host)
ui/       跨场景 UI:UiFactory(唯一调色板/工厂)、单机 HUD、对局 HUD、暂停菜单
render/   渲染:后处理(post_process.gd + post_process.gdshader)、相机(camera_2d.gd)
tests/    -s 冒烟/探针(分层见 tests/README.md)
level_editor/  浏览器地图编辑器(structure-editor.html + smoke.js + sync-*.js)
maps/     .cyrm 文本地图
data/     tile_defs.json / enemies.json(与编辑器共享的属性表与敌人注册表)
assets/   字体(含中文像素字体 unifont)与纹理
tools/    发布/控制台脚本(build_release.py、make_server_console.py)+ check_naming.py(命名规范检查)
```

技术细节(环面数学/敌人 AI/网络协议/发布)见 `CLAUDE.md` 与 `RELEASE.md`。
