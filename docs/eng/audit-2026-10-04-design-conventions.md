# 设计与主流规范审计（2026-10-04）

> **这是什么**：一次针对「有没有不符合主流规范、明显不合理的设计」的全仓审计记录。覆盖 6 个域
> （联机 / 世界几何 / 渲染表现 / UI / 玩家武器敌人 / 工程测试工具），由 6 个只读子代理分头读代码，
> 逐条结论再由审计者**抽读原文复核**（复核中发现并纠正了子代理的两处判断，见 §6）。
>
> **这不是什么**：★ **它不是欠账清单**。[`registered-debt.md`](registered-debt.md) 仍是**唯一**的欠账
> 清单，本文件**没有**改动它。要把本文件里的条目转成"要我修"，得由人挑一批写进那份清单。
>
> **判据**：每条都带 `相对路径:行` + **逐字引用**。图例：
> `✅` = 审计者亲自读到该行原文；`⚠` = 静态可证但**未实机验证**；`❓` = 未证实，不要当事实用。
>
> **基线**：Godot 4.7.1 标准版官方文档（渲染器选择 / 多分辨率 / 自动加载 / GDScript 风格指南 /
> 日志与导出）+ 上游引擎源码与 issue + 社区权威多人实践。链接见 §8。

---

## 0. 总体判断

这个仓库**不是**"一堆不合规范的设计"。相反：绝大多数偏离主流的地方，代码注释里都写清了
"为什么"（为什么不用引擎复制节点、为什么杀端口、为什么参数不从 autoload 取），而且**比主流更严**
的地方不少 —— `net_bus.gd:105-121` 判活读 ENet peer 自己的 state 而非滞后的 `get_peers()`；
`tests/probe/allscript_probe.gd:17-35` 有覆盖面下限（fail-closed 而非 fail-open）；
`tests/smoke/menu_theme_mirror_smoke.gd` 的 Theme 镜像守卫读的是**生产产出**并带条数闸。

真正的问题集中在三类：

1. **写坏了但没人发现**（静默失效）—— 典型是 §1.2 的 `[debug]` 键；
2. **单机侧接线缺口**（有功能后果）—— 典型是 §1.1 的幽灵砖；
3. **靠纪律而非机制维护的一致性** —— 文档/注释/真值三处不符、生成式只做了一半、守卫有盲区。

---

## 1. 高：会静默失效或已有功能后果

### 1.1 单机激光磨砖 = 幽灵砖：格级拆砖回调只接了服务器 ⚠

> ★★ **2026-10-04 已修** —— 本节描述的是**修前**状态,下面引用到的行号也都是修前的。三条都已落地:
> - ① **单机补格级回调**:`scenes/level_0.gd:246` 注册 `on_destroyed` → `TileDefs.destroy_cell(cell)`
>   (清该格 16 个子格的 `sub_hp` + 逐子格发 `on_sub_destroyed`,渲染/碰撞/瓦片账本由回调收口)。
> - ② **PvP 孪生兄弟**:`server/match/match_combat.gd:18-22` 改按**当前格** 4×4 清 `destructible_sub`,
>   并补静默口 `TileDefs.zero_cell_sub_hp` —— ★ 碰撞的**真相源是 `sub_hp`**(`CollisionBuilder.build_sub`
>   按 `sub_alive` 筛),不是 `destructible_sub`;只清后者,`build_sim` 会在复位时把墙算回来。
> - ③ **回溯保真**:`scenes/level_0.gd:426-470` 的 `_restore_sub` 已把 `hp_grid` 一并写回
>   (此前"整格碎过再回溯 ⇒ `hp_grid[cell]` 仍 0 ⇒ 下一发激光一发即碎")。
> - ④ **只有查源码才会发现的孪生缺陷**(本轮评审逼出来的):`MatchRound._reset_world_and_clear_dynamics`
>   每局复位漏了 `TileDefs.init_sub_hp`(客户端 `reset_destructibles` 一直还**两套表**)⇒
>   下一局"客户端有墙、服务器没有"⇒ **可穿墙**。已修(`server/match/match_round.gd`)。
>
> 守卫:`tests/probe/tile_collision_probe.gd` **相③b**(格级销毁无幽灵砖)+ **相④b**(回溯含格级 HP);
> `tests/probe/destroyed_cells_probe.gd` 相③/相⑥(服务器拆砖 + 复位两套表)。逐轮裁决与偏离追认见
> [`plans/2026-10-04-tile-destruction-consistency.md`](../superpowers/plans/2026-10-04-tile-destruction-consistency.md)。
> ★ **仍未闭环**:真链路(占 7777)端到端未跑 ⇒ "真 PvP 局可达"目前只算**静态可达 + 单进程探针覆盖**。

**机制**（`✅` 全部逐字读过）：

- 格级回调声明：`core/sim/tile_defs.gd:185` `static var on_destroyed: Callable = Callable()`
- 全仓**唯一**接线在服务器：`server/match/match_host.gd:46`
  `TileDefs.on_destroyed = Callable(self, "_on_tile_destroyed")`
- 单机场景只接了**子格**口：`scenes/level_0.gd:241`
  `TileDefs.on_sub_destroyed = Callable(self, "_on_sub_destroyed")`
- 触发点走的是**格级**：`scenes/weapons/laser_weapon_base.gd:282`
  `TileDefs.damage_tile(t["cell"], tile_chip, "explosion")`
  门控 `:75` `return not Level0.pvp_mode` ⇒ **单机必走**
- 清格后回调打空：`core/sim/tile_defs.gd:384-386`
  ```
  		grid[cell.y][cell.x] = 0
  		hp_grid[cell.y][cell.x] = 0
  		if on_destroyed.is_valid():
  			on_destroyed.call(cell)
  ```

**后果**：`current_grid` 已当空气（BeamTrace / 寻路 / LOS 全按空气算），而瓦片层不重绘、
`_destructible_sub` 不重建 ⇒ **逻辑 / 物理 / 画面三者分叉**，正是本仓在
`server/match/match_host.gd:48` 自称最忌的"幽灵墙"。

**为什么这是接线缺口而不是有意设计**：子弹侧**故意**避开了这条路 ——
`scenes/weapons/bullet_base.gd:165` `if MazeGenerator.current_subgrid.is_empty():` 才回落到格级，
并在 `:160` 写明格级路径的契约是"破坏后变空气（**Level0 刷新渲染/碰撞**）"。激光的注释
（`laser_weapon_base.gd:276-278`）也假设"由 `damage_tile` 回调 **Level0** 处理"。**假设成立，
接线没做。**

**修法**（二选一，★ **2026-10-04 复核后订正了定档与代价**，见 §3 顶部订正块第 4 条）：

- **(a) Level0 补格级回调**（`level_0.gd:241` 旁接 `TileDefs.on_destroyed`，回调内 `for sy in 4: for sx in 4:`
  读 `sub_hp` → `TileDefs.restore_sub(sub, 0)` → 复用 `_on_sub_destroyed(sub, pre_hp)`）——
  **档 2**，渲染/碰撞/脏块/账本一次到位。但**只修单机**，修不掉 PvP 那半；且有个坑：
  `_restore_sub`（`:426-465`）不还原 `hp_grid`（`damage_tile` 已把它写成 0）⇒ **回溯复原的格会被下一发激光"一发清整格"**。
- **(b) 激光改走 `damage_sub`**（改 `laser_weapon_base.gd:281-282` 一处）—— 更小、零新状态，
  且删掉格级破坏**最后一个生产调用点**。但它是 **档 3**（权威侧破坏判定 + 广播由 `tile_destroyed`
  变 `sub_destroyed`，坏了要真对局打树叶才发现），而且**语义不等价**：`tile_defs.gd:239`
  给每个 16px 子格发的是**格级** hp ⇒ 整格耐久 **×16**（树叶 16 发、树干 64 发），
  **"一发开大洞"的手感消失** ⇒ 这一步必须由人拍一个数值。

