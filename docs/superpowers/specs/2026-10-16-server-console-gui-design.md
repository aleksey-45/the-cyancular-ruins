# 服务端控制台(Server Console)设计

> 2026-10-16 · 状态:**已定稿(含同日订正,见下)** · 范围:给 headless 的 PvP 服务端 exe 加一个**进程内运维面板**。
> 设计已经过逐段认可,并用**真 Theme + 真字体渲染真图**验收过(不是示意图)。
> ★ 本文的**数字都是实测值**;与源码冲突以源码为准。
>
> **2026-10-16 订正(写实施计划时被实测推翻,不是设计变更)**:
> ① `-s` 冒烟里 **autoload 标识符在编译期就解析不到** ⇒ 数据层必须 autoload-free、**不能引用 `LobbyRooms`**;
> ② 大厅**拿不到局内在线 / 掉线宽限信息**(成员转连 worker 后 `players` 为空,grace 只在 worker 的
>   `GraceWindow` 里)⇒「在线人数」与「掉线宽限中」两个 UI 状态**撤掉**,换成大厅能证明的量(见 §5.6 / §6.1)。

---

## 1. 为什么做

服主"开服"的完整动作是**双击 `Cyancular Ruins Server.exe`**(不用 `start_server.bat`;客户端的
「启动/重启本机服务器」按钮走的也是同一条:`core/net/local_server.gd:44` 无参拉起)。今天得到的是一个
cmd 控制台窗口,而运维最需要的三件事都看不见:

| 需要 | 今天 |
|---|---|
| 有几间房、谁在里面、哪一间在打 | 只能从 `房间 4821 创建` 这类**逐行 print** 里拼 |
| 每局 worker 的端口/进程**还**活着吗 | 只能从 `[lobby] spawn worker pid=… port=…` 里拼,**没有"现在"** |
| 关掉一间卡住的房 | **没有这个手段**;只能整进程重启(`LocalServer.restart()` 会 taskkill 全部) |

额外的具体痛点:worker 是独立进程,**stdout 父进程看不到**(Windows `CreateProcess` 不继承句柄,
`server/lobby/worker_launcher.gd:57-62`),只能去 `user://logs/worker_<端口>.log` 翻文件。

---

## 2. 硬约束(每条都有出处)

### 2.1 引擎级:今天的服务端 exe **永远开不出窗口**

`dedicated_server=true`(`export_presets.cfg:83`)会让导出器加一个 custom feature
(`editor/export/dedicated_server_export_plugin.cpp:72-74`),而引擎在启动早期**无条件**覆盖显示驱动:

```cpp
// godot-4.7.1-src/main/main.cpp:2285-2288
if (ProjectSettings::get_singleton()->has_custom_feature("dedicated_server")) {
    audio_driver = NULL_AUDIO_DRIVER;
    display_driver = NULL_DISPLAY_DRIVER;
}
```

覆盖点在**命令行参数解析之后** ⇒ 传任何开关都改不回来。**这不是"没人写 UI",是产物结构决定的。**

### 2.2 两条 Godot 布局事实(读源码得来,不是猜的)

- `scene/gui/scroll_container.cpp:43-101`:`vertical_scroll_mode = AUTO`(默认)时 `min_size.y` **恒为 0**
  (只有 `DISABLED` 与 `MAXIMIZE_FIRST` 两个分支才设它);
  `MAXIMIZE_FIRST` 时 `min_size.y = MIN(内容最小高, custom_maximum_size.y)`。
- `scene/gui/control.h:276,630`:`custom_maximum_size` / `get_combined_maximum_size()` 在 4.7 存在。

⇒ 于是有**原生**答案,不必手写高度:日志用 `AUTO` + `EXPAND_FILL` 吃掉全部余量;房间表用
`MAXIMIZE_FIRST` + `custom_maximum_size.y = 6 行`(房少收缩、超过 6 行才滚)。

### 2.3 仓内约束

