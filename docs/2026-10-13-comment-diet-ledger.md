# 注释瘦身:被删事实台账（2026-10-13）

> **这份文档是什么**：执行"**>100 行的 `.gd` 注释 ≤15%**"（[`comment-style.md`](eng/comment-style.md) §8）时，从代码注释里删掉的**实测读数、推导与事故史**在这里留档。
> **为什么要留**：那些注释不是废话 —— 它们是"这个值为什么是 0.1 / 60 / #639BFF"的依据。额度规则要求它们离开代码，**但依据不能丢**。
> **怎么用**：改某个常量/阈值前，先在这里搜它的名字；确认新依据后再动。★ 本文件**不是规范**，只是台账。
> **行号**：是**瘦身前**的行号（那个版本里的注释已经不在原位）。

## 0. 执行摘要（口径与验收）

- **口径**：`整行注释行 ÷ 非空行 ≤ 15%`，适用对象 = **总行 >100 的 `.gd`**（空行不计；行尾注释不计入分子）。起因 = 仓主 2026-10-13 裁定。
- **规模**：全仓 112 个 >100 行的 `.gd` 中 **102 个超标**，需压掉约 **6,694 行**注释；实测最终 **11,502 → 4,398 行**（注释占非空行 **32% → 15%**）。
- **两条机器判据**（缺一条不算完）：
  1. `python /tmp/cy_gate.py` 的闸门①：>100 行文件全部 ≤15%；
  2. 闸门②：**每个改动文件剥离注释后与 `HEAD` 逐字节相同**（含行尾注释；字符串里的 `#` 不算注释）。
- **分工**：Lead 亲做 8 个文件；五路并行 worker 分别负责 `scenes/**`(23)、`server/**`(12)、`tests/**`+`tools/**`(24)、`ui/**`+`core/**`(28)、`ui_factory.gd`+`server_main.gd`(2)。**全部语句零变化**（102/102 IDENTICAL）。
- **两处过程异常照实记**：
  1. **并发写同一文件**（我分派时范围重叠 + 无法给 subagent 发指令）⇒ 出过一次**相邻重复注释行**（`server_input_sanitize_smoke.gd` 38/39 行），随后被一次覆盖写修掉；复扫确认现在无残留（只剩 3 处"空 `#` 分隔线"的假阳性）。
  2. **守卫幻觉**是本轮**额外**的收获：各 worker 合计改标/删除 **40+ 处**"承诺改漏了会红"的死指针，其中两处是**假守卫**（源码守卫只扫 `pvp_game.gd`，却写在 `royale_game`/`team_game` 里）。
- **本文件是什么**：被删掉的**实测读数与事故史**的落点。改某个常量前先在这里搜它的名字。

## 1. `ui/factory/ui_factory.gd` → 建议落点 `docs/eng/ui.md`

- **2026-09-13 视觉评析**：此前每个界面各自硬编码 `Color(...)`，同一屏里能同时出现 6 种互不相干的色（青/暗青/靛蓝/金/中性灰/纯红）；按钮填充只比底色亮 9 个色阶（**实测对比度 1.05:1**）—— 按钮作为"可点区域"根本看不见。这是"颜色只在本文件定义"的由来。
- **描边亮度标定（实测，不是拍脑袋）**：目标 = 对页面底 ≥3:1、对按钮填充 ≥3:1。第一版 `#3D4A5A` 只到 **2.13:1 / 1.82:1**（截图里确实偏暗）故上调；现行 `C_BORDER` `#5C708F` ≈3.8:1 / 3.3:1；`C_BORDER_DIM` ≈2.3:1（刻意低于主按钮）。
- **`C_GRACE`（掉线中）读数**：底板 = `C_PLATE` 压在地图开阔区 `#78969F` 上 ≈ `#6C8790`（L=0.2253）：本色 `#B89EE6` → **1.65:1**（达不到大字下限 3:1）。达不到不是这一档的问题：该亮度底上要凑 3:1 需文字亮度 ≥0.775 或 ≤0.042，连 `C_TEXT` 也只有 3.11:1。大乱斗排行榜画在 `_board_bg`（黑 0.25）上：本色 **2.24:1**，而 `C_DANGER`（离开）1.59:1、"复活中"的 `C_TEXT_DIM` 更低 ⇒ 本档在排行榜上比既有两档**更显眼**，这是取这个亮度的全部理由。
- **`C_PLATE` 逐档表（WCAG 相对亮度，底色取地图开阔区 `#78969F`）**：
  | alpha | 底色 L | 青血条 | 金残弹 | 白字 |
  |---|---|---|---|---|
  | 0（不垫） | 0.283 | 1.87:1 | 2.26:1 | 2.57:1 |
  | **0.10（现在）** | 0.225 | 2.27:1 | 2.74:1 | 3.11:1 |
  | 0.15（上一版） | 0.199 | 2.50:1 | 3.03:1 | 3.44:1 |
  | 0.45（当年那套） | 0.080 | 4.81:1 | 5.81:1 | 6.60:1 |
  用户 2026-09-15 先定 0.15、同日下调 0.1；这是看过实图后的选择，**别拿对比度理由调回去**。例外：大乱斗排行榜 `royale_hud._board_bg` 单独 0.25（用户点名排除）。
- **队色读数（3v3，底板同上）**：队 A `#639BFF` **1.39:1**（裸地图 1.15:1）；队 B **2.96:1**（裸地图 2.45:1）。历史值：`#63FFF3` 3.11:1、`#73D9FF` 2.38:1、`#FF9E73` 1.89:1、`#8FC0FF` 2.03:1。H185 S50 V100 量化回测 **185.20°**；两队互辨 **2.13:1 / 33.3°**（旧值 2.24:1 / 43.1°）。★ 六人同框图在 `.superpowers/sdd/`（不入库）是**旧口径**，新口径未重取图。
- **槽位三态**：初版 `C_SLOT_EMPTY` 明度≈底板 ⇒ 空格"看不见"、4×2 格阵形状读不出、容量指示器失效；用户"青色要蓝一点、透明一点" ⇒ 三档统一 alpha 0.5（取色断言必须先做屏幕合成，否则恒红）。
- **Godot 默认主题实测（为什么必须自绘）**：房间行与页面底 **1.01:1**；色相滑条轨道整条不可见；`LineEdit` 1.01:1 且占位符与真输入同样亮；`CheckButton` **开=浅灰药丸、关=小灰点且轨道不可见**（自绘开关图标的由来）。
- **面板必须不透明**：半透明会让下层菜单文字透上来重影。双线（凿刻感）= 两层 `PanelContainer`，内层只画 `C_INNER`、不画底。padding **48/34 → 64/46**。`menu_style_probe`（**已删·2026-10-09**）的两条位置断言（内亮线内缩 1px / 内层宽度 < 外层 −2px）与实测 `body.rect == (0,0,外层全尺寸)` 是那次迁移的判据。
- **像素风**：直角、整数边宽。定宽单位推导：拉丁 `less_perfect_dos_vga` 8×16（半角 8px）+ 汉字 Unifont 16px 网格 ⇒ 32px 字号下半角 16px、全角 32px ⇒「1 单位 = 半角字符宽」；**换字体要重算 `max_units`**。
- **交互细节**：点击音双响成因（handler 各响一声 + ESC 同路径；`"ui"` 不在 `Sfx.PITCH_VARIATION`）；键位格 200×40 / 返回键 280×48；各页输入框 240×36 / 250×40；`menu_filter_button` 已删、由 SubResource 接管；switch icons 懒建共用。