★ **本缺陷还有一个 PvP 可达的孪生兄弟**（`server/match/match_combat.gd:18-22` 按 2×2 清子格 ⇒
服务器清错邻格、留幽灵墙），**它今天就在真对局里可达** —— 见 §3 顶部订正块第 4 条。两条得一起修，
否则"只修单机"等于没修一半。

### 1.2 `project.godot` 的 `[debug]` 段被一次"改键位"提交毁掉 ✅

> ★ **2026-10-04 已修** —— 本节描述的是**修前**状态。`b2f4134` 已把 `[debug]` 三键按 `6b5f3fb` 的原样补回
> （`file_logging/enable_file_logging` / `enable_file_logging.pc` / `max_log_files=64`），并配了常驻守卫
> `tests/smoke/project_settings_smoke.gd`。★ 守卫的**承重断言是"读 `project.godot` 原文判三行逐字存在"** ——
> 实现者拿空工程实测：`has_setting(...)` 对这三个**引擎内置**键**恒真**（连本仓从未写过的 `log_path` 也返回 true），
> 而 `.pc` 的引擎默认值本就是 `true` ⇒ 只断言"存在/为真"**拦不住** `d6d2440` 那种"键名被乱码吞掉"的事故。
> 覆盖上限：测不到"日志**真的**落到 `user://logs/`"，也测不到**导出模板的 release 半边**（见 [`registered-debt.md`](registered-debt.md) §五）。

**现状**：`project.godot:35-36` 两条键**不是合法设置名**（键里塞进了 8 行注释、中文被双重编码），
`grep "^file_logging" project.godot` 零命中：
```
[mojibake Chinese prefix]file_logging/enable_file_logging"=true
[mojibake Chinese prefix]file_logging/max_log_files"=64
```

`od -c` 可见 `303 250`（= 0xC3 0xA8）这类**双重编码**特征：原始 UTF-8 中文被按 Latin-1/GBK 解一遍
再按 UTF-8 存回。

**取证（谁什么时候弄坏的）**：

- `git show 6b5f3fb`（2026-09-12，「客户端/worker 都要留引擎日志」）当初写的是**正确**的键，
  并附理由"导出客户端是 GUI 子系统（无控制台），崩了/报错了在用户机器上**一个字都留不下来**"：
  ```
  file_logging/enable_file_logging=true
  file_logging/enable_file_logging.pc=true
  file_logging/max_log_files=64
  ```
- **`git show d6d2440`（B10「加速键位改为鼠标右键」）**：这个提交本意只改一个按键，却把整个
  `[debug]` 段从文件尾"搬"到 `[autoload]` 之后，**把 8 行注释并进了两条键名**、中文双重编码，
  并**整行吞掉了 `enable_file_logging.pc=true`**。一次只改键位的提交顺手废掉了一整段崩溃日志配置，
  一周无人发现。

**影响面（与常见误判相反）**：桌面端文件日志**默认就是开的**
（见 §8 官方 Logging 文档："By default, Godot writes log files in `user://logs/godot.log` on desktop
platforms"，以及上游 commit "Enable file logging by default on desktops"）。实测
`%APPDATA%/Godot/app_userdata/The Cyancular Ruins/logs/` 里连**导出客户端**在 02:11 跑的轮转日志都在。
真正失效的是**配额**：`max_log_files` 停在默认 **5**（官方文档：`Up to 5 log files are kept by default`；
实测该目录恰好 5 份 = `godot.log` + 4 份带时间戳）。而
`docs/2026-09-17-duel-probe-lobby-rpc-blocker.md:18` 声称
"`project.godot` 的 `log_file_logging/max_log_files` 5 → 64（原先会把崩溃现场轮转吃掉）"——
**这条保障今天不存在**，与当初那次"用户唯一的崩溃现场被轮转挤掉"是同一个坑。（顺带：那句话里的键名
本身也写错了一层，应为 `debug/file_logging/max_log_files`。）

**修法**：删 `project.godot:35-36`，按 `6b5f3fb` 的原样补回三条真键；再加一条"源码级守卫"——
`project.godot` 的键必须匹配 `^[a-z_]+/`（或断言 `ProjectSettings` 认得这些键），
这样下次再有工具把注释并进键名时会红。

### 1.3 发布 exe 里打包了整套测试与工具（336 条 `res://tests/*`）✅

**配置**：`export_presets.cfg:11-13`

```
export_filter="all_resources"
include_filter="maps/*.cyrm,data/*.json"
exclude_filter="*.md,.superpowers/*"
```

**实证**（对仓库根那两个 44MB exe 直接 grep）：

```
$ grep -a -o -P 'res://tests/[A-Za-z0-9_./-]+' "The Cyancular Ruins.exe" | sort -u | wc -l
336          # 含 .gdc/.gdv 编译产物，如 res://tests/harness/ground_bot_input.gdc
$ grep -a -o -P 'res://[A-Za-z0-9_./-]+' … | awk -F/ '{print $1}' | sort | uniq -c
    407 tests    10 tools    3 DevTools    50 server   …
```

**关键证据：这不是引擎限制。** 同一份 exe 里 `res://.superpowers/*`（同样含 51 个 `.gd`）**确实被排掉了**
⇒ `exclude_filter` 对**资源**（脚本）也生效，只是**没写 `tests/*`**。补一行即可。
另有 `res://DevTools/*` **3 条**。★ **2026-10-04 订正（本条初稿写错了）**：初稿说"那是**未入库**的本机目录，
按 `.gitignore` 只挡 git、不挡导出" —— **反了**。`DevTools/gamelog/log_viewer.{gd,gd.uid,tscn}`
**是已入库的**（`.gitignore` 只挡未跟踪文件，挡不住已经在库里的；`.gitignore:38` 那句"本机残留…不属于
上游工程"对这 3 个文件是错的）。⇒ 连带两条新发现：
① **`export_presets.cfg` 的 `exclude_filter` 里没有 `DevTools/*`**（`:13`/`:87` 都是 `"*.md,.superpowers/*"`），
而 `docs/superpowers/plans/2026-09-21-cyrm-v4-editor-render-and-ui.md:262` 那一步
（"排除 DevTools（两处 preset 都要改）"）**从未落地**（勾选框是 `- [ ]`，但按本仓"勾选框不可信"的教训，
以 `grep exclude_filter` 为准）；
② 它们是 `gamelogs/`（gitignore）的**只读查看器**，即"本机工具"被跟踪、被导出、却又不该在库里 ——
三个属性同时成立，只有 `git rm` 能解（ignore 规则办不到）。

**要一并知道的两件事**：

- 主菜单**故意**依赖其中一个测试文件：`scenes/main_menu.gd:163-170` 在 `-- --autotest-*` 时
  `load("res://tests/smoke/menu_autotest.gd")`；且 `:154-155` 注释里**已知**"tests/ 会一起打进发布包"。
  所以这不是"没想到"，而是"知道但没当问题"。代价：向内泄漏实现 + 玩家侧多一个自动化后门。
  真要排 tests 就得把这一个文件挪出 `tests/`（或改成不依赖测试文件）。
- 客户端 exe 里有 **50 条 `res://server/*`**，而客户端代码对 `res://server/` 的引用是 **0 次**
  （已 grep 确认）⇒ 纯死重。

### 1.4 1920×1440 固定窗口 · 不可缩放 · 全仓无全屏 ✅

`project.godot:40-43`

```
window/size/viewport_width=1920
window/size/viewport_height=1440
window/size/resizable=false
window/stretch/mode="viewport"
```

`grep DisplayServer\|fullscreen\|window_set_size` 在非测试代码里 **0 命中**；设置页唯一的"显示"组
是**游戏内视觉项**（`scenes/settings_menu.gd:63-70`），没有窗口/全屏开关。

⇒ 1080p 屏高 1080 < 1440：窗口超出屏幕 360px，用户既不能缩放也没有全屏出路。❓ 具体走"超出屏幕"
还是"被 OS 钳制成 0.75× 非整数放大"**未实机验证**（两种后果都指向同一个修法：`resizable=true` +
全屏开关，基准尺寸收进 1080p）。

