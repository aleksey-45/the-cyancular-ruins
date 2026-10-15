# %s

> **本文件从 [`registered-debt.md`](../registered-debt.md) 拆出**（2026-10-13，原文件 888 行 / 126KB 越过了 `CLAUDE.md:5` 那条 64KB 上下文线）。返回索引：[`registered-debt.md`](../registered-debt.md)。
> ★ 文档会过期 —— **任何冲突以源码为准**，读之前先 `grep` 复核；`文件:行号` 与本仓自述一致地会漂。

## 七、已裁定不做(won't fix,2026-10-04 加)

**本节不是欠账清单**:§一/§二 是"要还的债",这里是**已经判过、决定不还的** —— 每条都带**判决理由**与**翻案条件**。
★ **写在这里的唯一目的:下一代 agent 读到就不必按审计重查一遍。** 没有翻案条件的"不做"等于没判,所以三段缺一不可。
★ 判决来源:用户 2026-10-04 对审计 §1/§2/§3/§4 的逐类裁定(见 [`audit-2026-10-04-design-conventions.md`](../../archive/audit-2026-10-04-design-conventions.md) §10 那张表)。
本节三条都不是"没发现",而是"发现了、判过不做"。

1. **菜单没有键盘/手柄焦点入口**(`audit §2.7`;owner 用户;最后复核 2026-10-04;判决:**记录而不修改**)。
   - **症状**:`grep -rn "grab_focus\|focus_neighbor" core/ scenes/ server/ ui/` = **0 命中**(2026-10-04 复核);
     全仓唯一被处理的"焦点"是返回 —— [`scenes/settings_menu.gd`](../../../scenes/settings_menu.gd):142
     `if event.is_action_pressed("ui_cancel")`。而 Godot **不会**自动点亮首个可聚焦控件 ⇒
     冷启动后 Tab / 方向键 / 手柄**一个按钮都到不了**。
     ★ 这不是"机制没人用过":[`scenes/mp_lobby.gd`](../../../scenes/mp_lobby.gd):506/509 为"进不去的房"
     按 `disabled` 切 `focus_mode`(NONE / ALL)—— 机制在、只是**没喂初值**,也没把屏与屏之间的邻居接起来。
   - **为什么判"不做"**:用户 2026-10-04 对审计 §2 的裁定是「**记录而不修改**」,且在审计 §7 的候选表里**不列为候选**
     (audit §10)。实质理由:现网入口只有鼠标,本仓是单机 + PvP demo,**没有**主机/手柄发行计划;
     而"手柄能走完全部菜单屏"的改动面是**每一屏**(首焦点 + 邻居网格 + 焦点可见样式),收益对不上面。
   - **什么条件下翻案**:真做手柄/键盘导航(或主机发行)时。**前置三件,缺一件就只是"能按 Tab 但看不出焦点跑哪去了"**:
     ① 每屏给首个可聚焦控件喂初值(`grab_focus()`,一般落在该屏主行动);
     ② 用 `focus_neighbor_*` 把网格**显式**接起来(本仓大量绝对定位 + 容器混排,靠引擎自动推导不可靠);
     ③ 给 `focus` 态补**可见**样式(Theme / StyleBox),否则焦点在哪看不见。
     ★ 届时以 `settings_menu.gd` 的 `ui_cancel` 为入口往回推,但**先 `grep` 复核行号**(审计是快照,行号会漂)。