## 2. `server/server_main.gd` → 建议落点 `docs/eng/netplay.md`（另标注的除外）

- **四角色语义与 K 键自杀**（闸在 `_on_suicide_request`）；`--roles`/`--teams` 必须同序等长；设计 §4.5「三态化清单」原先只列四处，**suicide 闸是第五处二分**，规则 7「不分死因」+ §10 → `docs/eng/modes.md`。
- **专用大厅开机 30s 自杀**（`78aeeb7`，2026-09-28）。两处**未落纸**的边界：① `NetBus.start_server()` 失败那支早退会跳过 `set_process(false)` 收尾（哪天把它变成"重试"口子就重开）；② 已删守卫 `duel_spawn_timeout_smoke` 判据③原文 —— **本行须在 `_ready` 内、`add_child(RoomManager.new())` 之后、两者间无早退；`_run_worker` 内不得有它** ⇒ 建议落 `registered-debt.md`。
- **版本自报**是发布机（无 git）的唯一依据；局域网 IP 打印/写盘供朋友填「服务器地址」，**私有网段排前**；Dedicated Server 导出**无控制台** ⇒ 落盘 exe 旁 `local_ip.txt`；公网联机需转发 UDP 7777 + worker 端口段（部分 → `RELEASE.md`）。
- **`_kill_port_holder` 已收进 `core/net/proc_util.gd`**；`Select -ExpandProperty OwningProcess` 是**踩坑才修对的**（2026-09-06）；原守卫 `kh_l5_probe` 第 3 条**已删**。
- **事故史**：① 原 M1 现象（可用 <2 只重置计时 ⇒ worker 僵死占端口、大厅 30s 回收后撞车）；② 自检 **B2** 三症状（对手颜色不生效 / 昵称表空到连自己头顶 ID 都建不出 / 禁武器闸门没上）根因 = 把载荷**推**给正在切场景的客户端（同一次 poll 静默丢失）；③ `--matchsync-diag` 的来历（2026-10-03 客户端收不到任何 `match_sync`；已排除 `can_send_to_server()=true`、`rpc_id` 返回 0(OK)、定向通道活着 `snapshot_own` 60Hz、worker 日志无 error）；④ `957ac69` 已刻意抑制 1v1 补态那一路的出生点校正。
- **零散单行事实**：三条"读数分母同源"；`destroyed`/`teams` 非空才带（双向兼容、每局多几 KB）；收齐全部人类即开局；`RoyaleHost` 散点出生；1v1 规则项以房主（role1）为准；AI 昵称 `电脑玩家%d-computer`；色相缺省 0；尚未开局的缺席从收人表摘除、3v3 掉光交 30s 梯；尚未满员时如有 claimed 玩家掉线即退进程。
- **测试开关** → `docs/eng/tests.md`：`--test-destroy-tile` 值形如 `"136,64,3.0"`（delay 可省 ⇒ 3.0）、`--test-ground-teleport` 仅测试用。

## 3. `scenes/player/player.gd` → 建议落点 `docs/eng/player.md`（另标注的除外）

- **squash 两条路径的实测**（原 `:302-316`）：梯子下行 k≈0.735 被钳到满幅 −10%（`scale=(1.1000,0.9000)`），是**真违规且每帧**；水中那条**不重叠**（`Water.feet_offset` 取碰撞箱底边 ⇒ 脚底探针恒落在 wall 支撑格里 ⇒ `in_water ∧ on_floor` 重叠 **0 帧**）⇒"站池底永久 ~9% 挤压"并不存在；过滤它买到的是下沉窗口 30 帧的 `_air`（320/700×0.30≈0.137 → `(0.9863,1.0137)`）。
- **副本侧同口径已补**（2026-09-20，`player_replica._in_water`：本地网格查询、零协议字段）；**爬梯那一半仍是残留**（spec §4.3）→ `registered-debt.md`。
- **加速走速度域的手感实测**（原 `:209-211`/`:184-187`）：缩放 delta 只有坠落变快、跳跃变低、移速不变；`_push_haste_mult` 三个消费点（游泳走调用参数、攀爬/武器走注入成员），服务端写点 `match_host.gd:223`、快照读点 `match_snapshot.gd:30`。
- **字符串反射的三种失败形态**（原 `:981-1004`）：`get` 拼错**静默返回 null**、`set` 拼错**静默不写**、`call` 拼错报通用错误并**中止整个 `rewind_restore`**；Godot 4.7.1 对 `class_name` 类型的未知成员只当**警告级** unsafe 访问（`project.godot` 未把 `unsafe_*` 升成错误）⇒ 类型化买到的是"当场点名成员带行号"，**不是**编译期红。同族真事故 `world_rewind.gd:98-103`（`_current_slot` 改名 ⇒ 快照空字典 ⇒ 第一个键就早退 ⇒ 位置/HP/武器全不还原；改回退役名 ⇒ `rewind_probe` 7 条红：位置差 276px、HP 30≠50、HUD 血量通知未触发；引擎每帧报 `Nonexistent 'int' constructor`，同一跑 83 行）→ `player.md` + `tests.md`（变异案例）。
- **回溯保真两处缺陷的仪器原文**（原 `:1005-1039`）：发现 A（切枪帧 index=1 mag=9 → 入树后 mag=4）、发现 B（快照 `wmags=[11,1]`/`widx=1` ⇒ 切枪后 `held[0].mag=3`）；S8-A/B/C/D 四条变异各自变红的对应关系。**覆盖上限**：S8 直调本函数、**不覆盖真回溯的帧选择**，PvP 那份 `MatchHost._apply_rw_frame` 行为侧无 headless 守卫 ⇒ 归真链路批 A。
- **`apply_mag` 顺带钳位 `[0, mag_size]`**：其中"范围内逐位等价"是**推理非实测**；越界档（"快照之后那槽换型号"）无任何断言（债 **§六.3** —— ★ 2026-10-13 订正：原写 `§六.13`，按内容核实那条是"武器子字典写回无守卫"，钳位这条在 §六.3 里）。→ `registered-debt.md`
- **背包化前的旧语义**（原 `:822-827`）：`reset_mag_state → equip_type(default_type()) → refill_current_weapon` ＝"复活即回默认枪 + 满弹"；现今单机重开由 `Level0.restart_single` 统一重置，联机复活"除随机一把外全丢"。
- **联机长按丢弃曾形同虚设**（原 `:843-850`）：早先 `if pvp_mode: return`，当时阈值 2s（现 0.6s）；`LocalInputSource` 的 drop 读口当时报"Q 按着" ⇒ 碰一下 Q 就丢、按住每 tick 丢一把。
- **`host_level` 的实测**：探针里给 `current_scene` 赋值**不生效** → `tests.md`。
- **重建世界偶发原生段错误**（重启后蓝屏/地图未加载）；推迟一帧与 `safe_change_scene` 同因（立刻摘树触发 CanvasItem EXIT_TREE）。