附带一条设置自相抵消：`:40-41` 基准尺寸**等于**窗口、`:42` 又不可缩放 ⇒ `stretch/mode="viewport"`
的倍率**恒 1.0**，"整屏渲染到低分辨率再放大"在本工程从未发生。

---

## 2. 与主流规范正面冲突

| # | 问题 | 证据（`✅` = 已读原文） | 为什么不主流 |
|---|---|---|---|
| 2.1 | **按 UDP 端口无差别强杀进程**，且 `start_server.bat` 那条**结构性永不命中** | `core/net/proc_util.gd:20-26`：`Get-NetUDPEndpoint -LocalPort … \| Select -ExpandProperty OwningProcess -Unique` → `Stop-Process -Id $_ -Force`；大厅启动就调：`server/server_main.gd:154` `ProcUtil.kill_udp_port(NetBus.DEFAULT_PORT)`。而 `start_server.bat:16` 用 `for /f "tokens=5" %%p in ('netstat -ano ^\| findstr /r ":7777"')` —— **UDP 行只有 4 列**（实测 `netstat -ano \| awk NF` = 4），`tokens=5` 取不到 PID | 主流：bind 失败→明确报错退出。这里杀的是该端口的**任意属主**（别的程序 / 另一个正在跑的大厅）。`env.sh:79-81` 已经踩过同形状的坑（"带 `LISTENING` 的判据**结构性恒假**"），但只修了 tests 侧。⚠ 动机在 `proc_util.gd:5-9` 写明（旧实例占着 7777 → 新实例 bind 失败闪退），属**有理由**，但对"误杀"这半边无护栏 |
| 2.2 | **输入包 `ax` 无界，服务端零校验** | `core/net/packet_input_source.gd:121` `_axis = pkt.get("ax", 0.0)` → `:175` `return _axis`；`scenes/player/player.gd:373` `var target_velocity_x = horizontal_input * speed_target * mult.x`；服务端接收 `server/match/match_host.gd:190` `(_pending_input[role] as Array).append(pkt)`（无边检/钳位/限速） | 主流在服务端把轴钳到 `[-1,1]`。`move_speed=700`，`ax=50` ≈ 35000px/s（全图 9600px）。★ 本仓**声明不承担反作弊**（`server/lobby/lobby_rooms.gd:233` "**不防**恶意爆破(本设计不承担反作弊)"），但 `ax` 无界同时是**协议健壮性**问题（版本不匹配/有 bug 的客户端会瞬移），与反作弊是两件事 |
| 2.3 | **输入队列无上限 + 每 tick 只消费 1 包**，积压不可恢复 | `server/match/match_host.gd:251` `var pkt: Dictionary = q.pop_front()`（每 tick 一包）；`:190` append 无上限；同文件 `:159` 自述实测"队列在开局 1 秒内从 0 跳到 8 然后就永远停在那儿(**ρ=1,没有回复力**)" | 主流：硬上限 + 丢最旧。常驻 ~133ms 输入延迟；持续灌包则服务端内存无界。⚠ 走 reliable 是为"不丢 just_pressed 边沿"（`packet_input_source.gd:6-9`），代价来源写明 |
| 2.4 | **60 条 `@rpc` 无一例指定 channel** | `grep transfer_mode\|transfer_channel\|call_local` 全仓 **0 命中**；`@rpc` 声明 **60** 条。例：`core/net/net_bus.gd:234` `@rpc("authority", "unreliable")`（snapshot_world）与 `:255` `@rpc("authority", "reliable")`（match_sync_data），都只有两个参数 | ENet 按通道保序：60Hz 输入与 `claim_role`/`match_sync` 共用通道 0，一次 `bullet_spawn` 重传会顶住其后所有权威事件。★ transfer_mode 的**分工本身是对的**（快照 unreliable、一次性载荷 reliable，`net_bus.gd:232-235/253-255` 注释写明），缺的只是 channel |
| 2.5 | **玩家域靠字符串反射读写**，静态检查全失效 | `scenes/player/player.gd:964` `wc.get("_current_index")`、`:965` `wc.call("equip_index", int(d["widx"]))`、`:968` `live2.set("mag_ammo", int(d["wlive"]))`；`scenes/player/swim_component.gd:31` `tm = float(parent.get("pvp_haste_mult"))` | 根因是根节点**没有 `class_name`**（`scenes/player/player.gd:1` `extends CharacterBody2D`）。同文件别处又是静态点号（`:712` `if by_inst and weapons._current_index >= 0:`），`WeaponComponent` 也确有真方法（`weapon_component.gd:220` `func equip_index`、`:461` `func current_weapon`）⇒ 反射纯属多余，重命名只会**静默失效** |
| 2.6 | **"兜底读宿主真实输入"** 还有 4 处 | `scenes/weapons/weapon_base.gd:223/228/233`（`has_method` 不成立即 `return Input.is_action_*("attack")`）；`scenes/player/swim_component.gd:13-15` `# src=null(冒烟等直接调用)回落真实 Input` → `src = LocalInputSource.new()` | 同类坑本仓**已经踩过一次**并留下注释：`core/net/ai_input_source.gd:63-67` "AI 没有鼠标(服务器 headless),不覆写就会让它去读**宿主机的真实鼠标位置** —— 瞄准变成随服务器桌面而变的随机值"。瞄准修了，攻击/游泳这两处同形状的兜底没修 |
| 2.7 | **菜单没有键盘/手柄焦点入口** | `grep grab_focus\|focus_neighbor` 生产代码 **0 命中**（只有 gitignore 的 `.superpowers/sdd/_gen/*` 里有）；唯一被处理的是返回：`scenes/settings_menu.gd:142` `if event.is_action_pressed("ui_cancel"):` | Godot 不自动点亮首个可聚焦控件 ⇒ 冷启动后 Tab/方向键/手柄一个按钮都到不了。而 `scenes/mp_lobby.gd:506/509` 专门改过 `focus_mode`，说明机制被用过、只是没喂初值 |
| 2.8 | **零 i18n** | `tr("` 全仓 **0 命中**、`TranslationServer`/`tr_n(` **0 命中**、无 `.po/.csv/.translation`、`project.godot` 无 `internationalization` 段 —— 且项目文档**没有一处**把它写成有意取舍 ⇒ 标不了"有理由"。量级：子代理实测 `ui/`+`scenes/` 约 **328** 处中文串面（❓ 该计数我未复核） | 迁进 `.tscn` 后文案又多一种落点；且多条探针**按文案找控件**（`scenes/main_menu.gd:204` 自述 `kh_l4_visual_probe` 按文案找按钮）⇒ 改文案 = 改测试。真要 i18n，得先把探针判据换成 `unique_name_in_owner`/`meta` |
| 2.9 | **无 CI、无聚合回归入口**；判据靠逐脚本自造文本行 | 无 `.github`；`tools/check_naming.py:9` 自称"检查,有违规 → exit 1(CI/本地都能用)"但没人调它。覆盖缺口：`EXPECTED_CHECKS` 只在 **18/152** 个测试脚本里（实测），`tests/lib/probe_base.gd:49-53` 自己写明盲区"**✓ 汇总行 + ALL-OK 并不蕴含'这一组跑过'**"，`tests/smoke/room_sweep_smoke.gd:61` 有实例（"而 verdict **仍是 `SMOKE_ROOM_SWEEP OK`** —— 那一组断言被静默跳过"） | 主流用 GUT/gdUnit4 + CI 拿 JUnit XML 与退出码。★ 本仓**已有**退出码通道：`probe_base.gd:61-64` 真调 `quit(0/1)`，只是文档统一要求"判据取 grep 文本"⇒ 现成通道被浪费。另：`--quit-after` 值实测有 8 种（3600×46、600×6、54000、36000、14400、10800、7200、300），"统一 3600"只活在文档里；11 个 `.sh` **无一**自己 `timeout`（`team_match_probe.sh:4` 那条只是**注释**里教人怎么包） |
| 2.10 | **守卫有盲区，恰好盖住唯一的违规** | `tools/check_naming.py:69-73` 在项目根 `if rel == ".": continue` ⇒ 规则 A（目录名一律小写）**从不检查顶层目录**。实测 `python tools/check_naming.py` 打 `命名检查 OK` 并 exit 0，而顶层就躺着大写的 `DevTools/`（且 `SKIP_DIRS:34` 未收录它） | 正对上本仓自己的硬规则"**守卫能给的保证总是比它读起来少**"。修法：把 `continue` 改成跳过 `rel == "."` 这个**自身**而不是跳过它的子目录 |
| 2.11 | **自订规则被自己违反，且没机制守** | `AGENTS.md:103` 要求 `.ps1` 纯 ASCII+CRLF，而 `tools/gamelog/capture_session.ps1` 有 **49 行非 ASCII**（靠 UTF-8 BOM 侥幸）；`start_server.bat:4` 自称 `This bat is pure ASCII + CRLF`，实际 **7 行中文**；而 `.gitattributes` **只钉了 `*.ps1`** ⇒ 8 个 `.bat` 全按 LF 入库（`git ls-files --eol '*.bat'` = `i/lf`） | 规则只存在于文档；`.bat` 那条从未被机制覆盖。cmd.exe 对角/多行 `for` 块的 LF 容忍度是出了名的差 |