| 约束 | 出处 | 对本案的含义 |
|---|---|---|
| 裁剪模板 `disabled_classes` 关掉 `Panel` / `Tree` / `ItemList` / `TabContainer` / `SplitContainer` / `SpinBox` / `CodeEdit` / `ColorPicker` | `cyancular_build_profile.gdbuild:43-124` | 面板只能手搓行(`PanelContainer` + `Label` + `Button` + `ScrollContainer` + `RichTextLabel`)——恰好也是 `UiFactory` 那套;**用了被裁的类只会在导出产物里炸**(`RELEASE.md:170`) |
| `module_regex_enabled:false` | 同上 + `AGENTS.md:204` | 进导出包的脚本**禁用 `RegEx`** |
| 两预设都是 `all_resources` + exclude `tools/*,tests/*` | `export_presets.cfg:11-13,85-87` | 面板必须落在 `server/` 下(`tools/` 不进包);且**要加进客户端预设的 exclude**,否则管理面会随客户端一起发出去 |
| 大厅入口节点 `set_process(false)` | `server/server_main.gd:125` | 面板**不能**指望入口的 `_process`(RoomManager 能 tick 是因为那行只关自己) |
| 端口/房间拆除只有一个收口 | `server/lobby/lobby_rooms.gd:820` + `tools/room_sweep_lint.gd` | 面板的"关房"**必须**调 `teardown_room`,不许自己动注册表 |
| `Settings.apply_display()` 只在 headless 早退 | `core/config/settings.gd:113` | **非 headless 下服务端窗口会按玩家存档改尺寸/全屏** —— 必须处理 |
| 字号只有 16/32/48;颜色只许来自 `UiFactory` | `docs/eng/ui.md:14-20`、`ui_factory.gd:19` | 见 §5.3 |
| 观感/版式不写自动化守卫 | `AGENTS.md` §2 表末行 | 见 §9 |
| **`-s` 冒烟里 autoload 标识符不可解析** | 本轮实测:`Compile Error: Identifier not found: NetBus`(`lobby_rooms.gd:120`) | 数据层必须 autoload-free;**不能引用 `LobbyRooms`** ⇒ 见 §6.1 |

---

## 3. 方案选型

| 方案 | 结论 |
|---|---|
| **A′ 让服务端 exe 拿回窗口,面板长在 `server_main.tscn` 上** | **选定** |
| B′ 客户端里加「服务器」页 + 服务端写状态文件 | 落选:运维面住进玩家 exe;多一条状态文件生命周期 |
| C′ 独立「服务端控制台」exe | 落选:会与 `LocalServer` 形成**「启动服务端」的第二份实现**(本仓禁止) |
| D 浏览器 / HTTP 面板 | 落选:`TCPServer` / `StreamPeerTCP` / `WebSocketPeer` **全在 `disabled_classes` 里** ⇒ 要重编模板(10~15 min),且往发布包塞 TCP 栈 |

A′ 的机制(`custom_features` 是预设字符串,导出时拼进 project settings;任意设置都支持
`setting.<feature>` 覆盖):`editor_export_platform.cpp:1768-1777` + `project_settings.cpp:392-406`,
而 `run/main_scene.dedicated_server` 用的正是同一个机制。
**全仓 `.gd` 零处读 `has_feature("dedicated_server")`**(只有 `editor`/`template_debug`/`template`)⇒ 翻标记不牵动任何分支逻辑。

---

## 4. 构建与启动形态

改两处,**exe 名与全部下游不动**(`LocalServer` / `build_release.py` / `capture_session.ps1` / `README`):

| 文件 | 改动 |
|---|---|
| `export_presets.cfg:83`(preset.1 `Dedicated Server`) | `dedicated_server=false` + `custom_features="serverui"` |
| `project.godot` | 新增 `run/main_scene.serverui="res://server/server_main.tscn"` |

三条必须处理的后果:

1. **headless 早退**:`DisplayServer.get_name() == "headless"` 时**不实例化面板**。
   ★ 这条不用新守卫 —— `tools/build_release.py:106-147` 的产物冒烟已经在 `--headless` 下断言服务端
   必须打出「worker 就绪」且退出码 0;面板一旦在 headless 里出错就会被它抓住。
2. **`apply_display()` 绕开**:面板窗口在 `server_main.gd` 里显式设回(`window_set_size` +
   `WINDOW_MODE_WINDOWED`),并在注释里写清**为什么**(不改 `Settings`:那是公共配置层,不该知道导出细节)。