## 4. `scenes/mp_lobby.gd` → 建议落点 `docs/eng/ui.md`（另标注的除外）

- **骨架迁移的判据与读数**：四状态（chrome / 加入面板开 / 创建弹层开 / 等待室开）改前改后**逐像素差异 0 / 2764800**；骨架由 `tools/gen_menu_scene.gd` 生成。
- **房卡宽的双来源**：代码 `_card_width()` 公式 vs `.tscn` 的 `CardGrid` `offset_left/right + h_separation` —— 改一个要改另一个，错位**不报错**。
- 压暗罩 `Color(0,0,0,0.55)` 与 `ui/screens/match_result.gd` 的 `MASK_COLOR`、暂停菜单**逐字同值**（调色板纪律的已知例外）。
- **多表加入的时序论证**（→ `docs/eng/netplay.md`）：1v1 `join_room` 成功**立即**回，royale/team 是 `call_deferred`+`await` ⇒ 正向一到就关闸会让 absent 漏出去、**花掉一次性刷新额度**（之后第一张真陈旧卡片被拒时反而不会自动刷新）。
- **三模式"已在房间中"文案各自点名**；闸门只挡最后那一次 RPC，两颗入口按钮由 `_show_wait_room` 直接收起 —— **两半缺一不可**（→ netplay.md）。
- **`time` 键的权威那一份在 `_player_options()`**（`match_host.gd` 读 `options.get("time")`），建房载荷里的 `time` **没有任何读者**；1v1 必须排除它的理由（`beta_mode` 会话级 + `create_room` 冻结签名 ⇒ 无法按 beta 隔离 ⇒ 没勾 Beta 的玩家能打进带时间经济的 1v1）。→ netplay.md
- **端口段单一来源 = `WorkerLauncher` 常量**；旧页手写 "7800~7999" 而实际池是 **7800~8299**（照它放行防火墙会漏掉半个池子）。→ netplay.md
- 限时上界 15 = `ROYALE_MATCH_TIME_CEILING` 上界链的**第三环**（`Settings.royale_match_min` 写入端）→ `docs/eng/modes.md`。
- 3v3 模式色刻意不用蓝（`#639BFF` 就是 `C_TEAM_A`）；模式色定义在 `ui/factory/ui_factory.gd` → ui.md。
- `C_WARN` 被钉死为「弹夹见底」单一语义（不借来表"私密"）→ ui.md。
- 名单行 `UiFactory.fit_name(名字, 14)` 定宽截断；不截会顶宽（卡宽固定）⇒ 整行错位 → ui.md。
- 标题带内边距 **16/8 → 28/14 → 20/12** 是**第二份字面量**（工厂那条不带右侧角标）⇒ 两边手改同步。
- 「配对已取消」那一支的语义（已入房后房主/对端掉线被大厅取消 ⇒ 直接刷新、不叠加闸门）、`_settle_multi_fail` 的"推迟到帧末"同因、`_ack/_sent_ms` 与 `_got` 的字段说明 —— 文件头/邻近处已有等价说明，本处删。

## 5. `scenes/pvp_match_client.gd` → 建议落点 `docs/eng/`（逐条标注）

- **队色比值的实测链**（→ ui.md）：旧实验图 `.superpowers/sdd/_t6_tint2.png` 第②列是一坨**灰紫**；2026-09-19 复测队 1 得 `#639BFF` **逐字节相等**、当时队 2 token `#63FFF3` 也逐字节相等；2026-09-20 队 2 token 改 `#80F4FF`；队 2 比值分量 >1（g=244/155≈**1.574**、r≈**1.293**）；hue 旋转**表达不了** S50（新青 `#80F4FF` = H185 S50 V100）；hue shader 的"纹理乘两次"bug 2026-09-19 已修。
- **`BODY_BASE_COLOR` 读数**：12987 个不透明像素里主色占 **10875（83.6%）**，次色 `#5585D9`；复测法 = `alpha>200` 过滤取众数。→ ui.md
- **跨纪元 ack 的完整机制**（→ `docs/eng/netcode-input-uplink.md`）：服务器在 `_on_reclaim` 把 `_ack_seq[role]` 归 0；客户端要到 `_on_resumed` 才归零。**哑火窗口实测 ~560 帧 ≈ 9s**（一局中段可上万帧）；症状 = 不报错、回滚恒 0、`sync_soft_state` 不再被调用（地上的枪没了、手上也没多、还开不了火）。
- **三处"对象反射 → 点访问"的改造口径**：R11 明令不给 player 根加 `class_name`；S11 那条 ×2 计数判据；债单 §六.7 的**死锁形状**（进/出必须读宿主自己那一个 `input_source`）。
- **KH 分支复制粘贴残留事故**：多留 `var ts := …` + 又一次 `TileHitFx.spawn(… cell.x …)` ⇒ `cell` 未声明 ⇒ **整个脚本解析失败**（不是"多播一次粒子"）→ netplay.md。
- **客户端子弹 `collision_mask = 5` 而对手是层 2 幽灵体** ⇒ 物理上**永不接触**；观感"伤害算到了却像穿透"；判据与服务器裁决同常量同公式（`HIT_RADIUS` + 环面最短距离）。
- **层位实测**：`match_result.tscn` **150**、三个 HUD 130、小地图 131、`status_banner.tscn` **140**；`.new()` 会拿 CanvasLayer 默认 **1** 被盖住（两处同款陷阱）。
- **第二条 MATCH_OVER 载荷的三条可达路径**（→ modes.md）：`server_main` 每次 reclaim 成功重播 `round_state`；`team_host._finish_match` 直接 PLAYING→MATCH_OVER；倒地边沿检测在 match `_round_state` 之前且不看状态。
- **结算页安全网的可达形状**（→ ui.md）：载荷混进非字典节 ⇒ `_build_section` 参数类型转换失败 ⇒ `show_result` 在 `visible=true` 之前结束 ⇒ 玩家卡死。★ **不**构成陷阱的那条：`_build_result_payload()` 内部抛错只让它自己结束，签名 `-> Dictionary` 使 null 被强转空字典 ⇒ 退化成"可见但空"（实测 `visible=true`）。
- **幻影空洞机制 + "先还原 + 再应用 == 服务器的 grid，不上线任何新字节"的论证**（→ netplay.md）；顺序反过来症状与"根本没还原"逐字相同；`reset_destructibles()` 只重铺瓦片层 + 重建碰撞（**不碰**玩家/子弹/地面武器）。
- **拾取插桩的两种成因分类**（→ netplay.md）：① 静默 `return` 没建出枪；② `canonical_pos` 与画出来的位置分家。判据 = 玩家 400px 内每 30 物理帧一行，`canon/render` 两栏是重点。
- **`NetBusExt` 里有同名遗留的 `beam_fired`**，挂错节点 = 静默 no-op（对手的枪凭空消失/永不再现）。
- ★ **一处过期事实已顺手订正**：原注释写"客户端不知道服务器侧'自己刚丢下'冷却、要消掉得让 `weapon_spawned` 带 `by_role`"—— 代码里 `by_role` **早已上线**；已按现实改写（与服务器 `_live_self_drops` 同口径）。
- **重连时间线本机实测**（→ netplay.md）：尝试 @0.15s → `connection_failed` @**31.81s** → tick 在 ~**33.8s** 判超时（当年宽限期恰好 30s）；ENet 自身连接超时 ~31.8s；一次成功握手约 2~3×RTT，故 5s 覆盖到 ~1.6s RTT。
- **reclaim 只发一次的不变量**（→ netplay.md）：worker 接受第一次时 `_grace.leave(role)`，第二次必不成立 → **踢连接**；症状"刚重连上几秒又断"，而且 token 是对的 ⇒ **查 token 查不出**。
- **菜单守卫的订正史**：`NetBus.stop()` 置空 `multiplayer_peer` ⇒ 引擎 `set_multiplayer_peer` 先 `clear()`、`last_connection_status` 当场复位 ⇒ CONNECTED→DISCONNECTED **从未被观测** ⇒ `server_disconnected` **不会发**；`PauseMenu.go_menu()` 走直接 `NetBus.stop()`、连 `toggled` 都不经过 ⇒ "ESC 会引发重连"**不存在**。
- **对手离开的两种到达时序**：通知先到 / 断开先到 —— 判据"不论谁先到，结局都是 2.5s 后回主菜单、不叠加 60 秒重连循环"；60 秒那条路的第二个后果 = 把刚建出来的主菜单当 `old` 退役。
- **共享基类收口的量化**（2026-09-14）：7 个函数、合计 **58 行代码逐字相同**，`_physics_process` 是 C2 心跳 → netplay.md。