---

## 3. 一致性债：靠纪律而非机制

> ★ **逐条复核结论见 [`conventions-review-2026-10.md`](conventions-review-2026-10.md)**（2026-10-04；43 条全覆盖，含本节每条的"理由是否仍成立 / 档位 / 归属"）。

> ### ★★ 2026-10-04 复核订正（本节以下有 4 处事实错误，已由独立回源码复核发现）
>
> 1. **死镜头常量是 5 个不是 3 个**：除 `cam_lookahead_x`/`cam_lookahead_y`/`cam_deadzone` 外，
>    `core/config/player_params.gd:51-52` 的 `cam_smooth_x`(10.0)/`cam_smooth_y`(8.0) **同样零读取**
>    —— 我先前按"名字命中"数出 3 个，是漏了这两个。（复核方法：在 `*.gd`/`*.tscn` 里排除声明文件后
>    检索这五个名字，命中 **0**；先前看到的"6/2/6/4 次命中"**全部来自文档**，包括本节自己。）
> 2. **`Explosion.make_circle_texture()` 不是"每帧"**：调用点只有
>    `scenes/weapons/weapon_base.gd:211`（武器 `_ready`，即换枪时）与 `core/present/laser_visual.gd:38/42`
>    （每次生成激光视觉）⇒ 它是"**每次调用重建** 16×16 双层 `set_pixel`"，**不属于"每帧白给"那一组**。
>    真正的每帧项只有榴弹的组查询、`watch_hud` 的无脏标记、`enemy_bullet._wrap()` 的组人数查询。
> 3. **"镜像守卫取的是生产值"这句是错的**：`tests/smoke/menu_theme_mirror_smoke.gd:189-190`
>    `F.call("skin_menu_panel", outer, Vector2(64, 46))` 与 `:200` `F.call("header_strip", "标题", 32)`
>    传的是**守卫自己写死的字面量**。它证明的只是"给定 padding 时 Theme 与生产皮逐值一致"，
>    **不证明"生成器与生产同一个来源"**。⇒ 缺口在**入参**而非读取路径，而且**这条订正让原结论更强**：
>    `UiFactory.menu_panel()` 的默认值若从 64/46 改成 96，生成器仍产 64/46、守卫仍传 64/46
>    ⇒ **两处一起静默过期**（双绿而 Theme 已经不对）。
> 4. **★★ 下面那条 `match_combat.gd` 2×2 的"可达性有限"是错的 —— 它在真 PvP 局可达**：
>    `server/match/match_host.gd:46` 接的 `_on_tile_destroyed` 会被**服务器侧的激光**触发 ——
>    服务器进程不实例化 `Level0` ⇒ `Level0.pvp_mode` 恒假 ⇒ `laser_weapon_base.gd:75`
>    `return not Level0.pvp_mode` 判**真**，于是 `:282` 的格级 `damage_tile` 在服务器上也走；
>    而激光枪 id 6 默认不禁用、`server/match/match_ground.gd:34-37` 每局各散 2 把，
>    `_tile_contacts` 只放行 `explosion_destroyable`（树叶/树干正是）。
>    ⇒ **严重度：中 → 高**。后果是**两端口径分裂**：服务器清掉的是**错误的邻格**（本格 16 子格一格没清），
>    客户端按 `pvp_match_client.gd:421-423` 的 `for sy in 4: for sx in 4:` 清对 ⇒ 服务器留幽灵墙。
>    （原文那句"仅 `--test-destroy-tile`（`match_host.gd:205` 注明默认关）"**不成立**。）

- **生成式只做了一半**（`✅`）：`tools/gen_menu_theme.gd:218-221` 手抄了 `UiFactory`
  `body.content_margin_left = 64.0` / `..._top = 46.0`，生产侧唯一来源是
  `ui/factory/ui_factory.gd:305` `static func menu_panel(padding: Vector2 = Vector2(64, 46))`；
  而**镜像守卫**取生产值用的却是 `F.call("skin_menu_panel", outer, Vector2(64, 46))`
  （`tests/smoke/menu_theme_mirror_smoke.gd:190/200`）⇒ 同一份派生逻辑"守卫里有、生成器里没有"。
  `registered-debt.md:28` 还把这条链记为**范本**（★ 2026-10-04 订正：原写 `:24`）。
- **数值三处不符**（`✅`）：黑鸟瞬移真值 `core/config/enemy_params.gd:95-96` = **2~6 格**，
  注释 `scenes/enemies/enemy_black_bird.gd:5` 写 **3~8**，文档 `docs/eng/enemies.md:15` 写 **2~4**；
  冲锋伤害真值 `enemy_params.gd:104` `charge_damage = 7`，注释与文档都写 **6**。
  武器侧同款：`core/config/player_params.gd:78` = **0.6s**，`docs/eng/weapons.md:35` 写 `(2s)`，
  `scenes/player/player.gd:846` 写"没有反馈的**两秒**长按是不可用的"；`scenes/weapons/s686.tscn:11/14`
  = 射程 **1100** / 散布 **3.0**，而 `weapons.md:14` 写 `±5°、射程700`。
- **武器槽位三方不一致**（`✅`）：`README.md:19` 说"`1`~`6` 切枪"，
  `core/net/local_input_source.gd:42` 注释说"5/6 的 InputMap 动作**保留不删**"，
  而 `project.godot` 的 `[input]` 段只定义了 `left/right/up/down/charge/rewind/haste/toggle_barrel/attack/R/F/Q/1/2/3/4`
  ⇒ **既没有 5 也没有 6**（`core/sim/weapon_inventory.gd:31` `DEFAULT_MAX_WEAPONS := 4`）。
  武器表 6 把、槽位 4 个。行为上无害（代码只读 1-4），但两处文档/注释都在骗下一个想开第 5 个位的人。
- **22 块砖硬编码三处**（`✅`）：`core/sim/tile_defs.gd:13` `const MAX_TEXTURE: int = 22`、
  `core/sim/terrain_atlas.gd:29` `const TEX_COUNT: int = 22`、`core/sim/map_catalog.gd:21 const PALETTE := {`
  （键 1..22）。加第 23 块砖时：`terrain_atlas.gd:192` `if tex < 1 or tex > TEX_COUNT: continue`
  把越界纹理**当空气跳过**（不渲染），而 `TileDefs` 侧越界回落"hp1、不可破坏的墙" ⇒ **新砖隐形但仍挡路**。
  无生成器、无守卫。
