# The Cyancular Ruins

> 2D 横版(平台跳跃)射击 demo · Godot 4.7 · 环面(Torus)无缝世界 · 单人 + PvP

A side-view 2D shooter-platformer demo built in Godot 4.7, with a seamless wrap-around
(torus) world and both single-player and 1v1 networked play.

---

## 运行

- **引擎**:Godot **4.7.1 标准(非 mono)**编辑器打开 `project.godot` 直接跑(F5)。
- **单人**:主菜单 →「单人」。
- 视口 1920×1440,`rendering/mobile`。

### 控制(以 `project.godot` 输入映射为准)
- 左右移动、上=跳跃/爬梯、下=下蹲/下落/下潜;水中上浮下潜
- 鼠标瞄准,左键开火(按住=持续/蓄力重型武器)
- `1`~`5` 切枪(手枪/步枪/重狙/霰弹/榴弹)
- PvP 倒下后按游戏规则自动复活;单机 `R` 重载场景

---

## PvP 联机

架构:**大厅(端口 7777)+ 每局一个独立 worker(端口 7800 起)**。

```
玩家 A ─建房─► 大厅(配对) ─拉 worker─► A、B 转连该局 worker(独占端口) → 对局
```

- 不同对局 = 不同 worker 进程 = **内存隔离**(拆墙/回合等状态不跨局互扰)。
- 客户端默认服务器 IP:`120.53.107.140`(可在匹配界面改)。

### 跑服务端
- **本地/局域网**:双击 `start_server.bat`(自动杀旧进程、启动大厅)。
- **导出版**:双击 `Cyancular Ruins Server.exe`(大厅,带控制台;会自动拉起每局 worker)。
- **云/公网**:需放行 **UDP 7777 与 7800~7999**(大厅 + 每局 worker 动态端口)。

### 连接
1. 主菜单 →「多人」
2. 服务器地址框填主机 IP(默认云 IP;局域网填主机局域网 IP)
3. 「建房」开一局并把房间号告诉对手;或「刷新」看房间、手动填房间号点「加入」
4. 对局开始:回合制——每局先到 **5 击杀**赢,三局两胜,局间换边

---

## 规则要点(PvP)
- 玩家之间**物理碰撞**;**取消命中无敌帧**,每发子弹只结算一次(霰弹逐丸生效,不帧伤)
- 每局开赛**砖块还原 + 清空场上子弹**;COUNTDOWN **3 秒冻结**
- 可破坏地形只由**服务器权威**拆(客户端同步显示),不会"幽灵墙"
- 头顶显示昵称(匹配界面输入,默认 `Anon`)、延迟按阈值绿/黄/橙/红

---

## 构建 / 发布

详见 `RELEASE.md`。一键打包(客户端 + 控制台服务端,并把服务端打回控制台):

```bash
python tools/build_release.py
```

产物在仓库根(`The Cyancular Ruins.exe` / `Cyancular Ruins Server.exe`),历史日期构建在 `builds/`。

---

## 测试

无单测框架;`Tests/` 下是 `-s` 冒烟/诊断脚本:

```bash
# 敌人/武器/环面逻辑主冒烟
Godot_console --headless --path . -s res://tests/enemy_logic_smoke.gd
# PvP 链路(大厅→worker→建房→开局)
bash tests/pvp_room_smoke.sh
bash tests/pvp_match_smoke.sh
```

> 用 4.7.1 **console** 版跑;开发/冒烟约定见 `CLAUDE.md`。

---

## 目录

```
scenes/   场景(Godot 惯例 PascalCase 的 .tscn;脚本 snake_case)
globals/  autoload + 静态工具(MazeGenerator/TileDefs/NetBus/Water…)
server/   服务端:大厅(server_main)+ 房间(RoomManager)+ 每局权威(MatchHost)
tests/    -s 冒烟/探针
editor/   浏览器地图编辑器(structure-editor.html + smoke.js)
map/      .cyrm 文本地图
tools/    发布/控制台脚本(build_release.py、make_server_console.py)
```

技术细节(环面数学/敌人 AI/网络协议/发布)见 `CLAUDE.md` 与 `RELEASE.md`。
"# the-cyancular-ruins" 