## 6. `scenes/**`(其余 23 个文件) → 建议落点逐条标注

**背景取景与镜头运动(→ `docs/eng/ui.md`)**
- `main_menu.gd`：背景取景 **150%** 的像素完美取舍（72/32 = **2.25×** 非整数）；`BG_CELL_PX=32` ⇒ 4800×3200 ≈ **61MB**，烘到 96 会 553MB；整数倍邻近档 30.0 / 20.0。镜头运动量级：`SEGMENT_SEC` 48s、平均 ≈36 格/48s ≈ **54px/s**（峰值 81px/s）、一整圈 3 段 ≈144s、梯形剖面峰值 1.33×。浮现动画现值 0.6/0.45/0.09/0.28 ≈ **1.35s**（原 ≈2.5s）。`ROW_W=760` 的算法（1920 − 边距 76 − 两栏 1.25:1 ⇒ 左栏内宽 ≈850，见 `info_menu.gd`）。
- `royale_game.gd`：`ROLE_COLORS` 生成口径 —— 色相 **22.5° 等分**、S=0.45 / V=1.0 pastel、16 色。

**换场与退役(→ `docs/eng/render.md` 或 `tools.md`)**
- `level_0.gd`：换场耗时实测 —— 第 1 次 **2.21 / 13.06 / 31.86 / 53.90 ms**；第 2 次 **3.21 / 14.68 / 21.72 / 79.54 / 133.28 ms**；退出码 **139**、6264 个 CanvasItem + 3 shader 泄漏。

**敌人(→ `docs/eng/enemies.md`)**
- `enemy_base.gd`：`_in_water ∧ is_on_floor()` 敌人实测 **239/1350 帧**；过滤会吃掉 **13 次真实落水挤压**（max scale.x 1.0000→1.0861）；玩家侧 **0**（池底上方 0.02~0.18px）；原探针已删、**从未重测**。
- `enemy_fly_base.gd`：LOS/BFS 缓存 **TTL≈150ms**（@60Hz）；障碍只收 ≈600px 内的实体。

**副本与插值(→ `docs/eng/netplay.md` / `player.md`)**
- `player_replica.gd`：`SNAP_DIST=128px` 的依据（v/k=25px；探针 ±0/±8/±16ms = 22.6/29.7/37.2px；丢包 200ms ≈60px；回溯/重生几百~几千px）。脚底探针 1px 差：本体首帧缓存 **58.0**（5 箱合并）vs 副本 **57.0**（stand）。squash 配对后果：水中下沉持续 ≈**9%** 挤压、冲刺起步满幅 **−10%**、爬梯残留 **2.5~3.0%** 拉伸 / 梯底 ≈**6.3%** 挤压。
- `team_game.gd`：队友不互挡的层/掩码契约表（1 队 layer2/mask21；2 队 layer16/mask7；幽灵体 mask0）。

**武器(→ `docs/eng/weapons.md`)**
- `weapon_base.gd`：鼠标→世界换算**不能 ÷ `crop_scale`**（crop 只定比例），否则瞄准"水平"实际偏下、榴弹弧线贴脸。
- `laser_weapon_base.gd`：`CollisionAabb` 曾认不出多边形、身体框退化成原点周围 **36×36** 的兜底值。

**UI 实测(→ `docs/eng/ui.md`)**
- `settings_menu.gd`：字色 `C_WHITE` vs Theme `C_TEXT` 实测差 **9220 像素**；按钮 32 号字最低高 **72**。
- `pvp_game.gd`：P2 染色的数学依据 —— 色相旋转保持 S/V，本体主色 S61 ⇒ 产不出目标 S50；**比值法输出恒等于目标 token**。

**本轮抓到的两处"假守卫"(值得单独记)**
- `royale_game.gd:60` 与 `team_game.gd:38` 原写"`tests/probe/rollback_fidelity_probe` 有源码守卫钉这一行"，而该守卫只扫 `res://scenes/pvp_game.gd`（探针 `:153`）⇒ **两处假守卫**（`pvp_game.gd:40` 那处是真的，已保留）。已改成"零守卫：该源码守卫只扫 `pvp_game.gd`，不覆盖本文件"。
- `weapon_base.gd:246` 原写"判据：本文件里 `Input` 紧接 `.is_action` 的子串命中数必须为 0"—— **全仓无此守卫**（`grep tests/` 无 `weapon_base` 引用）⇒ 已改成自律条款 + 零守卫。