2. **零 i18n / 没有文案表**(`audit §2.8`;owner 用户;最后复核 2026-10-04;判决:**记录而不修改**)。
   - **症状**:`grep -rn 'tr("' core/ scenes/ server/ ui/` = **0 命中**(★ 别用 `grep "tr("` —— 它会**假命中** `str(`);
     无 `.po` / `.csv` / `.translation`,`project.godot` 无 `internationalization` 段 ⇒ 文案全是**中文字面量**。
     量级:审计 §2.8 记"`ui/` + `scenes/` 约 **328** 处中文串面",★ 但**那个数来自子代理、审计自己标了未复核**
     (audit §5 第 5 条)⇒ 谁要引用**先自己数一遍**。
     ★ 同条点出的**结构性障碍**才是判"不做"的真正原因:多条探针**按文案找控件**
     ([`scenes/main_menu.gd`](../../../scenes/main_menu.gd):204 自述 `kh_l4_visual_probe` 按文案找按钮;
     [`tests/harness/menu_autotest.gd`](../../../tests/harness/menu_autotest.gd) 的 `_press_by_text` 同理)⇒ **改文案 = 改测试**。
   - **为什么判"不做"**:同样是用户 2026-10-04 的「记录而不修改」(audit §10)。它不是"加一份翻译文件"的工作量:
     ① 文案今天有**多个落点**(代码字面量 + `.tscn` 里的 `text=`,而"搬进 `.tscn`"这件事本身又添了这一处);
     ② 得先把"按文案找控件"的探针判据换成 `unique_name_in_owner` / `meta`,否则每换一版译文都要跟着改探针;
     ③ 项目**无**多语言发行需求。
   - **什么条件下翻案**:真要出中文以外的语言(或要让用户切语言)时。**顺序不能反**:
     先做 ② 的判据改造(探针不再认文案),再抽文案表(`.csv` + `TranslationServer`,或一层统一的取词),最后才谈译文。
     反过来先抽表 ⇒ "改文案 = 改测试"这条税**翻倍**(两套文案表 + 仍按文案找控件的探针)。

3. **发布版里"菜单自动探针"退化为 no-op ⇒ 发布版没有菜单端到端守卫**(owner 用户;最后复核 2026-10-04;判决:**裁剪后不随包发布**)。
   - **症状**:[`scenes/main_menu.gd`](../../../scenes/main_menu.gd) 的 `_ready` 在命令行含 `-- --autotest-*` 时
     把 [`tests/harness/menu_autotest.gd`](../../../tests/harness/menu_autotest.gd) 挂到树根,但那条依赖被 `:164` 的
     `ResourceLoader.exists("res://tests/harness/menu_autotest.gd")` 守着 ⇒ 文件不在包里时它**静默跳过**
     (不报错、不打日志、不影响退出码)—— **不是坏,是"没有"**。
     ★ 裁剪**之前**它是能用的(2026-10-04 实况):`export_presets.cfg:11-13` 是 `export_filter="all_resources"` +
     `exclude_filter="*.md,.superpowers/*"`,审计 §1.3 对仓库根那两个产物直接 grep 得 **336** 条 `res://tests/*` 路径
     ⇒ 发布版里探针文件**在**。发布包裁剪(`exclude_filter` 加 `tests/*,tools/*`;audit §1.3 / §7 第 3 条)**已于
     2026-10-04 落地**(`10da6cc`)⇒ 它**已不在**包里。
     ★ **代价不只"少一条守卫"**:`menu_autotest.gd:43-47` 自述这条通道**曾是发布产物上跑场景探针的唯一一条**
     (导出 exe 编译了 `disable_path_overrides=yes`,`<exe> res://x.tscn` 会被引擎当场拒绝)
     ⇒ 裁剪同时收掉"在成品上跑 `tests/probe/*.tscn`"这个能力。
     ★ **配套订正已完成(2026-10-04:`10da6cc` 改口 + `d2b7e53` 补「**发布版里**」限定语)**:`main_menu.gd:154-156` 那句「tests/ 会一起打进发布包」
     **曾经是实况**,已改口为两段现况 —— 曾经会一起进包(⇒ 真守卫理由只是"文件可能不存在")+
     2026-10-04 起 `exclude_filter` 已含 `tests/*` ⇒ **发布版里**这条通道没了。
   - **为什么判"不做"**:用户 2026-10-04 裁定"发布版不再有菜单自动探针"(与发布包裁剪同批;audit §7 第 3 条那句
     "同时决定 `tests/harness/menu_autotest.gd` 这个'生产依赖测试文件'该怎么办"就是这件事的入口)。代价侧很实在:
     ① 探针**不是单文件** —— 它的 `sceneprobe/<名>` 分支还要 `tests/probe/<名>.tscn`(`:48-49`),
     只放一个文件等于**同一种静默 no-op**(闭包会随探针增长再次缺文件);
     ② `-- --autotest-*` 会成为**成品里可用的隐藏开关**:它真点按钮、真切场景、真往 `user://` 写截图(`:495-513`)
     ⇒ 等于给成品留一条测试后门;
     ③ 它**本来也不是自动守卫**:没有任何脚本(零个 `.sh`、零个 `.py`)跑它,覆盖靠人手动拿开关跑一次再 grep。
   - **什么条件下翻案**:需要一个"**发布产物上真的跑过**"的端到端证据时(例如每次发布都必须验一遍菜单流转)。
     **翻案条件 = 把那条探针作为运行期资源随包发布**,并接受上面 ①②③:最小做法是让 `exclude_filter` 留一个白名单
     (只放 `tests/harness/menu_autotest.gd` + 它 `sceneprobe/` 分支要用的 `tests/probe/*.tscn`),
     并给白名单配一条**能红**的守卫 —— 否则又是"闭包少了文件 ⇒ 静默 no-op"的老形状。
     ★ 更便宜的替代(只要"菜单能起来"这一档):在 [`tools/build_release.py`](../../../tools/build_release.py) 的产物冒烟里加一步
     `-- --autotest-mp` + grep 一条文本(它已有同款做法:`check_weapon_registry` 拿 `-- --registry-report` 那行文本对账)。
     但那**不是**端到端守卫,只证明"主菜单 → 大厅"这一步没崩。