3. **worker 子进程照旧 `--headless`**(`worker_launcher.gd:70-157`)⇒ 不会每局弹一个窗口。
4. **客户端预设要收口**:面板落在 `server/` 下,而客户端预设是 `all_resources` ⇒ 不加排除的话
   管理面会随 `The Cyancular Ruins.exe` 一起发出去。在 `export_presets.cfg:13`(preset.0)的
   `exclude_filter` 末尾追加 `server/gui/*`。

窗口默认 **1280×960**(`Settings.DISPLAY_RESOLUTIONS` 里已有的 4:3 档),逻辑空间仍是 **1920×1440**
(`stretch/mode=viewport`,1920→1280 是 2/3 非整数缩放 ⇒ 像素边缘略不均,与主菜单/大厅**同一个**已接受的取舍)。

---

## 5. 页面设计(已定稿)

冻结记录(本机 scratch,`gitignore`;数字才是权威):`.superpowers/sdd/_gen/server_panel_frozen_{main,empty,few,confirm}.png`,
以及两张**失败证据** `mock_server_panel_v1.png`(整页右溢)、`mock_server_panel_v9.png`(字号翻倍后横向溢出 394px)。

### 5.1 骨架与几何账

```
┌ 76 ───────────────────────────────────────────────────────────── 76 ┐
│ 标 题 带(76)   服 务 器 控 制 台 …   版本 · pid · 7777 ●           │
│ 概 览 条(92)   房间 9 · 在线 23 · worker 5 · 端口 5/500 · 已运行 …  │
│                本机 192.168.1.24 · 端口 7777 / 公网提示(脚注 16)   │
│ ┌── 房 间 (1080, 最高 6 行后滚) ──┐ ␣40 ┌─ 所 选 房 间 (648) ────┐ │
│ │ 房号 模式 人数 状态 端口 房龄 地图│      │ 4821 大乱斗      3/4  │ │
│ │ 4821 …                            │      │ 端口 7821 · 进程 … 在 │ │
│ │ (超过 6 行 ⇒ 可见滚动条)          │      │ [关 闭 房 间]        │ │
│ │                                   │      ├─ 名 单(最高 5 行后滚)┤ │
│ │                                   │      │ 1 阿伟        房主   │ │
│ └───────────────────────────────────┘      └──────────────────────┘ │
│ 日 志(全宽,唯一 EXPAND 的块,吃全部余量;可见滚动条)               │
└─────────────────────────────────────────────────────────────────────┘
```

账面:`1920×1440`,外边距 **76** ⇒ 内容 **1768×1288**;中段 = 左 **1080** + 间隔 **40** + 右 **648**。
面板内边距 **32/20**(`menu_panel` 默认 64/46 会溢出;28/14 太挤)。

**实测读数**(改一次量一次):

| 状态 | 中段 | 日志 | `page_min` | 余量 |
|---|---|---|---|---|
| 9 间房(主态) | 613 | **435** | (1768, 943) | 纵向 345 |
| 4 间房 | 613 | 435 | (1768, 943) | 右列成为约束,中段不再随房数缩 |
| 0 间房(空态) | 174 | **874** | (1768, 504) | 日志吃满余量 |

★ **横向零余量**:中段最小宽 = 1080 + 40 + 648 = 1768 = 可用宽。
⇒ **左列内宽必须 ≤ 1024、右列 ≤ 592**(各减 64 内边距)。**任何新增文案都要先量宽度** ——
不量就是首版那种整页右溢,而且**不报错**。

### 5.2 主次(2026-10-16 按反馈重排)

1. **概览条** —— 服务器健康一行读全。★ 同一件事**只在这一处**说
   (此前散在"房间标题的计数 / 端口池 / 底部状态行"三处,必然不同步)。
   **可显示的量只有大厅能证明的**:房间数 / 待开局数 / 对局中数 / worker 在跑数 / 端口 x·500 / 已运行时长。
   ★ **不显示「在线人数」** —— 成员转连 worker 后大厅的 `players` 是空的,硬给一个数字就是假数据(§6.1)。