**其余守卫幻觉已就地改标"零守卫（已删·2026-10-09）"**：`kh_l4_visual_probe`、`reconnect_smoke`、`menu_weapon_grid_probe`、`info_page_probe`、`enemy_logic_smoke`、`net_ground_probe`、`tests/manual/hue_tint_probe`、`hud_declarative_probe`、`settings_display_section_probe`、`settings_esc_probe`、`rewind_weapon_probe`（S10，两处）、`kh_l5` 字号检查器（死引用，随块删）。★ 保留的**真守卫**：`menu_autotest.gd`（仍在库）、`replica_smoothness_probe`、`rollback_fidelity_probe`（对 `pvp_game.gd` 那处）。

**遗留(不属额度范围，供后续处理)**：`scenes/player/swim_component.gd`（≤100 非空 ⇒ 额度豁免）仍有 15 行注释带 Markdown；`scenes/effects/{grain_crystal_fx,time_glow}.gd`、`scenes/enemies/{enemy_black_bird,enemy_bullet,enemy_spawner}.gd` 共约 22 行注释仍带 Markdown（均已达标，本轮按"不动"处理）。

## 7. `server/**`(12 个文件) → 建议落点逐条标注

**计分 / 状态(`match_state.gd` → `docs/eng/modes.md`)**
- `destroyed_cells` 上限 **841（≈8~10KB）** 是**已退役**旧定图 `factory1v1.cyrm`(150×100)上"可破坏纹理格"的实测数；旧注释"全拆光 15k 条"把**地图格数**当上限、**松约 18 倍**；换图后可能不再是新图上限。
- `ATTRIB_FRESH_MS=8ms` 完整推导：真实命中在同一调用栈 0~1ms，上一物理帧归因 ≥16.7ms；**延迟扣血型伤害必须自己每帧重写归因**，否则静默判成无攻击者（ACS 偏低）。
- 已知边界（登记不修）：同一帧内先被敌人打中、再被自己的爆炸炸到 ⇒ 记到**敌人**账上。
- 助攻死代码的失效条件②：`same_team` 若变成**非传递**（联盟），被删的 `or` 不再死，且 (k4) 照绿。
- `_rw_on`/`_rw_trail` **必须声明在根基类**（子类符号编译期解析不了）→ netplay.md。

**战斗 / 归因(`match_combat.gd` → modes.md / world.md)**
- v3 过期口径（`*2` = 32px/2×2）会把邻格象限清出 4 个洞、被拆那格 16 子格一个没清；守卫 `destroyed_cells_probe` 相③ **已删**。
- 基类写 attribute 顺带闭合的第二件事：1v1 原先 `remove_meta("last_self_hit_time")` **永不执行** ⇒"自己炸自己后 8ms 内被敌人打中"记成 `self_damage`；守卫 `stats_delivery_probe` ⑦ **已删**。
- `RoyaleHost`/`TeamHost` 的**同名覆写仍留着**（与基类重复但幂等无害；删它会作废 `modes.md` 与 `team_host_probe` 以那两处为锚点的整段登记）。
- 四条伤害来源 + "**归因写入先于 `take_hit`**"的权威落点：`core/sim/explosion.gd:62`、`scenes/weapons/laser_weapon_base.gd:233`。

**地面武器 / 落点(`match_ground.gd` → weapons.md / tests.md / netplay.md)**
- `--test-ground-teleport` 来历：机器人只会"水平走 + 卡住跳"，窄台上**永久卡死**（实测两轮都栽在这）。
- 2026-09-17 前的真坑：`entries[].pos` 曾是"判定圆心" = canonical + visual_offset（手枪 ≈**60px**，而拾取半径仅 **64px**）。
- 载荷 vs 生成事件的语义差：重连沿用"生成时 vel"会重演约 **2 格**下落；原守卫 `ground_action_probe` ⓪/⑦ **已删**（零守卫）。
- `_handle_ground_actions` 调用约定：**在消费输入包之后**调（边沿刚写进 `PacketInputSource`）→ netplay.md。

**回合 / 重开(`match_round.gd` → modes.md)**
- `_round_full_heal` 生效时机 = 倒计时结束时（含换局后的第一拍）。
- 旧实现把复活调度塞进**计分闩锁** + 调 `get_meta_or_null`（Godot 4.7 **不存在**）⇒ 抛错中断、复活永不安排、**局永远推不完**。

**宿主(`match_host.gd` → netplay.md / registered-debt.md)**
- 字符串反射→类型化的**三处逐字行为差** + 守卫 `rewind_weapon_probe` S9（已删）。
- **覆盖上限照实**：`_apply_rw_frame` 行为侧（值对不对）**零守卫** ⇒ 归"真链路批 A"。
- 回溯机语义：环缓只存自己 + 自己的子弹、**已爆榴弹不复活**；回溯期 frozen/免伤、子弹照常伤害他人（用户裁定）。

**大乱斗宿主(`royale_host.gd` → world.md / modes.md / netplay.md)**
- `plan_spawns` 回退分支：实测两图池 **122/59** vs 人数上限 8（今天不可达）；**不收窄**的理由 = 池极小时收窄会让补足补不满 ⇒ `(-1,-1)` 更糟。
- **走光候选集必须含 `_left`** 的完整论证（0 杀离开者两边都不在 ⇒ 独胜误判）；只在幸存者 ≤1 时改变结果；守卫 `late_match_probe` ④/⑤/⑤b **已删**。
- 原先靠事后 `host._round_spawns = spawns` 覆盖**为何形同虚设**（`_spawned_once` 已闩）。

**3v3(`team_host.gd` → modes.md)**
- `plan_team_spawns` 重试循环实测：200 次里 **123 次（61.5%）**"队间最小距 ≤ 队内最大距"、最坏两队同格；修复后 **200/200** 满足，最差队间距 0 → 20。
- `_apply_team_layers` 抽成函数的原委（探针手工摆位时 `players` 为空，否则要抄第二份真相；`team_host_probe._place` 已删）。
- `_start_next_round` 覆写的首要理由：此前 ROUND_OVER 虚分派到基类，而队号 `{1,2}` 与 role `1/2` **字面撞号** ⇒"碰巧对但不是语义对齐"（守卫 `team_host_probe` ⑨ 已删）。
- `_threshold_team` 的三个读者（要不要进 / 报哪队 / 是否已决出）+ 常量失效的静默面。
- `_attributed_killer` 为何自带一份（基类不得含子类方法的**反向断言**；两份读同一 meta）。
- 层位占用表：**1 地形 / 2 玩家 / 4 敌人 / 8 掉落物 / 16 队 B 身体层** → netplay.md。