24. **服务端输入收口只钳了 `ax`；`aim` / `winst` 仍未钳位**（owner: closeout 批 Task 4；最后复核 2026-10-08）
    - **事实**：`PacketInputSource.apply_packet()` 从客户端包里取六个字段(`ax` / `held` / `aim` / `winst` / `pressed` / `released`)。
      本批按范围纪律**只钳 `ax`**(非有限 → 0；`|ax| ≤ 1`，见 `PacketInputSource.sanitize_axis`)；`held` / `pressed` / `released`
      是**位图**，未知位被 `& BIT_X` 掩掉 ⇒ 天然安全。
    - **未钳**：`aim`(`Vector2`，`get_aim_dir_override()` **原样返回**，未归一化)与 `winst`(int，只判 `> 0`)。
    - **最强保证**：本批**只**保证 `ax` 与"队列长度有界且丢包保住边沿"。**不是**"客户端包已完全可信"。
    - **翻案条件**：先核 `aim` 在下游(玩家瞄准消费处)是否已归一化；若没有，按 `sanitize_axis` 同一手法补一个纯函数 + 一条能红的断言。

25. **RPC 通道分流"是否生效"没有运行期判据**（owner: closeout 批 Task 5；最后复核 2026-10-08）
    - **事实**：`GDScript.get_script_method_list()` 的元素键只有 `["name","args","default_args","flags","id","return"]`，
      **没有** `rpc_config`(实测) ⇒ **通道号无法在运行期回读**。而 `@rpc` 注解只吃字面量(不能引用 const)⇒ 声明与表天然是两份文本。
    - **现有判据** = [`netplay.md`](../netplay.md) 通道表 ↔ 声明的**文本对账**([`tests/smoke/rpc_channel_contract_smoke.gd`](../../../tests/smoke/rpc_channel_contract_smoke.gd))，
      **已在文件头标注为"代理判据"**(按本文档所属批次的 D6b 纪律)。
    - **最强保证**：只证明"**声明按表写**"，**不**证明"`bullet_spawn` 的重传真的不再堵住 `send_input`"。
    - **翻案条件**：写一个两 peer 分占不同 ENet 道的对打脚本，读 `MultiplayerPeer.get_packet_channel()` 确认落点(引擎源码
      `modules/enet/enet_multiplayer_peer.cpp::put_packet` 给出的映射是 `transfer_channel > 0 ⇒ SYSCH_MAX + tr - 1 = tr + 1`)。

26. **`beam_fired` 在 `NetBus` 与 `NetBusExt` 各声明一次**(重名)(owner 未认领；最后复核 2026-10-08)
    - **事实**：两处各一份 `@rpc`、函数体逐字相同([`net_bus.gd`](../../../core/net/net_bus.gd) 与 [`net_bus_ext.gd`](../../../core/net/net_bus_ext.gd))。
      `net_bus_ext.gd` 那份**自己的注释**写着"原版 NetBus 逐字节不动，新 RPC 进 NetBusExt" ⇒ ext 那份是**遗留**。
    - **为什么危险**：重名 = 接收端挂错节点 = **静默 no-op**。裁定与判据三处已存在：[`scenes/pvp_match_client.gd`](../../../scenes/pvp_match_client.gd)
      (**必须走 NetBus**，不是 NetBusExt)、[`scenes/pvp_game.gd`](../../../scenes/pvp_game.gd)(发送端走 NetBus)、
      `kh_l6_probe.gd`（已删·2026-10-09）(判据是**同行**必须含 `NetBus.rpc_id(`)。
    - **本批处置**：**两份给同一通道**(Task 5 的 `transfer_channel` 都是 3)，并把"重名集合恰好 = `{beam_fired}`"**钉成一条断言**
      (`rpc_channel_contract_smoke` 的 ③：新出现一个重名、或 beam_fired 被删掉一份，都会红)。
    - **翻案条件**：确认真无调用点后**删掉 ext 那份** —— 那是协议面改动，单独走档 3(别顺手删)。

