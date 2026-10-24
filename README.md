# The Cyancular Ruins

> 2D 横版(平台跳跃)射击 demo · Godot 4.7.1 · 环面(Torus)无缝世界 · 单人 + PvP(1v1 / 3v3 / 大乱斗)

## 运行与操作

- **引擎**:Godot **4.7.1 标准(非 mono)** 编辑器打开 `project.godot` 直接跑(F5);视口 1920×1440,`rendering/mobile`。
- **单人**:主菜单 →「单人」;单机按 `R` 重载场景,PvP 倒下后按游戏规则自动复活。
- 设置页「显示」组可选 **4:3 四档分辨率**(1280×960 / 1600×1200 / 1920×1440 / 2560×1920)与**全屏**;默认窗口 1920×1440,`stretch/aspect=keep` ⇒ 窗口任意大小时版式不变(等比缩放 + 黑边)。
- 控制(以 `project.godot` 输入映射为准):左右移动、上=跳跃/爬梯、下=下蹲/下落/下潜,水中上浮下潜;鼠标瞄准,左键开火(按住=持续/蓄力重型武器);`1`~`4` 切枪(持有位上限 `WeaponInventory.DEFAULT_MAX_WEAPONS` = 4;6 把武器:手枪/步枪/重狙 M82A1/霰弹 S686/榴弹发射器/激光枪,滚轮循环切换)。

## PvP 联机

**大厅(端口 7777)+ 每局一个独立 worker(端口 7800 起)**:不同对局 = 不同 worker 进程 = 内存隔离(拆墙 / 回合状态不跨局互扰)。流程:`玩家 A ─建房─► 大厅(配对) ─拉 worker─► A、B 转连该局 worker(独占端口) → 对局`。

- **跑服务端**:本地 / 局域网双击 `start_server.bat`(自动杀旧进程、启动大厅);导出版双击 `Cyancular Ruins Server.exe`(带控制台,自动拉起每局 worker);云 / 公网需放行 **UDP 7777 与 7800~8299**(`WORKER_PORT_BASE`=7800 起、`WORKER_PORT_SPAN`=500 个)。
- **连接**:主菜单 →「多人」→ 填服务器地址(默认 `120.53.107.140`,局域网填主机 IP)→「建房」并告知房间号,或「刷新」后填房间号「加入」。

### 三种模式(权威都在**服务器侧宿主**,客户端只显示)

| 模式 | 打法 | 胜负 | 局内死亡 |
|---|---|---|---|
| **1v1**(`server/match/match_host.gd`) | 回合制对抗 | 每局先到 **5 击杀**赢、**三局两胜**;局间换边 | 2s 后复活 |
| **3v3**(`server/hosts/team_host.gd`) | 6 人两队各 3 | 每队先到 **9 击杀**赢一局、三局两胜;局间**整队**换边 | 2s 后复活 |
| **大乱斗**(`server/hosts/royale_host.gd`) | N 人**限时**死斗、散点出生 | 倒计时归零 ⇒ **击杀最多者胜**(并列 = 0);剩 <2 人提前终局 | 2s 后复活(复活点动态避开敌人) |

★ 计分口径:**1v1 / 3v3 不分死因**(任一玩家倒地 ⇒ 对方得分);**大乱斗按 `last_damager` 归因**、无源死亡不计分。三个宿主都在 `server/match/match_host.gd` → `match_state.gd` 基类链上;细节见 [`docs/eng/modes.md`](docs/eng/modes.md)。

## 规则要点(PvP)

- 玩家之间**物理碰撞**;**无命中无敌帧**,每发子弹只结算一次(霰弹逐丸生效,不帧伤);每局开赛**砖块还原 + 清空场上子弹**;COUNTDOWN **3 秒冻结**
- 可破坏地形只由**服务器权威**拆(客户端同步显示);头顶显示昵称(匹配界面输入,默认 `Anon`)、延迟按阈值绿/黄/橙/红

## 构建 / 发布

导出、裁剪模板、版本号与产物冒烟见 [`RELEASE.md`](RELEASE.md)。一键打包(客户端 + 控制台服务端);产物落在仓库根(`The Cyancular Ruins.exe` / `Cyancular Ruins Server.exe`),时间戳归档在 `builds/`(每次导出一份副本)与 `releases/`(带发布标识的子目录),两者都不入库:

```bash
python tools/build_release.py
```

## 测试

无单测框架;`tests/` 分三档:冒烟(`-s`)/ 场景探针(`.tscn`)/ 真链路(`.sh`)。清单、逐支判词与已知边界见 [`tests/README.md`](tests/README.md)。

```bash
source tests/env.sh && "$GODOT" --headless --path . -s res://tests/smoke/network_input_smoke.gd  # 单支冒烟
bash tests/run_all.sh   # headless 默认批(不碰 7777、不弹窗;--list 看清单 / 排除理由 / 已知红基线)
bash tests/run_real.sh  # 真链路批(大厅 → worker → 建房 → 开局;占 7777)
```

> 用 4.7.1 **console** 版跑;**跑测试前先问用户**,分工与跑批纪律见 [`AGENTS.md`](AGENTS.md)。

## 目录

```
scenes/   场景(页面与对局场景;.tscn 与脚本一律 snake_case)
core/     autoload + 静态工具(参数 / 地图格式 / 寻路 / 砖块 / 水 / 联机…);sim/ net/ config/ present/ 四层
server/   服务端:大厅 + 房间(lobby/)+ 每局权威(match/ · hosts/)+ AI 补位(ai/)
ui/       跨场景 UI(factory/ 工厂与唯一调色板、hud/ HUD、screens/ 结算页等页面)
tests/    冒烟 / 探针 / 真链路(smoke/ · probe/ · harness/ · scripts/,分层见 tests/README.md)
level_editor/  浏览器地图编辑器(editor.html + smoke.js + sync-*.js)
maps/     .cyrm 地图(v4 二进制)
data/     tile_defs.json / enemies.json / weapons.json(与编辑器共享的属性表、敌人注册表与武器注册表)
assets/   字体(含中文像素字体 unifont)与纹理
tools/    发布 / 控制台脚本(build_release.py、make_server_console.py)+ check_naming.py(命名规范检查)
```

技术细节见 [`CLAUDE.md`](CLAUDE.md)(索引,分域正文在 docs/eng/*.md)与 [`RELEASE.md`](RELEASE.md)。