**房间编排(`room_manager.gd` → netplay.md / registered-debt.md)**
- `ROYALE_MATCH_TIME_CEILING` 的两环链（settings 钳位 / `mp_lobby` 秒换算）+ 残余暴露 **~3~25s**。
- **1v1 刻意没有在局宽限**的完整不对称论证（房龄 ≥2h + 一局几分钟 ⇒ 量级够不着；但同一"开局转连窗口"在 1v1 同样成立 ⇒ 要收紧需另行评估）。
- `ai_duel` 的真实可达路径（已配对开局的 1v1 房在 `go_match` 后、`on_peer_left` 摘除前收到 AI 请求 ⇒ 再拉 worker **覆盖 `worker_port`** ⇒ 首个端口无人归还；RPC `any_peer`，暂无界面调用点）。
- 凭据表 GC 搭在 30s 回收梯上的理由（再立一条梯 = 第二个定时器）。
- 建局引导已搬到 `server/match/match_bootstrap.gd`，调用点在 `server_main.gd`。

**大厅账本(`lobby_rooms.gd` → netplay.md / ui.md)**
- `RoyaleRoom.match_time` 与 `player_options.match_time` 是"**同一处两真值**"。
- `new_token` 实测：12 次抽样 **8 次**落 int64 负半区（`%x` 带符号打印）；2 万次抽样两段 `%08x` 长度全 16。
- `join_room` 已在房里拒绝的后果：`player_role` 从 1 **覆盖成 2** ⇒ 同 peer 占两 role、worker 侧两 role 指同一 peer、输入只喂得到 role 1。
- "该房间的对局已进行中"会命中 `mp_lobby._on_server_message` 的**自动刷新分支**（故不能说"房间已满"）→ ui.md。
- `_flush_*_state` 实测：断开信号**滞后超过一帧**、6 人局开局后瞬间 5 条 `max channels: 0`。
- `on_room_map` 不回话/不踢人的取舍 + 刻意不判空房。
- 三表房号空间重叠；三表**房主表示不同**（1v1 无 `host` 字段）；回局路径乙的已知边界（认领时已不在宽限期 ⇒ worker 的 `_on_reclaim` 踢连接）。

**其余**
- `rejoin_registry.gd`：token 原住 `Room/RoyaleRoom/TeamRoom.tokens`，随 Task 4（2026-09-21）整体删除（`grep .tokens` → 0 命中）；TTL 取 1h 的理由 → netplay.md。
- `worker_launcher.gd`：**30 → 120** 的教训与"承重的是 worker 存活、**不是**那条延迟"的推导；`grace_window_smoke` ⑧ **已删** → netplay.md。

**同类事实别处已有更好落点 ⇒ 直接删并点名**：掉落理由 → `MatchGround._drop_all_but_one`；归因先于伤害 → `MatchCombat._on_bullet_hit` / `_grenade_direct_hit`；`worker_pid` 判据 → `Room.worker_pid`；roster 冻结理由 → `LobbyRooms.freeze_roster`；三档端口延迟数值 → `WorkerLauncher` 顶部常量；两个归因窗口 → `MatchState` 两个常量；3v3 队号校验 → `WorkerLauncher.spawn_team_worker`。

## 8. 守卫幻觉:本轮就地改标"零守卫（已删·2026-10-09）"的（汇总）

- `ui/factory/ui_factory.gd` / `server/server_main.gd`：**12 个**（`menu_style_probe`、`ui_palette_single_source_smoke`、`menu_theme_mirror_smoke`、`kh_l3_visual_probe`、`tests/manual/kh_l4_visual_probe`、`tests/manual/combat_hud_visual_probe`、`grace_window_smoke`、`reconnect_probe`、`match_sync_probe`、`royale_bound_probe`、`team_host_probe`、`kh_l5_probe`）。
- `scenes/pvp_match_client.gd`：`hue_tint_probe` 守卫 D、`reconnect_probe` 相①（★ 该探针是 **2026-10-09 明批删除**、不是改名幸存，台账在 `tests/run_all.sh:123`）、`hud_declarative_probe` 的两处（"出现 `MatchResult.new(` 即红" 与 ⑧ 层位）。
- `scenes/mp_lobby.gd`：三处指向已删的 `lobby_ui_probe` / `lobby_behavior_probe`（全仓 0 命中）；另订正两处过期表述（标题带"探针按 text 读房间号"、"要靠探针数连接数"）。
- `scenes/player/player.gd`：`rewind_weapon_probe`（S1–S8）。
- ★ **仍在库、原话保留**的：`rollback_fidelity_probe` 对 `_rollback.in_contact` 的位置与唯一性断言（该探针存在且确实引用它，属实）。
- ★ **一个零读者写在代码里的实例**：`mp_lobby.gd` 的 `set_meta("roster_row")` —— 全仓只剩写入方，守卫为零（属清理候选，登记用）。

## 10. `tests/**` + `tools/**`(24 个文件,注释 2177 → 1007) → 建议落点逐条标注