27. **`rejoin_probe` 的 c3「反向对照」两遍不一致**（2026-10-08 实测；owner 未认领）
    - **事实**：两遍**同配置单跑** —— 第一遍 `REJOIN PROBE: ALL-OK(5 条断言)`；
      第二遍 `REJOIN PROBE: 1 条失败(跑了 6 条断言)`，失败行 =
      `WATCHER[c3] FAIL c3 ★ 那一行对**没有凭据的第三人**也是可点的 —— 可点性不是按人判的`。
      ★ **两遍的断言条数都不一样**（5 vs 6）⇒ 这个阶段**时序相关**（第一遍根本没走到 c3 的结论时刻）。
    - **这条断言在说什么**：[`tests/harness/rejoin_watcher.gd`](../../../tests/harness/rejoin_watcher.gd) 里它是 c1 那条的**反向对照** ——
      同一行、同一份载荷，**手里没有凭据**的人必须看到"点不动"；两条合起来才说明可点性是**按人**判的，
      而不是"那一刻所有人都能进"。
    - **归因**：与 closeout 批 Task 4/5 **无关**（该次日志里 RPC/通道/脚本错误 **0 条**；credential 类 RPC 都在 `transfer_channel = 0` 那条**没动过**的道上）。
      可能是**产品侧**（那一行的 `disabled` 确实不是按人判），也可能是**探针侧**（`_c3_row_disabled` 采样早于该客户端应用状态）。
    - **判别实验做完了（2026-10-08）⇒ 结论：不是产品缺陷，是探针竞态 + 一个"空过"守卫**：
      产品侧条件是 [`scenes/mp_lobby.gd`](../../../scenes/mp_lobby.gd) 的 **`btn.disabled = in_match and not mine`** ——
      第三人 `mine=false`、`in_match=true` ⇒ **`disabled=true`，产品是对的**（`mine` 的语义见该处注释：先问"这是我的房吗 + 凭据还在吗"）。
      真因是 watcher **在"第一次看到那一行"的那个 tick** 读 `row.disabled`，而那一刻 `mp_lobby` 可能**还没按新载荷重建按钮**
      （watcher 与它各收一次 `room_list`，先后不定）⇒ 读到的是 `in_match=false` 那一版的按钮 ⇒ **假红**。
      ★ 同时暴露一个更该修的东西：`_c3_row_disabled` **默认 `true`**（恰好等于期望值）⇒ **一次都没读到那一行时，
      原代码照样打 `_ok("同一行对第三人仍是 disabled")`** —— 断言**读起来比它给的多**。
    - **已修（2026-10-08，两处）**：① **结论时刻重读一次**按钮状态（`RESULT_WAIT`=40s 之后 UI 早已稳定）；
      ② 新增 `_c3_row_read`，**没读到就 `_fail`**（"这条反向对照**没成立**，不许按默认值空过"）。
    - **验证**：正常两遍 **`ALL-OK`**；★ **变异**：强制 `_c3_row_read = false` ⇒ **恰好红在新分支**
      （`WATCHER[c3] FAIL c3 ★ 没读到那一行的 disabled…`），而修前同一条件会**静默打过**。