2. **房间表** —— 谁在玩、哪一局。
3. **日志** —— **唯一 `EXPAND` 的块**,拿走全部纵向余量。
4. **地址 / 动作降档** —— 本机地址从右列面板**降进概览条**(一次性信息);
   「关闭房间」从 560×72 降到 **420×64**(破坏性且低频,不该是全屏最重的元素)。

### 5.3 字号档(本项目只有 16 / 32 / 48)

| 档 | 用途 | 本案落点 |
|---|---|---|
| **16** | **脚注 / 机器读数**(主菜单版本行、`LineEdit` 那一档) | 概览条的公网/转发脚注、**日志正文** |
| **32** | **一切"给人读来做决定"的** | 分区标题、**列头**、数据行、**名单**、明细行、按钮、概览主行 |
| **48** | **全屏唯一主角** | 选中房的房号(只此一处) |

★ **表头 vs 数据靠颜色区分**(`C_TEXT_DIM` vs `C_TEXT`/`C_WHITE`),**不靠字号**。
★★ **改字号必须重量宽度**:32 号字的宽度是 16 的两倍 —— 实测把列头/名单/明细从 16 升到 32 后
整页横向溢出 **394px**(`page_min` 2162 > 1768),必须拆行 + 砍重复才收回来。

### 5.4 颜色语义(全部取自 `UiFactory`,不新增字面量)

| 语义 | token |
|---|---|
| 分区标题 / 主行动 / 对局中 | `C_GOLD` |
| 1v1 / 强调 | `C_ACCENT` |
| 大乱斗 / 3v3 | `C_MODE_ROYALE` / `C_MODE_TEAM` |
| **掉线宽限中** | ~~`C_GRACE`~~ **撤掉**(大厅拿不到 grace,见 §6.1) |
| **worker 已退出(待回收)** | **`C_DANGER`**(★ 不许借 `C_WARN` —— `ui.md:24` 规定它只表"弹夹见底") |
| 名单里"局中无在线信息" | `C_TEXT_MUTE` |
| 表头 / 次要读数 | `C_TEXT_DIM` |
| 空态文案 | `C_TEXT_MUTE` |

### 5.5 名单(独立成块)

一行一人:**序号 + 名字(`UiFactory.fit_name(名, 14)`)+ 状态**;32 号字;
最多 **5 行**后滚(`ROSTER_ROWS_MAX`,大乱斗可到 16 人)。
★ 与 `docs/eng/ui.md:27` / `mp_lobby` 的名单口径**同源**。
★ 曾经的错法:挤在"所选房间"的一行里,字号 16、每人只给 6 个半角单位(48px)——
等于把"人"排成全屏最小的字。

### 5.6 界面状态 + 房间状态(各三态)

**界面四相**:

| 相 | 行为 |
|---|---|
| 主态 | 见上图 |
| **房少**(4 间) | 表格自动收缩(实测 `MAXIMIZE_FIRST` 生效)、**不出现**滚动条 |
| **空态** | 概览/右列/日志**一起**变 0(不能只清左列,否则一屏自相矛盾) |
| **二次确认** | 按钮就地变「确认关闭 4821?」,3 秒无操作回退(**不用** `AcceptDialog`,省一个控件的可用性风险) |

**房间行状态 —— 只有大厅能证明的三态**(「掉线宽限中」撤掉:grace 只在 worker 的 `GraceWindow` 里):

| `state` | 判据 | 颜色 |
|---|---|---|
| `waiting` 等待中 | 未开局 | `C_TEXT_DIM` |
| `in_match` 对局中 | 已开局 && worker 存活 | `C_GOLD` |
| `stale` **worker 已退出** | 已开局 && `worker_pid > 0` && `!pid_alive`(≤30s 内被回收梯收掉) | `C_DANGER` |

★ **名单的诚实边界**:`waiting` 房间的名单来自 `players` 表(**可信在线**);
`in_match`/`stale` 房间只有**开局那一刻冻结的 `roster`**,在线状态在 worker 侧、本面板**不显示也不许猜**
(数据层用 `online_known: false` 标出,UI 在名单标题里写「局中快照」)。

### 5.7 落点与实现细节