1. `tools/room_sweep_lint.gd`：**上界链三环推导**（settings 钳位 `[1,30]` → `* 60.0` 秒换算 → 滑块 `max_value`），以及"取片段/比数值，宁可响亮假红不可静默失明" → `docs/eng/room-lifecycle-conventions.md`。
2. 同文件：`drop_room → drop_port` 改名史 + **三张注册表名互为子串**（只留裸 `rooms.erase(` 会点错名字）→ 同上。
3. `tools/gen_menu_scene.gd`：迁移固定动作 ①~⑦ —— **改名要同改后代 `parent=` 路径**、`ext_resource` id 每次变、落地中性化清单、覆盖上限三条 → `docs/eng/tools.md`。
4. `tools/gen_menu_theme.gd`：`fix_alpha_border=true` 逐像素实测差 **100 像素**；Button 类链把空 CheckButton 从 **(40,22) 撑到 (120,62)**；Filter 五态内联 SubResource → `docs/eng/ui.md`。
5. `tools/_shot_scene.gd`：`addr=` 的状态栏文案**由网络驱动**，改前/改后各落一相（实测差一整行）；四条坏输入路径必须当场退出 → `docs/eng/tools.md`。
6. `tests/probe/tile_collision_probe.gd`：**幽灵砖**（整格碎而 16 子格仍 `sub_alive`，四条探针全绿）；`sub_hp` 是唯一真相源；节流窗口 `MAX_REBUILD_PER_FRAME=2` → `docs/eng/tests.md`。
7. `tests/probe/resync_world_probe.gd`：幻影空洞三维判据；`_paint_maze` 改 16px 子格后旧实现**恒 −1**（前置恒真/结论恒假）→ `docs/eng/world.md`。
8. `tests/probe/replica_smoothness_probe.gd`：旧法读数 **49.6% 零位移**；±16ms 档单帧 **8.242px** 已超 8.0 上限而判词**照绿** → `docs/eng/netcode-snapshots.md`。
9. `tests/probe/snapshot_size_probe.gd`：**0.96KB/人/快照**（整包）基线；**1400B MTU 分片悬崖 N≈27**；`vel` 承重（削掉会静默毁形变）→ 同上。
10. `tests/probe/rejoin_probe.gd`：`--quit-after 600s` 的量级推导（实测 60~100s）；**按端口兜底杀 `LOBBY_PORT` = 自杀**（退出码 255、明细全丢）→ `docs/eng/netplay.md`。
11. `tests/probe/team_match_probe.gd`：`RESULT_WAIT` 逐项求和（**547.4s / 最坏 632.4s ⇒ 取 680**）；"预算算错看起来像产品故障" → `docs/eng/modes.md`。
12. `tests/harness/team_match_watcher.gd`：导航三方案实测 —— 硬走 90s **0 位移**；4 邻域图最大连通区 **77 格（4%）**；自建跳跃图 **1792/2095（85.5%）**；建图 **330ms** → `docs/eng/tests.md`。
13. 同文件：回退模式（留存日志 `killA=0`，无归因击杀）+ `REC BACKOFF` 读数分栏 → tests.md。
14. `tests/harness/rejoin_watcher.gd`：与任务书的 **7 条偏离**；C1 = 主菜单 `PvpSession.reset()` 抹凭据（"别再绕过主菜单"）→ `docs/eng/netplay.md`。
15. `tests/harness/menu_autotest.gd`：导出产物被编译成 `disable_path_overrides=yes`，2026-10-04 起 `exclude_filter` 含 `tests/*` ⇒ **该通道在发布产物里已不存在** → tests.md。
16. `tests/probe/path_integrity_probe.gd`：只查 `RL/DirAccess` 会造 **28 条假红**；**Windows 不区分大小写**故"大小写写错会通过" → `docs/eng/tools.md`。
17. `tests/smoke/playout_clock_smoke.gd`：根因（每收一包重置时钟 ⇒ 缓冲深度 0）；参考改"跟自己的参考"（M12 CAUGHT）→ `docs/eng/netcode-playout-clock-sync-sources.md`。
18. `tests/harness/team_bot_input.gd`：三个带参钩子曾是**恒 false 桩** ⇒ 服务器侧从不跳/不开火（相③ `near` 恒 0）→ tests.md。

★ **两处照实偏离规范**（额度优先）：① 文件头保留 10~16 行（> §5 的 5 行），因为那是"每条一行的不变量集合"；② 保留块里仍有存量 `**` 加粗 163 行（§1 的口径是"新增 0 处、存量随改动递减"）。

## 11. `ui/**` + `core/**`(28 个文件,注释 1874 → 615) → 建议落点逐条标注

1. `core/sim/world_rewind.gd`：旧断言 `invalid_ref_count()==0` **修完仍 30+**（精英不入快照 + 40s 带）⇒ **恒红**；`rewind_probe` 端到端 7 条红（位置差 276px、HP 30≠50、`snap.size()=0`）→ `docs/eng/modes.md` 回溯节。
2. 同文件：形状守卫演进 —— **计数上界（≤5）对"只改字符串不改方法"无牙**（60 条全绿）；`EXPECTED_CHECKS` 60→61→90 → `docs/eng/tests.md` 案例集。
3. `core/sim/spawn_picker.gd`：两图各 4036 布局；只收一档会新增「旧兜底有货 ∧ 新兜底筛空」布局（factory1v1 1 / demo 5），加第③档后 0；池宽 843→130→688 / 670→61→566 → `docs/eng/world.md`。
4. 同文件：`factory1v1`（已退役图）最大地板连通区 **13 格**、843 格里 **155 孤立单格**；`newfactory` 最大连通区 48 ≥ 20 ⇒ **自适应分支生产不可达** → world.md。
5. `core/net/net_bus.gd`：上行实测链 —— 单人条目 **948B**（c2 664B / 70%）、8 人局 ≈**29Mbps** → 446 → 587 → 72KB/s；条目 368→**51B**、884→**102B**；世界包 N≤8 恒 1 片 → `docs/eng/netcode-snapshots.md` §2。
6. 同文件：广播 channel 0/1 的证据 —— 一帧同时报 0 与 1、backtrace 指向 `match_snapshot.gd:34` → `docs/eng/netplay.md`。
7. `core/net/prediction_rollback.gd`：容差扫描 —— 1px **221/195/159** 次（N=2/4/8）；2px 9/85/13；接触期偏差中位 1.6、p95 25~30 → netcode-snapshots.md。
8. 同文件：接触容差 8px N2 5 / N4 8 / N8 5；16/32 **跨轮抖动**（N=4 约 8~21、N=8 约 4~15）且无系统性更低；判据上界中位 ≤3 / p95 ≤35 三档全绿 → 同上。
9. `core/net/snapshot_codec.gd`：变体编码单值开销 —— float 8B、Vector2 12B、`String("pos")` 12B、bool 8B；dict **196B vs 手打包 24B**；世界包 2.1KB→**0.27KB**、本人包 588→**~114B**；trail 16 人×10 点 = 1847B ⇒ 2 片、4 点 ⇒ 1063B（24% 余量）→ netcode-snapshots.md §2。
10. `core/sim/terrain_atlas.gd` + `core/sim/map_format_v4.gd`：`newfactory` 4800×3200 ≈ **61MB**；Godot 4.7.1 `compress()` 传 −1/35/64/1024 **全报错返回 −1** ⇒ 游戏侧只写裸 body；畸形头 `body_size` 曾触发 **17GB 分配** → `docs/eng/world.md` / `render.md`。
11. `ui/hud/hud.gd`：对比度 —— 击杀数深青 **1.93:1** → 深底板 + 强调青 ≈**4.8:1**；防水条深蓝 ≈**1.0:1** → 浅蓝 ≈**3.8:1** → `docs/eng/ui.md`。
12. `ui/hud/minimap.gd`：`EDGE_BOTTOM` 推导 —— 延迟条 `font_size` 32、矩形上沿 y=1367 / 左沿 x=1784、圆心 (1756, 1300−EDGE_BOTTOM)、半径 140 ⇒ 需 >**70.17**，取 72；`PX_PER_CELL` = 140/50 = 2.8 → ui.md。
13. `ui/hud/royale_hud.gd`：每秒重建 N 个 Label 实测 **2.6 / 3.8 / 4.7 ms**（4/6/8 行）；9 字昵称 ≈690px vs 面板 480（→720）→ ui.md。
14. `ui/screens/match_result.gd`：居中 bug —— `custom_minimum_size.x=1120` vs 内容最小宽 **476** ⇒ 右长 **322px**、3v3 B 队四列不可见，**而数值断言全绿** → ui.md。
15. `ui/hud/combat_feedback.gd`：同帧两次 `apply_aoe` 间隔 0ms ⇒"被敌人打中却扣自己分"实测 `self_damage` **+40 而非 +20** → `docs/eng/modes.md`。
16. `core/present/sfx.gd`：噪声 `lp` 1400/900 均 ≥ 1/0.3≈3.34 ⇒ **两段实为纯白噪声、参数等价**（要区分需先试听）→ ui.md。
17. `core/sim/weapon_registry.gd`：`Array[int] [1,2,3] == [1,2,3]` 为真、`== [1,2,3.0]` 为**假** ⇒ 拿 id 数组比字面量 int 数组的断言会**假红** → `docs/eng/tests.md` 末节。
18. `core/config/settings.gd`：本机 `screen_get_size` **2560×1600** vs 可用 **2560×1528**；1080p 屏装不下 1920×1440 基准 → ui.md。