- **`MAP_WIDTH/HEIGHT` 两个写者、两条推导、零断言**（`✅`）：
  `core/config/game_parameters.gd:32` `func refresh_map_size()` 读**地图文件**；
  `core/sim/world_builder.gd:18` `GameParameters.MAP_WIDTH = grid[0].size() * GameParameters.TILE_SIZE`
  读**已加载网格**。目前靠后者兜住漏调、反而**掩盖**了前者（子代理逐点核过 10 处生产 `set_map_file`）——
  ★ **2026-10-04 复核订正**：原写的「当前无漏调」**不成立** —— `server/match/match_host.gd:39` 的
  `MazeGenerator.set_map_file(map_path)` 后面**没有** `refresh_map_size()`，靠 `:41` 的
  `WorldBuilder.load_grid()` 覆写 `MAP_WIDTH/HEIGHT` 兜住 ⇒ 读作「**漏了，但被兜底掩蔽**」
  （10 处生产点里唯一一处）。纯属"调用者义务"，无任何断言/编译期保证。
- **碰撞层全是裸数字**（`✅`）：`project.godot` 全文 `grep layer_names\|2d_physics` **0 命中**。
  实例：`scenes/player/player.tscn:124` `collision_layer = 2` / `:125` `collision_mask = 5`；
  `scenes/enemies/enemy_base.gd:90` `area.collision_mask = 2  # 检测玩家(layer 2)`。
  全仓只有第 5 层具名（`server/hosts/team_host.gd:31` `const TEAM_ENEMY_LAYER := 16`）。
  层义只活在散文（`docs/eng/world.md:48`）与冒烟断言里 ⇒ 改层要扫 20+ 处 `.tscn`/`.gd`。
- **一处改动被静默覆盖**（`✅`）：`core/present/menu_fisheye.gdshader:72`
  `uniform float blur_radius = 6.0;` 带注释"★ 2026-10-04:4.0 → **6.0**（用户「高斯模糊也再强一点」）"，
  但 `scenes/main_menu.gd:80` `const BG_BLUR_RADIUS_PX := 4.0` 在 `:276`
  `mat.set_shader_parameter("blur_radius", BG_BLUR_RADIUS_PX)` 每屏覆盖它；而该 shader **只被 main_menu 用**
  （grep 确认）⇒ **10-04 那次"模糊再强一点"从未生效**。
- **`CollisionBuilder` 头部注释与自己的常量相反**（`✅`）—— ★ **2026-10-04 已修**:头部注释原写
  "从 125×75 网格展开成 250×150 的 **32px** 子格(每 64px 格 → **2×2**)"，而 `:13` 的常量是
  `SUB_TS = 16  # 16px 子格(cyrm v4:64px 格 → 4×4)`。现已改成 16px/4×4。
  **这条注释过期确实咬到人了（同一闭环，已一并修）**：`server/match/match_combat.gd` 修的**修前**是
  ```
  		for qy in range(2):
  			for qx in range(2):
  				destructible_sub[cell.y * 2 + qy][cell.x * 2 + qx] = MazeGenerator.EMPTY
  ```
  —— v4 子格表已是 4×4（同文件 `:25` 的正确写法是 `Vector2i(sub.x / 4, sub.y / 4)`），修前清到了别处、
  真砖一格没清。★ 严重度**已在 §3 顶部订正块第 4 条改为高**（可达性**不**限于 `--test-destroy-tile`：
  真 PvP 局里服务器侧激光走格级 `damage_tile` 就能触发）；现已修为 `match_combat.gd:18-22` 的 4×4，
  并有 `destroyed_cells_probe` 相③ 守卫。
- **`docs/eng/world.md:9` 与源码相反**（`✅`）：文档写"游戏侧读的只有 v3 文本与旧字母格式两种
  （编辑器**写**的是 v4 二进制，**游戏还读不了**）"，而 `core/sim/map_format.gd:89`
  `static func is_v4(path: String) -> bool: return MapFormatV4.is_v4_data(_read_bytes(path))`
  与 `core/sim/world_builder.gd:16` `MapFormat.load_subgrid(...)` 明摆着在读 v4。
- **第二份环面数学**（`✅`）：`core/sim/grid_pathfinder.gd:7` 自述"★ **改这里 = 改环面数学/寻路**"，
  而 `scenes/enemies/enemy_fly_bird.gd:384` `if absf(dx) > GameParameters.MAP_WIDTH * 0.5:` /
  `:385` `dx = -signf(dx) * (GameParameters.MAP_WIDTH - absf(dx))` 手抄了同一式子（全仓仅此一处）。
- **文档与源码不符（相机）**（`✅`）：`docs/eng/render.md:9` 写"相机 `camera_2d.gd` **带前瞻/死区**"，
  而 `core/present/camera_2d.gd:25-33` 是 `_process` 里直贴：
  `_base_pos.x = target.global_position.x` / `... = target.global_position.y + PlayerParams.cam_y_bias`，
  无前瞻、无死区、无平滑。
- **每帧白给**（`✅`）：
  - `scenes/weapons/bullet_base.gd:78-79` → `:215-216` `for group in CONTACT_GROUPS: for n in tree.get_nodes_in_group(group):`
    —— 引信点燃前**每物理帧、每颗榴弹**两次组查询并各分配一个 Array。同仓 `scenes/enemies/enemy_base.gd:37`
    自己写着正确做法："玩家组每帧缓存:同一物理帧内 `_players_frame()` 只建一次数组,砍掉每帧每敌多次
    `get_nodes_in_group` 分配。"
  - `ui/watch_hud.gd:126/134/135/145`：`_process` 里无条件 `_big.text = …` +
    `add_theme_color_override` + `_cap.text = …` + `queue_redraw()`。同仓正确写法 `ui/hud/hud.gd:128`
    `if low != _ammo_low:`。
  - `core/sim/explosion.gd:129-138` `make_circle_texture()` 每次调用都 `Image.create` + 双层
    `set_pixel` 循环 + `ImageTexture.create_from_image`（无缓存）；对照 `scenes/effects/tile_hit_fx.gd:5-13`、
    `water_fx.gd:7-15` 都有 `static var _tex` 缓存。
  - `scenes/enemies/enemy_bullet.gd:71` `if get_tree().get_nodes_in_group("player").size() >= 2:`
    —— 既每帧分配，又把"我是权威服务器"押在**组人数**上（语义脆弱：人数≠权威）。
- **死代码 / 死默认值**（`✅`）：
  - `core/net/net_bus_ext.gd:39-43` 的 `signal local_beam_fired` + `@rpc beam_fired` 是死的重名协议面
    （真发送端走 NetBus：`pvp_game.gd:78` `NetBus.local_beam_fired.connect(...)`；仓库自己在
    `net_bus.gd:280` 与 `pvp_match_client.gd:882` 两处注释警告"别在 NetBusExt 里再加一份…挂错节点的 = 静默 no-op"）。
  - `core/net/net_bus.gd:55` `var is_server_mode: bool = false` 三次赋值（`:76/84/89`）**零读取**。
  - ★ 2026-10-04 订正文档时新发现：`core/config/player_params.gd:48/49/53` 的
    `cam_lookahead_x`(100.0) / `cam_lookahead_y`(80.0) / `cam_deadzone`(8.0) **全仓无人读** ——
    `core/present/camera_2d.gd`（37 行）里一次都没出现，只在声明处出现。三个**看起来像已实现的调参**
    其实是死常量；而 `docs/eng/render.md:9` 原先那句"相机 `camera_2d.gd` **带前瞻/死区**"正是照着
    参数名写出来的（已按源码订正）。
  - `scenes/enemies/enemy_fly_bird.gd:15` `var _max_hp: int = 20` 立刻被 `:48` `_max_hp = hp` 覆盖，
    场景真值 `scenes/enemies/enemy_fly_bird.tscn:174` `hp = 25`（它决定冲锋阈值 `:394`）。
  - `scenes/enemies/enemy_base.gd:93` `rect.size = Vector2(44, 40)` 被 `enemy_jump_bird.gd:33` `Vector2(44, 36)`、
    `enemy_black_bird.gd:70` `Vector2(46, 36)` 在 `_ready` 换掉。
  - `ui/factory/ui_factory.gd:626` `static func line_edit(...)` **零生产调用**（只有 gitignore 的
    `.superpowers/sdd/_b2_backup/*` 与一条过期注释 `tests/harness/rejoin_watcher.gd:329`）。