| 项 | 值 |
|---|---|
| 面板场景 / 脚本 | `server/gui/server_panel.tscn` + `server/gui/server_panel.gd`(命名检查:目录小写 / `.tscn` snake_case) |
| 主题挂法 | `CanvasLayer` → 满屏 `Control`(`theme = res://ui/theme/menu_theme.tres`)→ 内容。★ 主题必须挂在 **CanvasLayer 内部的 Control** 上(CanvasLayer 会断主题传递,六个菜单屏都是这么解的) |
| 刷新 | 面板自己 `_process`,**~2 Hz**;房号集合没变就**原地改文字**,变了才增删行(★ 不照抄 `mp_lobby._redraw_cards()` 的整批重建:那是事件驱动,2 Hz 重建会闪、会丢选中与滚动位置) |
| 选中态 | 点房间行 = 选中;选中行 `row_box` + **2px `C_ACCENT` 描边**;刷新时**按房号保持选中**,房没了退回空态(**不退回第一行** —— 那会让人以为自动选了别的房) |
| 行高 | 房间行 **60**、名单行 **44**、行间隔 **8**(两个 `MAXIMIZE_FIRST` 上限 = 6×60+5×8 / 5×44+4×8) |
| 滚动条 | 宽 **16**;轨道 `C_FIELD`、滑块 `C_BORDER`、`grabber_highlight/pressed` = `C_ACCENT` |
| 面板层号 | 服务端进程里没有别的 UI,层号无冲突;取一个并注释"本进程唯一",别照抄对局内 HUD 的 128~150 |

---

## 6. 数据层(唯一可测的一层)