★ 附：整行注释里的 Markdown 加粗 **692 行 → 95 行**（§1；剩余多为原样保留的旧行）。

## 12. 最后 8 支(差额文件) → 建议落点逐条标注

- `core/net/playout_clock.gd` → `docs/eng/netcode-playout-clock-sync-sources.md`（**已在库**）：旧实现（目标 = latest − playout）在 3000 帧固定种子、±16ms 抖动下 p95/max 超出 **+5.8 tick**，且与 playout 4/6/8 无关（5.8/5.8/5.7），均值恒 `playout−0.93`；名义 4 在 ±8/±16ms 下单帧位移顶到 **10.0px**（闸 8.0）；深度补偿扫描 k=0.5/1.0/1.5 ⇒ **只有 1.5 三档全绿**；来源：NTP RFC 5905 §10 / RTP RFC 3550 §6.4.1+A.8 / Valve-Bernier 2003；夹具要求探针**手动驱动时间轴**（墙钟会让抖动夹具失效）。
- `core/config/player_params.gd` → `docs/eng/player.md` + `weapons.md`：`stop_snap` 原在 `player.gd`（`climb_component` 抄过一份死副本）；`charge_velocity` 1500→1900、`charge_duration` 0.6→0.4（600px）；丢弃长按 2026-09-16 定 2s→1s→0.6s；squash 2026-09-21 用户实测"太果冻" ⇒ **三项一起收**（0.10→0.06 / 9→16 / 0.30→0.10，事件强度不动）；8 个同名常量与 `EnemyParams.shared` **刻意不共享**；`cam_zoom` 0.75 = 4→3 整数下采样。
- `ui/screens/pause_menu.gd` → `docs/eng/ui.md`：标题带文案 + 64 号曾由 `kh_l4_visual_probe` 钉住（**已删**）；layer 145 盖 PvpHud 130 / HUD 129 / PostProcess 128；压暗罩 **0.55** 与 `match_result.MASK_COLOR`、`mp_lobby` 逐字同值（调色板已知例外）；`Sfx.play("ui")` 原先只有关闭侧响；`change_scene` 同步析构偶发原生段错误 ⇒ `Level0.safe_change_scene`；`toggled` 是对 KH 原件的有意偏离。
- `tests/smoke/server_input_sanitize_smoke.gd` → `docs/eng/netcode-input-uplink.md` + `tests.md`：`ax=50 ≈ 35000px/s`（全图仅 9600px）；`clampf` 对 NaN 不能假设 ⇒ 先判有限性；队列 ρ≈1 零漂移随机游走，**实测开局 1 秒内 0→8 后不再回落**；生产/消费 1 包/tick 是 C2 的 1:1 同序要求；读数分母 11+6+4=**21**（计数闸）；返回值 = **丢之前**的原始深度（包络靠它学习）；"上限缩回去"就是缺失的回复力（堆 6、收到 2 ⇒ 一次释放 4 包）。
- `ui/hud/team_hud.gd` → `docs/eng/ui.md` + `modes.md`：`TEAM_KILLS_TO_WIN=9` 在 HUD 里是**字面量**（引 `TeamHost` 会把 `MatchHost` 整条链拖进客户端）；`mwinner==0` 是 3v3 **新可达值**（两队走光 ⇒ 平局），照抄 `pvp_hud` 的 1v1 兜底会念成「P2 获胜」，样板是 `royale_hud`；`_big/_sub` 转发现在是**零读者**（两探针已删）⇒ 清理候选；本页是最小可用版式。
- `core/sim/grain_account.gd` → 主策划案「怀表」一节 + `docs/eng/modes.md`：口径 = 白短针余额 `GRAIN_CAP` / 红长针主圈 `SHORT_WINDOW`（顺时针推进·逆时针拨回）/ 额外 1/4 圈 `LOAN_LIMIT`（恢复 50/s）；`loan_depth` 是世界反馈驱动量（变亮/色差/敌加速/变调）；锁定期任何技能取不出颗粒（按了也空转）；2026-09-28 参数化（单机 `TimeParams` 行为逐位不变）；入账例：乌鸫击杀 300。
- `core/config/time_rules.gd` → `docs/eng/modes.md` + `netplay.md`：用户裁定"启用贷款、**仅限**短时限额、账户不透支"；`DEF_HASTE_MULT` 固定 ×3 **不进建房页**；`clamp_self()` 顺序 = 先钳 `window`（贷款上限由它推出）、再钳 `cap ≥ initial`；建房页滑条与服务器**共用同一套 `R_*`**；`rewind_buffer_seconds = min(cap / rewind_burn, 15)`。
- `core/net/local_server.gd` → `docs/eng/netplay.md`：冷启动 + bind 实测 **6~30 秒**（磁盘/安全软件扫描）+ netstat 自身耗时 ⇒ 每秒探一次、最多 45s；强杀后立刻复用端口**偶发失败** ⇒ 等 0.8s；按映像名 taskkill + 端口占用者兜底（**否则新实例 bind 失败静默退出**）；`lan_ip` 私有网段优先 192.168 > 10 > 172.16–31。

★ 过程记录：这 8 支由**两个 worker 并发**落笔（12:03–12:08 逐支推进，两轮），其间 `server_input_sanitize_smoke.gd` 一度出现**逐字重复的同一行注释**（读-改-写竞态），随后被一次覆盖写修掉；复扫确认无残留。**最终以文件最终态 + 闸门结果为准**（额度 0 超标、104/104 语句 IDENTICAL）。

## 13. 待补：其余文件的台账

各 worker 完成后按同一格式追加。已完成订正的两处连带项：
- `tools/gen_menu_theme.gd` 里对已删守卫的 3 处引用（`kh_l5_probe` / `ui_palette_single_source_smoke` / `menu_theme_mirror_smoke`）—— 由 Lead 改标"零守卫"。
- `docs/eng/ui.md:24` 原写"对比度实测的唯一落点是 `ui_factory.gd` 的 `C_PLATE` 注释" ⇒ 已改指本文件 §1。