- **调色板纪律在声明它的文件里破一次**（`✅`）：`scenes/mp_lobby.gd:482`
  `fsb.bg_color = Color(0, 0, 0, 0)   # 只画线、不画底(底在外层 Button 上)`，
  而 `:435` 写着"这里只引用,不写字面量"，具名 token 早在 `ui/factory/ui_factory.gd:148`
  `const C_TRANSPARENT := Color(0, 0, 0, 0)`（`:146-147` 的注释正为"必须显式透明"而立）。
  调色板守卫只扫 `.tscn` 节点属性 + `.gd` 侧的 `C_PLATE` ⇒ **这处没守卫看得见**。
- **房卡宽度两套真相源**（`✅` 引用自同文件注释，`:524` 的公式行未逐字复核）：
  `scenes/mp_lobby.gd:25-26` 自认"于是同一件事有两个来源:**这里的公式** 与 `.tscn` 里 `CardGrid` 的
  `offset_left/right` + `h_separation`;改一个就要改另一个,否则卡片与网格错位(**而不报错**)。"
  而迁移的**目的**正是"在编辑器里拖得动"—— 拖一下 `CardGrid` 就静默错位。
- **`archive_build.py` 头部与实现相反**（`✅`）：`:7-18` 承诺"里面是一个**完整的发布目录**（六个文件
  平铺在同一层,这是硬要求）""`Packet.dll` ★ core **静态导入**它,少了它进程根本起不来""缺哪个这里会
  点名(**不静默**)"；实测 `builds/RoF_v0.5.0_202610040210/` 只有 2 个 exe，`EASYTIER_DIRS:57`
  **定义后从未被引用**（grep 确认），而同文件 `:56` 又写"不再携带 EasyTier"。
- **枚举型文档漂移**（`✅`）：`tests/README.md:10` "三个独立诊断工具:`convert_map.gd` / `seam_analyze.gd` /
  `seam_screenshot.gd`" —— 实测 `tests/scripts/` 有 **4** 个（多 `convert_map_v4.gd`）；
  `.gitignore:58-59` 提到的"根上那个 `.gdignore`"**不存在**（`find` 只找到 `.godot/.gdignore`
  与 `_crashtest/.gdignore`）—— ★ **2026-10-04 后记**：`_crashtest/` 已按 §9 的裁定**整个删除**（101MB 清理），
  今天 `find . -name .gdignore` 只剩 `./.godot/.gdignore` ⇒ 这句订正自己**只剩一半成立**；`.gitignore:58-59` 同句同病，待同步。
- **`ui/hud/royale_hud.gd:141`** 每帧重排同一串时间：
  `_timer_label.text = "剩余时间  %d:%02d" % [...]`（秒数没变也写）。

---

## 4. 有理由的偏离 —— **不要误改**

> ★ **逐条复核结论见 [`conventions-review-2026-10.md`](conventions-review-2026-10.md)**（2026-10-04；本节多数条目的"理由"已在复核里被**降级/推翻**，别照本表直接当"有意取舍"）。

> ### ★★ 2026-10-04 复核订正：本表的"理由"必须区分三种出处，原文把它们混为一谈
>
> **① 源码/仓内真有的理由** · **② 只活在本报告里的理由（那是我的判词，不是仓里的理由）** ·
> **③ 已经过期的理由**。混为一谈的后果是：`§10` 的裁定要求"逐条重新考虑"，而有些条目**根本没有可考虑的仓内理由**。
>
> | 条目（**# = §4 表内第 N 行**；★ 原表编号错位，已按表内实际行序订正） | 出处判定 |
> |---|---|
> | 1 手写预测/回滚 | **②+挂错对象**：`cyancular_build_profile.gdbuild:91-92` 确实列了 `MultiplayerSpawner`/`MultiplayerSynchronizer`，但"因此用不了引擎复制节点"**只在自编译模板下成立** —— `export_presets.cfg:31 custom_template/release=""`，靠 `RELEASE.md:149-151` 覆盖全局 `%APPDATA%\…\windows_release_x86_64.exe` 生效（模板被官方盖回即失效，`RELEASE.md:168` 已记该故障）。仓内对这俩节点 **0 引用**，也 **0 处注释**写"因此手写" |
> | 2 双 autoload | **③ 已过期**：`net_bus_ext.gd:4-6`「原 NetBus 保持与原版逐字节一致」今天为假 —— 自建 Ext 那次（★ 订正出处：Ext 的创建提交是 `e7b53fd`「搬入 NetBusExt 扩展协议收口节点」（2026-09-10）；原写的 `716b6fc`（2026-09-15）是 `core/` 分目录**搬家**）之后 `net_bus.gd` **一直在改** —— **保守下界**：从搬家那次 `716b6fc..HEAD` 起仍有 **6 次**（`git log --oneline 716b6fc..HEAD -- core/net/net_bus.gd`）、**+132/−1**，并**插进 2 条 `@rpc`**（`:282`→`weapon_spawned`、`:286`→`weapon_removed`；`func` 在 `:283`/`:287`）—— 正是头注预警会"RPC 全部失联"的那种改动。分离还已生出雷：`net_bus_ext.gd:39-43` 那对 `beam_fired` 零消费者，逼出两条防呆注释（`net_bus.gd:280`、`pvp_match_client.gd:882`）。兼容对象**仍在**（`pvp_session.gd:12` 默认云服 `120.53.107.140`、`README.md:33`） |
> | 9 `rendering/mobile` | **② 无仓内理由**：3D 节点 0、`hint_screen_texture`/`SCREEN_TEXTURE`/`BackBufferCopy` 0 命中（事实），但**没有任何一处写"为什么"** ⇒ **不满足"有理由"判据**（原文自己也这么写，与本表表头自相矛盾）。另：`gdbuild:3 disable_3d: true` ⇒ 发布模板本就摘了 3D，该设置对发布版近乎惰性 |
> | 10 SubViewport 2208×1728 | **② 半截**：2208×1728 只出现在 `scenes/level_0.tscn:13`，仓内**无注释解释 2×144**；"裁剪后逐像素恰 1 texel"可由 `post_process.gd:17-18 crop_scale` 推出，但"**+38% 填充写明**"**全仓（含 docs）查无出处** —— 那是我的算术。唯一**写明**的放大理由是另一件事（`post_process.gdshader:27-28` 世界视口大于窗口 ⇒ 鱼眼边缘无黑边） |
> | 17 `env.sh` 三条理由 | **③ 条数已过期**：`env.sh:13-14` 写 `set -e` 3 个 / `set -u` 5 个，实测 **2 / 8**（10 支脚本）。且"`[7800,8300)` 不扫"**只对池外两支成立**（`rejoin_probe.sh:30`、`team_match_probe.sh:35` 明文承诺），而 `pvp_match_smoke.sh:12/41`、`royale_soak_probe.sh:28/42` **照样扫该区间**（靠 `lobby_alive` 把关）⇒ **与 [`AGENTS.md`](../../AGENTS.md) §1 那句「绝不扫 `[7800,8300)`」直接矛盾** |
> | 其余各条：3 端口池 · 4 杀端口 · 8 squash 常量 · 11 61MB · 12 取景 150% · 13 绝对定位 · 14 生成器 · 15 `allscript_probe` | **① 源码/注释真有的理由，复核后仍成立**（细节与代价见本轮复核记录）。★ 但 13（绝对定位）的"无需重排"前提**已被 §10 的裁定推翻** —— 一旦 §1.4 让窗口可缩放/加全屏，这条理由当场失效 |


这些**看着不合主流，但注释/文档写明了理由**，判定为有意取舍：