28. **快照的编码方式：60Hz × 全量绝对态 × Godot 通用 `Variant` 序列化（字符串键每包重复）**
    > ★★ **分析全文、全部实测数字与来源**见 [`netcode-snapshots.md`](../netcode-snapshots.md)（**那份是单一来源**；本行是登记与翻案条件）。（owner 未认领；2026-10-08 复核源码 + 复读 2026-09-12 的实测）
    > ★★ **状态（2026-10-09）："去编码开销"那一半已落地** —— 新增 [`core/net/snapshot_codec.gd`](../../../core/net/snapshot_codec.gd)
    >   （一张 schema 表驱动两侧 + 首字节版本号 + `PackedByteArray`），发送点两处、解码收在 [`net_bus.gd`](../../../core/net/net_bus.gd) 的 RPC 入口
    >   ⇒ **三个游戏场景与全部钩子一行没动**。实测：世界包条目 **368→51 B**、本人包 **884→102 B**、
    >   **`N=8` 服务器上行 587→72 KB/s**、世界包**在 N≤8 恒 1 片**（"丢一片=整帧丢"对世界包归零）。
    >   **验证**：默认批 `RUN_ALL OK(12 runs / 3 gated-assertions)`；`snapshot_size_probe` 三条断言（真实产出逐键往返 / schema 与 `capture_state()` 对齐 / 武器块整体性）；
    >   **真链路**（协议改动 ⇒ 必须真两端对打）：`pvp_match_smoke` `SMOKE PASS`、`royale_soak` `ALL-OK(4/4)`、
    >   `rejoin` `ALL-OK(5)`、`pvp_room` `SMOKE PASS`（`team_match` 未跑：它被登记为"不算守卫"）。
    >   ★ **量化与增量仍未做**：量化有"**两端一起量化**"的前置条件（Gaffer），而 `c2` 是回滚锚点 ⇒ 属档 3；增量要双向 ack 系统。
    >   ⇒ **本行只销"编码开销"这一半；量化/增量另立**（见 [`netcode-snapshots.md`](../netcode-snapshots.md) §5.1）。
    - **架构侧不蠢**（先说清，免得读成"整套联机都是错的"）：服务器权威 + **unreliable 快照与 reliable 事件/输入分道** +
      本地玩家**预测/回滚对账(C2)** + 乱序丢弃(`tick` 比较) + canonical 坐标 —— 与业界同族
      ([Gaffer《Snapshot Interpolation》](https://www.gafferongames.com/post/snapshot_interpolation/)、Source/Quake 系增量快照)。
    - **蠢的是编码，三件事叠起来**：
      ① **60Hz 全量**（`match_state.gd:98` `SNAPSHOT_INTERVAL := 1.0/60.0`）—— 业界是 **10~30Hz + 客户端插值缓冲**
         （Gaffer 的经验值：缓冲 = 3× 发送间隔；60Hz 只是"不靠插值、用高频掩盖抖动"）。
      ② **通用 `Variant/Dictionary` 编码** —— **字符串键每包重复**、位置/速度是 32 位 float、**无量化 / 无变更位 / 无增量基线**。
         Gaffer 对**同类数据**（901 个立方体）做"绑定+量化+已 ack 基线增量"能把裸 60Hz 全量压到 **~1%**
         （17.37 Mbit/s → 目标 256 kbit/s，[Snapshot Compression](https://www.gafferongames.com/post/snapshot_compression/)）。
      ③ **每帧给同一个客户端发两份关于"他自己"的东西**：世界包里含自己那份渲染字段（客户端**刻意不消费**），
         外加逐 peer 的 `snapshot_own`。★ 注意别夸大：`snapshot_own` 的 `c2` 与世界的渲染字段**不是同一份数据**，
         真正的浪费是 **c2 每帧全量**（下面第 ① 项）。
    - **实测（两处独立、互相吻合）**：
      · `snapshot_size_probe`：单玩家条目 **872 B** = 渲染散字段 **272 B** + **`c2` 588 B（占 67%）**；`c2` **26 个字段**、渲染 11 个；
        世界包瘦身版 **176 B/人**（现在 ~265 B/人）；**N=8：单帧 6.81 KB → 每端 408.75 KB/s → 服务器上行 3.27 MB/s（≈26 Mbps）**。
      · [`royale-soak-2026-09-12.md`](../../royale-soak-2026-09-12.md) §2.2（**真客户端**）：每人每快照 ≈0.96 KB ⇒ 每端下 ≈57.5×N KB/s；
        **N=8：每端 460 KB/s（3.7 Mbps）、服务器 ≈29 Mbps**，并已判为"本层最硬的扩展性瓶颈"。
    - **次生后果**：N≥5 时一帧 **3~6 片**，而快照是 **unreliable 分片** ⇒ **丢一片 = 整帧丢**
      （1% 分片丢包 ⇒ 6 片整帧存活率 ≈94%）。
    - **文档漂移（2026-10-08 已订正）**：[`pvp-networking.md`](../netplay.md) 原写"**30Hz** × 8 字段 × 逐 peer `rpc_id`"，
      而源码是 **60Hz × 13 字段 × 世界包一次广播 + 逐 peer 本人包**，且**完全没提 `snapshot_own`** ⇒ 让人以为流比实际轻得多。
      ★ 该处已按源码订正（顺带说明:soak 那次 57.5 KB/s ÷ 0.96 KB = 60Hz ⇒ **实测本身就证明是 60Hz**，文档的 30Hz 是旧值）。
    - **建议的修法（按"收益÷风险"排序；★ 都不是本行能顺手改的，需单独立项）**：
      1. **`snapshot_own` 降频（60→30Hz）并只发回滚真正需要的字段** —— `c2` 占单玩家条目 **67%**；
         降一半频率即省 ≈1/3 总量。★ 风险：重放窗口变长（CPU）⇒ 必须过孪生/回滚冒烟。
      2. **世界包去键名 + 量化**（探针已量：**176 B/人 vs 265 B/人 ⇒ −34%**，**不动语义**，最便宜）；
         再进一步是 `PackedByteArray` + 固定 schema 位打包。
      3. **世界包不发自己那份**（客户端明确不消费）⇒ 世界包 ×(N−1)/N。
      4. **变更位**：`previewing`/`waterproof`/`haste`/`rewind`/`type_id`/`hp` 变化极慢、`trail` 是数组 ⇒ "未变 1 bit"。
      5. **降频到 30Hz + 副本插值缓冲**（Gaffer：延迟 = 3× 发送间隔）—— ★ **这一步改的是手感/延迟取舍，要用户拍板**。
      6. **增量 vs 已 ack 基线（+ relevancy）** —— 把 O(N²) 压下去的正解，但要引入 ack 驱动的基线管理，属**大改**。
    - **翻案条件（可验）**：`snapshot_size_probe` 的"单玩家条目"从 872 B 降下来（例如 ≤400 B）且 `royale_soak` 的
      **N=8 每端下行**从 460 KB/s 显著下降（例如 ≤250 KB/s），且孪生/回滚冒烟全绿 ⇒ 本行可销。
    - ★ **结论照实写**：**不是"愚蠢的模式"，是"最省事的编码 + 优化没做"** —— 而且**仓库自己 2026-09-12 就量出来并写了成因**，
      `snapshot_size_probe` 连"瘦身版 176 B/人"都算好了。**量了、登记了、没做**，这才是这条债的真相。

29. **输入队列："每 tick 恰好消费一个"是**无回复力**的 ⇒ 积压会**永久**留在那里（延迟加上去就不下来）**
    > ★★ **分析全文与来源**见 [`netcode-snapshots.md`](../netcode-snapshots.md) §4.2；本行是登记与翻案条件。（owner 未认领；2026-10-08 读码 + 对照 Valve/Gaffer）
    > ★★ **状态（2026-10-09）：机制已改，但本行暂不销** —— `PacketInputSource.adapted_cap` / `push_pending(q, pkt, cap)` 与
    >   [`match_host.gd`](../../../server/match/match_host.gd) 的 `_on_input` 改成：上限 = **实测抖动包络**（每 tick 一 tick 到过几包的**原始**深度）+ 1，
    >   包络**逐 tick 衰减** ⇒ 网络一安静就把堆着的陈旧包释放掉 —— **这就是原来缺的那条回复力**；
    >   丢的仍是最旧那包、边沿仍并入队首（玩家的按键不丢）。
    >   ★ 判据侧：`snapshot_own` 现在带 **`q`**（服务器待消费队列深度），服务端 `--netstat` 打「队列 / 抖动上限 / **累计丢弃**」
    >   ⇒ 翻案条件要的读数**有数据源了**（缺口是**没有真对局读数**：今天的真链路批是干净网络，无丢包/抖动注入）。
    >   ★★ **代价照实说**：丢一包 = 服务器少模拟一 tick 输入 ⇒ 客户端靠 C2 回滚纠正一次（单 tick、有界）。
    >   这是"低延迟 + 偶发小纠正"换掉原来的"零纠正 + 永久 ≈133ms 输入延迟"，**手感结论必须真对局读**。
    - **是不是"丢弃"的问题？不是。** 两条丢弃规则都对：
      · 世界包 `tick < _last_snap_tick` 丢掉旧包 —— Godot 的 `"unreliable"` = `TRANSFER_MODE_UNRELIABLE` = ENet **UNSEQUENCED**（**不保证顺序**），所以"新的赢"是正确做法 ✓
        （[`pvp_game.gd`](../../../scenes/pvp_game.gd) `_on_snapshot_world`）。
      · 本人包迟到：`PredictionRollback.on_authoritative` 里 **`if ack <= _acked: return`** ⇒ 旧 ack 被丢掉、锚点不会被往回拽 ✓。
      ⇒ **"丢弃"本身不产生延迟累加**。
    - **真正会累加的是"排队 + 每 tick 只消费一个"**：
      · 生产端：[`pvp_match_client.gd`](../../../scenes/pvp_match_client.gd) 的 `_input_seq += 1` → `rpc_id(1, "send_input", pkt)` —— **每个物理 tick 无条件发一个**（无节流、无"未确认上限"）。
      · 消费端：[`match_host.gd`](../../../server/match/match_host.gd) `if not q.is_empty(): var pkt = q.pop_front()` —— **每 tick 恰好一个**，注释写明是为"C2 1:1 同序"。
      · ⇒ 生产 1/tick、消费 1/tick。**客户端与服务器是两个独立时钟**（相位不对齐、负载不同）⇒ "某个服务器 tick 到了 2 个包"必然经常发生，而消费端**永远不会补消费 2 个**。
      ⇒ 队列长度是个**没有回复力的有界随机游走**：+1 之后没有任何机制把它拉回 0 ⇒ **积压会长期停在几 tick 上**（Task 4 的 `MAX_PENDING_INPUT = 8` 把上限钉在 ≈133ms，**只是限制了上限，没有消除它**）。
      ⇒ 后果：`ack_seq` 长期落后 `_input_seq` ⇒ 客户端每帧重放窗口**永久变长** ⇒ **输入延迟加上去不恢复** + 重放 CPU 上升。这正是 Valve 那篇说的"客户端会反复重放未确认命令"，但 Valve 的窗口由 **RTT** 决定，这里还要**再叠一层积压**。
    - **渲染侧同族问题（Valve 明确点过）**：[`player_replica.gd`](../../../scenes/player/player_replica.gd) 用 `global_position += (target-current)*(1-exp(-k·dt))` = **"朝最新目标点追赶"**，Valve 的原文结论是——
      *"那种'简单地朝最新目标点移动'的插值方案，在包间隔不固定时**表现不如位置历史插值法**"*
      （[中译：Latency Compensating Methods…](https://www.cnblogs.com/sun-shadow/p/19715823)）。它把"丢包/迟到"变成**速度误差**，
      且恒速运动时**永久**滞后 `v/k`（代码自己算过 ≈25px）。★ 仓库已经知道这一点，所以**幽灵体跟原始权威值**（把插值滞后挡在预测面之外）—— 那半边是对的。
    - **正确做法（三条路，按"是否破坏 1:1 同序"排）**：
      1. **服务端驱动客户端 tick**（Valve/Overwatch 的正道：服务器告诉客户端"跑几个命令"，客户端按它步进/发包）⇒ 生产 ≡ 消费 ⇒ 零漂移，
         **不破坏 1:1 同序**（C2 的确定性前提保住）。★ 改动最大：输入时钟换主人。
      2. **发前限流**：未确认数 ≥ N 时**不发**（丢生产端，不丢消费端）⇒ 队列排空、ack 追上。代价：那几帧服务器没模拟 ⇒ 回滚要纠正（**有界**橡皮筋）。
      3. **消费端抽干 + 合并边沿**（"输入是状态，不是命令流"）⇒ 延迟不累加，但**放弃 1:1 同序** ⇒ 必须连带改回滚语义，
         且 `tests/probe/kh_l5_probe` 那条"生产侧每 tick 消费一个"的判据会红（要一起改）。
    - **渲染侧**：**位置历史 + 固定 playout 延迟**插值（Valve：100ms + 前后夹逼查找；Gaffer：缓冲 = 3× 发送间隔）
      ⇒ 丢包被缓冲吸收，**延迟是选出来的常量，不是累加出来的**；幽灵体继续跟原始权威值。
    - **可验的判据**：给 `snapshot_own` 加上服务器 tick，探针里直接读"积压 tick 数 / 未确认数"随时间的变化 ——
      **现在它会在几 tick 上长期徘徊**（不回归 0）；修好后应**长期贴近 0**。★ 这条判据今天不存在。
    - **翻案条件**：上述判据显示积压长期 ≈0（或明确有界且在**衰减**），且孪生/回滚冒烟全绿 ⇒ 本行可销。
