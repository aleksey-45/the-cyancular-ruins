# The Cyancular Ruins

> 2D 横版(平台跳跃)射击 demo · Godot 4.7 · 环面(Torus)无缝世界 · 单人 + PvP

A side-view 2D shooter-platformer demo built in Godot 4.7, with a seamless wrap-around
(torus) world and both single-player and 1v1 networked play.

---

## 运行

- **引擎**:Godot **4.7.1 标准(非 mono)**编辑器打开 `project.godot` 直接跑(F5)。
- **单人**:主菜单 →「单人」。
- 视口 1920×1440,`rendering/mobile`。
- 设置页「显示」组可选 **4:3 四档分辨率**(1280×960 / 1600×1200 / 1920×1440 / 2560×1920)与**全屏**;默认窗口仍是 1920×1440(逻辑基准),`stretch/aspect=keep` ⇒ 窗口任意大小时**版式不变**(等比缩放 + 黑边)。

### 控制(以 `project.godot` 输入映射为准)
- 左右移动、上=跳跃/爬梯、下=下蹲/下落/下潜;水中上浮下潜
- 鼠标瞄准,左键开火(按住=持续/蓄力重型武器)
- `1`~`4` 切枪(持有位上限 `WeaponInventory.DEFAULT_MAX_WEAPONS` = 4;武器共 6 把:手枪/步枪/重狙 M82A1/霰弹 S686/榴弹发射器/激光枪,滚轮可循环切换)
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
- **云/公网**:需放行 **UDP 7777 与 7800~8299**(大厅 + 每局 worker 动态端口;worker 端口池 = `WORKER_PORT_BASE`7800 起、`WORKER_PORT_SPAN`500 个)。

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

无单测框架;`tests/` 下是 `-s` 冒烟/诊断脚本(2026-10-09 已按证据削减到原来的 ~10%,
台账见 [`docs/superpowers/specs/2026-10-09-test-surface-cut-90-design.md`](docs/superpowers/specs/2026-10-09-test-surface-cut-90-design.md)):

```bash
# 输入包/服务端收口(默认批的入口之一)。引擎不在 PATH ⇒ 先取 $GODOT(tests/env.sh 是它的一处默认值)
source tests/env.sh && "$GODOT" --headless --path . -s res://tests/smoke/network_input_smoke.gd
# 整批(14 支;不碰 7777、不弹窗。`--list` 看清单 + 每条排除理由 + 已知红基线)
bash tests/run_all.sh
# PvP 链路(大厅→worker→建房→开局;占 7777,走真链路批)
bash tests/smoke/pvp_room_smoke.sh
bash tests/smoke/pvp_match_smoke.sh
```

> 用 4.7.1 **console** 版跑;开发/冒烟约定见 `CLAUDE.md`。

---

## 目录

```
scenes/   场景(页面与对局场景;.tscn 与脚本一律 snake_case)
core/     autoload + 静态工具(MazeGenerator/TileDefs/NetBus/Water…);present/ 表现层(后处理/相机/字体/音效)
server/   服务端:大厅 + 房间(lobby/)+ 每局权威(match/ · hosts/)+ AI 补位(ai/)
ui/       跨场景 UI(factory/ 工厂与唯一调色板、hud/ HUD、screens/ 结算页等页面)
tests/    -s 冒烟/探针(smoke/ · probe/ · harness/ · scripts/,分层见 tests/README.md)
level_editor/  浏览器地图编辑器(editor.html + smoke.js + sync-*.js)
maps/     .cyrm 文本地图
data/     tile_defs.json / enemies.json / weapons.json(与编辑器共享的属性表、敌人注册表与武器注册表)
assets/   字体(含中文像素字体 unifont)与纹理
tools/    发布/控制台脚本(build_release.py、make_server_console.py)+ check_naming.py(命名规范检查)
```

技术细节见 `CLAUDE.md`(索引,**分域正文在 `docs/eng/`**)与 `RELEASE.md`。