| 偏离 | 理由出处 |
|---|---|
| 手写预测/回滚，不用引擎 `MultiplayerSynchronizer` | `cyancular_build_profile.gdbuild:91-92` 明列 `MultiplayerSpawner`/`MultiplayerSynchronizer` 为**禁用类** ⇒ 发布版结构上就用不了引擎复制节点 |
| `NetBus` + `NetBusExt` 双 autoload | `net_bus_ext.gd:3-8`「原版 NetBus 逐字节不动,扩展全放本节点」 |
| worker 端口池 7800 + 500 | `worker_launcher.gd:20-21` 单一来源；`pick_port` 唯一递增 + 占用集合，且写明为何不用 bind 探测。未见竞态 |
| 杀端口清残留 | `proc_util.gd:5-9`（旧进程占 7777 → 新实例闪退），并已立人工纪律（AGENTS.md 要求先查 `lobby_alive`） |
| 不承担反作弊（无 DTLS、join 无限速、令牌明文） | `lobby_rooms.gd:233`「**不防**恶意爆破(本设计不承担反作弊)」；`gdbuild:22` `module_mbedtls_enabled: false` 是裁剪换体积 |
| cyrm v3 只读分支保留 | `docs/2026-09-20-cyrm-v4-handover.md:241` 明写作为**只读迁移入口**；现存两图均已是 v4 |
| 环面上的浮点边界（`wrap_to_range` 单次加减、恰好半图不动） | 已实测正确；A*/LOS 调用点都先经 `cell_of`（posmod）规整 |
| squash 8 个同名常量重复 | `core/config/player_params.gd:98-101` 自陈"两份的漂移是真隐患"，由 `squash_stretch_smoke` 逐名钉住 |
| `rendering/mobile`（2D 游戏用移动渲染器） | 全仓零 3D 节点、不依赖屏幕纹理/后缓冲。★ 但**没有任何一处写"为什么"**，属"无理由的有意选择" |
| 2208×1728 的 SubViewport 尺寸 | 像素精确（1920+2×144 / 1440+2×144），裁剪后逐像素恰 1 texel、不重采样；代价 +38% 填充写明 |
| 地形图集常驻 61MB 显存 | 已登记（`handoff-2026-10-03.md:80`、`terrain_atlas.gd:19,163-165`），缓解=只缓存纹理不缓存 Image |
| 菜单取景 150%（2.25× 非整数） | `main_menu.gd:54-59` 与 `menu_fisheye.gdshader:31-34` **两处**写明"留给用户定"，且不涉及局内 |
| 固定视口下的绝对定位 | `1920×1440` + `resizable=false` ⇒ 无需重排；★ **订正（出处挂错对象）**：原写「计划『已知边界 2』已登记」，而 `docs/` 里"已知边界 2"只存在于本行自己（UI 计划「已知边界」第 2 条是"`.tscn` 魔数不会消失"，与绝对定位无关）—— 真正的登记在 [窗口与显示设置计划](../superpowers/plans/2026-10-04-window-and-display-settings.md):5/82（"不改任何一处版式……绝对定位逐像素不变"） |
| 生成器产出 `.tscn` 不入库、无 `--check` | `tools/gen_menu_scene.gd:54-61` 明写覆盖上限（"只保证同一份代码建出来的树 == `.tscn`"） |
| `allscript_probe` 排除点目录 + 条数下限 | `allscript_probe.gd:24-35` 写明数法与"别降级成 `<`"的理由 |
| 「退出码不可作判据」 | `probe_base.gd:49-53` + `room_sweep_smoke.gd:58-63` 的具体事故；★ 但这条被**过度概括**了，见 §2.9 |
| `env.sh` 不设 `set -e/-u`、按端口杀、`[7800,8300)` 不扫 | `env.sh:12-14/39-40/52-63` 三条都写明理由 |

---

## 5. 未验证 / 覆盖上限（别当已证事实）

1. ❓ §1.4：1920×1440 窗口在 1080p 屏上走"超出屏幕"还是"被 OS 钳制成 0.75× 非整数放大"——
   未运行引擎。
2. ✅ **已销(2026-10-04)**:§1.1 幽灵砖**已实机复现 + 已修** —— `tile_collision_probe` 的相③b 在修复前红在
   `相③b 格级销毁后仍有 16/16 子格在画(幽灵砖)`;修复后 `TILE COLLISION PROBE: ALL-OK`(含「格级销毁无幽灵砖」)。
   服务器侧同期修了两处:4×4 清格子格坐标(`* 2` 清到了 `(x/2,y/2)` 的右上象限)、以及每局复位漏 `init_sub_hp`
   (⇒ 下一局"客户端有墙、服务器没有")。详见 [`plans/2026-10-04-tile-destruction-consistency.md`](../superpowers/plans/2026-10-04-tile-destruction-consistency.md)。
3. ❓ 地形层缺 `texture_filter`：`scenes/level_0.tscn` 里 `WallLayer`/`WaterLayer`/`WaterSurfaceLayer`
   **无**该属性（该文件仅 `:21` 处有 `texture_filter = 1`，那是 **Player** 节点），
   而 `player.tscn:131`、`bullet.tscn:19` 等精灵全是 `1`(NEAREST)，`project.godot` 又没设
   `default_texture_filter`。仓库自己的判据是 `ui/map_picker.gd:103`
   `tr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST   # 像素风:禁止线性糊图`。
   ❓ 引擎默认滤波值（按 4.x 出厂线性判断）与实际可见性**均未在本机核实**。
4. ❓ §2.2/§2.3 的延迟与积压量级取自代码注释里的自测值，未复测。
5. ❓ §2.8 的 328 处中文串面计数来自子代理，我未复核（但"零 `tr()`/零 `.po`"已复核）。
6. ❓ `docs/pvp-networking.md:160` 写"快照（**30Hz** unreliable）"而
   `server/match/match_state.gd:98` `const SNAPSHOT_INTERVAL := 1.0 / 60.0   # 60Hz 快照…30Hz 太卡`
   —— 文档过期已复核，但"文档里其它处是否还有同类过期数字"未穷举。
7. 覆盖面：本次**没有**逐行审 `tests/harness/*_watcher.gd`（1600+ 行的真链路观察者）、
   `level_editor/`（12 个 JS，只做了"无外部依赖/有 node 冒烟/有自检按钮"的结构核对，未审逻辑）、
   `docs/` 全部 134 份 md 的内部一致性。
8. **全程只读**：未运行 Godot、未跑任何测试（遵循 AGENTS.md「跑测试前先问用户」）。
   第 1、2 节里标 ⚠ 的条目若要转成"已修"，得先按本仓分档补验证。

---

## 6. 审计过程的两处纠错（说明为什么值得交叉复核）

1. **"mojibake 键 ⇒ 文件日志整条关闭"是错的。** UI 域初判如此；实测 `logs/` 里有导出客户端
   （02:11，`build_release.py` 的产物冒烟，无 `--log-file`）刚写的轮转日志，且官方文档与上游 commit
   都说桌面端默认开启 ⇒ 实际损失**只有配额**（§1.2）。
2. **"tests/ 是否真进 .pck 未证实"应升级为已证实。** 工程域初判留了余地；直接对 exe
   `grep -a -o 'res://tests/…'` 得 **336** 条，且同批数据证明 `exclude_filter` 对资源有效（§1.3）。
   另修正一处行号：`UiFactory.apply_font_recursive` 的调用点是 `scenes/lobby_page.gd:65`（非 :70）。

---

## 7. 建议批次（按"小而独立 + 能配一条守卫"排序）

1. **§1.1 幽灵砖**：Level0 补格级回调（或激光改走 `damage_sub`）+ 一条"逻辑/子格/渲染三者一致"的探针。
   档 2。
2. **§1.2 `[debug]` 键**：删 `:35-36`、按 `6b5f3fb` 补回三条真键 + 一条"键名必须匹配 `^[a-z_]+/`"的守卫。
3. **§1.3 发布包瘦身**：`exclude_filter` 加 `tests/*,tools/*,DevTools/*`；同时决定
   `tests/smoke/menu_autotest.gd` 这个"生产依赖测试文件"该怎么办。
4. **§2.10 命名检查盲区**：一行修（顶层目录也要过规则 A）+ 决定 `DevTools/` 的去向 —— 今天有三条路：
   改名小写 / 收进 `SKIP_DIRS` / **`git rm` 出库**（★ 2026-10-04 新证据：那 3 个文件**是已入库的**，
   且会进导出包，见 §1.3 的订正）。
   （该文件的注释要求"这张表必须与 `.gitignore` 对齐"）。
