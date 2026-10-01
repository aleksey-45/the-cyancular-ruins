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

通过 Easytier 实现远程联机。
目前使用公共服务节点 dreamlife.indevs.in，详见 https://www.bilibili.com/video/BV1vsLy6ZEor

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
**可分发的一份**在 `builds/The Cyancular Ruins <版本号> <时间戳>/` —— 六个文件平铺
(客户端 + 服务端 + EasyTier 四件套),拷走整个目录即可玩。`builds/` 里**只留最新那一份**。

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