照仓内先例做成**纯构造**(`room_list_payload()` 的注释明写"抽出来是为了可测:探针没有对端,
`NetBus.reply` 会静默跳过 ⇒ 列表内容观测不到")。但先有一条**实测出来的约束**:

### 6.1 硬约束:`-s` 冒烟里 autoload 不可引用(实测)

`-s` 冒烟(autoload 尚未实例化)下,**autoload 标识符在编译期就解析不到** —— 实测
`res://server/lobby/lobby_rooms.gd:120` 报 `Compile Error: Identifier not found: NetBus`,
**整份脚本连内部类都构造不了**;而 `server/lobby/worker_launcher.gd` **是干净的**
(实测 `-s` 下 `pick_port()` 正常、`WORKER_PORT_SPAN = 500`)。

⇒ 数据层按「能不能被冒烟引用」切三块:

| 文件 | 职责 | 冒烟? |
|---|---|---|
| `server/lobby/worker_launcher.gd`(**改**) | `static classify(ports: Array, pids: Dictionary) -> Array[Dictionary]` + 实例口 `busy_ports()` | **能**(autoload-free) |
| `server/gui/server_status.gd`(**新**) | `static build(rooms: Array[Dictionary], ports: Array[Dictionary], now_unix: float) -> Dictionary` —— **只吃纯字典** | **能** |
| `server/gui/lobby_snapshot.gd`(**新**) | 适配层:把 `LobbyRooms` 三张表 + `WorkerLauncher` 读成纯字典 | **不能**(引用 `LobbyRooms`);逻辑密度低 ⇒ 靠评审 |

**`classify()` 的输入输出**(纯函数,三种占法必须可区分):

```gdscript
# ports: 已分配端口(Array[int]);pids: port -> pid(Dictionary,缺失/0 = 没 spawn 过)
# 返回每项 {port:int, pid:int, alive:bool}
#   已分配未 spawn  ⇒ pid=0,   alive=false
#   已 spawn 且活着  ⇒ pid>0,   alive=true
#   已 spawn 已退出  ⇒ pid>0,   alive=false
static func classify(ports: Array, pids: Dictionary) -> Array[Dictionary]
```

**`build()` 的输入输出**:

```gdscript
# rooms 每项:{kind: "1v1"|"royale"|"team", code: String, players: int, cap: int,
#            in_match: bool, host: String, map: String,
#            worker_port: int, worker_pid: int, created_at: float,
#            roster: Array[{"role": int, "name": String}]}
# ports = classify() 的原样输出
# 返回 {counts: {...}, rooms: Array[Dictionary], ports: Array[Dictionary]}
#   counts: rooms / waiting / in_match / lobby_players / workers_alive / ports_used / ports_total
#   rooms 每项 = 输入 + {state: "waiting"|"in_match"|"stale",
#                        age_sec: float, worker_alive: bool, online_known: bool}
#     ★ state 的判据见 §5.6;online_known = (state == "waiting")
static func build(rooms: Array[Dictionary], ports: Array[Dictionary], now_unix: float) -> Dictionary
```

- ★ `server_main.gd:118` 的 `add_child(RoomManager.new())` **要留住引用**(今天没存)。
  那一行的**位置本身是承重的**(注释明写:必须在 `_ready` 体内、`add_child` 之后、与 `set_process(false)`
  之间没有早退),而钉它的 `duel_spawn_timeout_smoke` **已删·2026-10-09 ⇒ 今天零守卫** ⇒
  改动时保持这些形状,并在 diff 里人工确认。

★ **一次刷新只读一次快照**。分两次读(一次给计数、一次给列表)会在两次读之间被房间增删穿过,
渲染出「(3 间) + 现在没有房间」这种自相矛盾的屏 —— 空态首版正是这个形态。

★ **房数 / 端口占用 / worker 存活是三个独立的量,不许互相推导**:端口归还延迟
(1v1 120s / 大乱斗·3v3 360s,`worker_launcher.gd:14,17,19`)意味着"房没了但端口还占着"是**常态**,
而这正是面板最该让人看见的东西。

---

## 7. 动作与安全

**只做一种动作:「关闭房间」**,实现 = `lobby.teardown_room(room, TEARDOWN_KILL, "<服主关闭>", true)`。
理由:它是仓内**唯一**的拆除收口(端口归还/删注册表只许出现在它体内,`room_sweep_lint` 钉着),
杀 worker / 拆房 / 作废凭据 / 断开玩家一次到位。

- **点按钮到执行之间房可能已经没了** ⇒ 执行时按**房号 (+模式)** 重新解析;解析不到 = no-op +
  刷新 + 在面板里说一句。**绝不拿快照里的对象直接操作。**
- **二次确认**见 §5.6。
- **不做**:踢单个玩家(要新增 RPC 且与宽限期/重连语义纠缠);「重启服务器」(进程内自杀没人重新拉起,
  那是客户端 `LocalServer` 的活);日志复制/导出。
- **不碰**:`--worker` 分支、`teardown_room` 的语义、`NetBus` 协议表、worker spawn 的 `--headless`。

---

## 8. 日志区

★ `RichTextLabel` 即便 `scroll_active = true` **也不画滚动条** —— 只给一个"无从判断位置的死盒子"。
故:`ScrollContainer`(可见滚动条 + 滚轮) + `fit_content = true` 的 `RichTextLabel`。

- 滚动条**套调色板**:轨道 `C_FIELD`、滑块 `C_BORDER`、悬停转 `C_ACCENT`,宽 **16**。
  (轨道若用 `C_ROW` 压在 `C_SURFACE` 上**几乎看不见** —— 第一版就是这么被反馈的。)
- 刷新 ~2 Hz;`worker_<端口>.log` 增量读(记 offset)。
  ★ **v1 不读 `godot.log`**:大厅自己正在写那个文件,同进程再去读它在 Windows 上有共享语义风险,
  而"有时有有时没有"比没有更坏。大厅自己的 stdout 仍可从控制台窗口看到。
- **自动跟随到底是默认**,用户手动上滚 ⇒ 暂停跟随,标题栏提示「已暂停 · 点此回到底部」。
- ★ `EXPAND_FILL` 必须设在**日志面板**上:设在内层 `ScrollContainer` 上是无效的 ——
  实测日志块只有 **90px** 高(AUTO 下 `ScrollContainer` 的 `min_size.y` 为 0,面板只拿到最小高)。
- 日志正文 **16**;不做"字号开关"(一个常量的事,别为一个值加控件)。

---

## 9. 验证与守卫(按仓规,不许多写)

| 层 | 守卫 | 理由 |
|---|---|---|
| 数据层 `WorkerLauncher.classify()` + `server_status.build()` | **1 条 `-s` 冒烟**(两函数一起测) | 纯逻辑,能红:① 去掉"已分配未 spawn 的端口"它红 —— 那正是**端口泄漏看不见**这个失败模式;② `state` 三态判据写反它红 |
| headless 不实例化面板 | **已有**:`build_release.py:106-147` 产物冒烟 | 行为上可观测,零新代码 |
| 面板版式/配色/字号 | **不写** | `AGENTS.md` §2 表末行 —— 观感不写自动化守卫 |
| 导出标记被改回去 ⇒ 窗口静默消失 | **不写,改登记** | 只有人眼能观测;硬造一条必然是 **D6(读配置文件文本判形态)**,按 `AGENTS.md` 不许进 |

**登记进 `docs/eng/registered-debt.md`**:① 面板版式零守卫;② 导出标记这条"零报错地跑错分支"只能靠人眼;
③ 1280×960 下 2/3 非整数缩放;④ `server_main.gd:118` 那一行的位置零守卫;
⑤ **`lobby_snapshot.gd` 适配层零守卫**(它引用 `LobbyRooms` ⇒ `-s` 下不可引用,只能靠评审;
判据逻辑全在 `server_status.build()` 里,适配层只做字段搬运)。

**设计期仪器(不是守卫)**:**逐控件内缩审计** —— 把每个文字控件的全局矩形与它所在面板的矩形相减,
四向距离一览。「有没有字顶格/出框」**人眼看降采样图判不准**:本轮实测把 `1214 ≤ 1288` 判反过一次,
而它抓出了**真的**顶格(`header_strip` 的 `L 0.0`)与两处整页溢出。

---

## 10. 分期

| 期 | 内容 | 出口判据 |
|---|---|---|
| **P0** | **可行性验证**:只改 §4 那两处(不加任何 UI),双击 exe 跑一次 | 出窗口 + 7777 照常 + 能拉起 worker + 日志照旧。**红则回退选 B′** |
| **P1** | `WorkerLauncher.busy_ports()` + `server/gui/server_status.gd` + 它那条 `-s` 冒烟 | 冒烟 `SMOKE OK`,且去掉一个端口占法它就红 |
| **P2** | 面板场景/脚本(只读:概览条 + 房间表 + 名单)+ headless 守卫 + `apply_display` 处理 | **尽早真导一次**:类可用性只在导出产物里现形(`RELEASE.md:170`) |
| **P3** | 日志区(滚动条 + 增量 tail + 跟随/暂停) | 手滚能暂停、点回能到底 |
| **P4** | 「关闭房间」+ 二次确认 + 边界登记 + 客户端预设 `exclude_filter` 收口 | 点一次关掉真对局,房与端口按既有梯回收 |

---

## 11. 明确不做

- 对局内**比分/血量/回合**(在 worker 进程里,要新协议)。
- **局内在线状态 / 掉线宽限倒计时** —— 同属 worker 侧(`GraceWindow`);面板只显示开局冻结的名单,
  并在标题注明「局中快照」。**不许拿 `players` 空表倒推"0 人在线"**(那是假数据)。
- 踢单个玩家、封禁、远程运维(要新端口,而 `TCPServer` 被裁着)。
- 面板内「重启服务器」(进程内自杀无人拉起)。
- 大厅自己的日志流(理由见 §8)。
- i18n(全仓零 i18n,`docs/eng/debt/wont-fix.md:29-43` 已裁定不引入)。面板文案是第三处硬编码落点,
  ★ 注意 `tests/harness/menu_autotest.gd` 会**按文本**点按钮 ⇒ 改文案可能打断测试。

---

## 12. 已知边界与风险

1. **服务端从此要显示/GPU**:无显示器的机器必须显式 `--headless`(仍然有效,面板自动不实例化)。
2. **面板窗口的显示参数**:`apply_display()` 在非 headless 下会按玩家存档改窗口 ⇒ 由 §4.2 显式覆盖。
   ⚠ 这条只有跑一次真窗口才能验(结构性走不到 headless 分支)。
3. **横向零余量**(§5.1):任何新增文案都可能整页右溢,而**不报错**。
4. **导出标记回退**会让面板静默消失,零守卫(§9)。
5. **worker 进程内的对局态永远看不到** —— 这是进程隔离的代价,不是缺陷。
6. `_wait_timer`(`server_main.gd:12`)是全仓未读写的死字段,与本设计无关,**不顺手删**。