5. **§2.9 最小回归入口**：`tests/run_gate.sh`（`check_naming.py` + 纯逻辑 `-s` 批 + 聚合判词），
   把 `probe_base.gd:61` 现成的 `quit(1)` 当判据用起来。

**登记建议**（本文件不改这些文件，由人裁定）：可行动的条目逐条搬进
[`registered-debt.md`](registered-debt.md)（它仍是唯一欠账清单）；若本文件要长期保留，
可把 `docs/eng/audit-*.md` 加进 `tools/check_naming.py` 的 `DOC_FILES`，让"引用的路径必须存在"也覆盖它。

---

## 8. 主流基线引用

- 渲染器选择：<https://docs.godotengine.org/zh-cn/4.x/tutorials/rendering/renderers.html>
- 多分辨率与 stretch 模式：<https://docs.godotengine.org/en/stable/tutorials/rendering/multiple_resolutions.html>
- 自动加载 vs 普通节点：<https://docs.godotengine.org/en/stable/tutorials/best_practices/autoloads_versus_internal_nodes.html>
- GDScript 风格指南（命名）：<https://docs.godotengine.org/en/stable/tutorials/scripting/gdscript/gdscript_styleguide.html>
- 日志（默认 5 份 / 桌面默认开）：<https://docs.godotengine.org/en/stable/tutorials/scripting/logging.html>
- 上游「桌面默认开启文件日志」commit：<https://github.com/godotengine/godot/commit/20af28ec0651da256e2c9ccefc868ea028c73a4a>
- 导出工程：<https://docs.godotengine.org/en/stable/tutorials/export/exporting_projects.html>
- 权威服务器多人实践（对照 §2.2/§2.3/§2.4）：<https://www.strayspark.studio/blog/godot-4-multiplayer-networking-authoritative-server>
- gdUnit4 的 CI 与报告（对照 §2.9）：<https://godot-gdunit-labs.github.io/gdUnit4/latest/faq/ci/>

---

## 9. 附：本次磁盘清理记录（2026-10-04，用户裁定后执行）

| 对象 | 体积（前） | 处置 | 说明 |
|---|---|---|---|
| `.claude/worktrees/{3v3-fixes,cyrm-v4-editor,kh-merge}` | **1.1 GB** | **`git worktree move` 到仓库外** | 三个 worktree 搬为 `E:/Workspace/godot/wt-*`（与既有的 `wt-base` 同处）。搬前逐个查过 `git status`：**三个都 clean、零未提交**。★ 为什么不是 `rm -rf`：它们是 git worktree，目录删掉只在 `.git/worktrees` 里留僵尸登记，得再 `git worktree prune`。搬完 `.claude/` 从 1.1 GB → **20 KB**（只剩 `settings.local.json`），也顺带解除了对 Godot 导入面的污染 |
| `_crashtest/`（109 个文件） | **101 MB** | **删除** | 构成：两个临时导出 exe 各 41MB（可再生）+ `dis_7M.txt` 18MB（反汇编 dump）+ ~1MB 的 83 份日志/结果。★ **代价照实记**：18 份入库文档里出现过 `_crashtest/…` 的**历史跑法配方**（如 `./_crashtest/CyancularClient.exe --log-file …`），从此不可复跑；被 C1 分析点名为证据的 `_run1_prefix.log` **不在**这里（在 `.superpowers/sdd/`，未动） |
| 仓库根 `.hud.bak` / `_k6.bak` / `_exportprobe.log` / `.round1_run1_FIXFAIL.log` | ~95 KB | **删除** | 全部 gitignore，且无任何入库文档引用（逐名 grep 过） |
| `DevTools/` | 10 KB（3 个文件） | **未删（已恢复）** | ★ 见 §1.3 的订正：它**是已入库的**，我最初"未入库残留"的判断是错的。`git checkout -- DevTools` 已还原，去向待用户裁定（keep / `git rm` / 搬出仓库） |
| `builds/` + `releases/` | 85 MB + 506 MB | **保留** | 归档策略：`releases/` 按设计"每次发布沉淀一份、不清理" |

---

## 10. 用户裁定（2026-10-04）—— 本节**取代 §7 的排序**

用户对 §1/§2/§3/§4 逐类下了决定，照抄如下（这是后续所有动作的口径）：

| 范围 | 裁定 | 本文档此后的处理 |
|---|---|---|
| **§1（A1 幽灵砖 / A2 `[debug]` 键 / A3 发布包打进 tests / A4 不可缩放无全屏）** | **都得做** | 四条全部从"发现"升级为"待实施"；实施时按 §0 的分档走（A1 档 2、A2/A3 档 2~3 视改动面、A4 档 1） |
| **§2.7（菜单无键盘/手柄焦点入口）**、**§2.8（零 i18n）** | **记录而不修改** | 保留原文，**不实施**、不改代码；§7 里不列为候选。★ 它们仍是"与主流冲突"的事实，只是这一轮不做 |
| **§3（一致性债）** | **全部重新考虑** | ★ **订正（条目归属）**：原表此格把 §4 表内的两条（①`cyrm v3 只读迁移入口` ②`不承担反作弊`（无 DTLS / join 无限速 / 令牌明文））误写成 §3 的例外 —— §3 里**没有**这两条 ⇒ §3 条目的"有理由/已完成"判定**全部作废**，按"待重新评估"处理（两条例外归下一行） |
| **§4（有理由的偏离）** | **除两项外全部重新考虑** | 只有 `cyrm v3 只读入口` 与 `不承担反作弊` 两条维持"有理由"；其余各条（手写预测/回滚、双 autoload、端口池、杀端口、squash 常量重复、`rendering/mobile`、2208×1728、61MB、取景 150%、绝对定位、生成器无 `--check`、`allscript_probe` 排除项…）**都要重新评估是否仍成立**，不得再以"文档里写了理由"当作结论 |

★ **用户给出的优先级**：**先把"旧版本表述"清除与封存**（否则接手的人会绕很多路）—— 本文件的 §9 是清理记录，
`docs/archive/` 是封存区（纪律见 [`docs/archive/README.md`](../archive/README.md)）。

### 10.1 本轮"旧版本表述"处置的收口（2026-10-04）

| 项 | 处置 | 结果 |
|---|---|---|
| 活文件里的旧版本号（`RELEASE.md` 6 处 / `CLAUDE.md` / 三个 tools 的用法示例 / `check_naming.py` 注释） | **清除**（去掉历史枚举与旧版示例，只留"真相源一处 + 别在文档里另抄"） | 已改 |
| `claude-md-full-2026-10-02.md`（295 KB，拆分前 `CLAUDE.md` 全文）、`kh-line-log.md`（46 KB，原 `AGENTS.md`） | **封存**进 `docs/archive/`（`git mv`，附封存纪律，两处指针改写） | 已做 |
| 其余 dated 交接/报告（09-17 三份、09-28 batch-b、royale-soak、c2-retrospective、naming-cleanup-plan）与 `docs/superpowers/{plans,specs}`（105 份 / 4.1 MB） | **不封存**（用户裁定"到此为止"） | 不动 |
| `docs/2026-09-20-cyrm-v4-handover.md` | **不封存** —— 它仍是 `AGENTS.md` §4 指定的 cyrm 格式权威指针（被引 5 次） | 不动 |
| **另两条版本线的提及**（`AGENTS.md` §0 / `RELEASE.md` / `archive_build.py` 里的 `KH_v0.5.0_B17`、`siri_v0.5.0`） | **保留** —— 用户："这些是**其他开发者的版本**，即使我们目前已经是最新版本了，我认为依然要留着" | 不动（`release_prefix` 的多线机制是现行机制，前缀真相源在 `project.godot`） |
| §3 里点出的 **26 处 `CLAUDE.md:<行号>` 死指针** | **实测全部落在 `docs/superpowers/plans/*`（历史 plan），活文档 0 处** ⇒ 按"只修活文档"的裁定，**本轮无动作**（历史 plan 是快照，改它等于篡改记录） | 不动；★ 但"活文档禁引行号"这条**未**入纪律（用户未选该项） |



