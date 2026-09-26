# AGENTS.md(KH_v0.5.0 线)

> 上游工程(原作者)的说明在 `CLAUDE.md`;本文件只记**本线新增的时间玩法(第一阶段)**与纪律。

## 个人钟 · 第一阶段(2026-09-26,B1-B6)

**目标**:个人时间颗粒账户(怀表)+ 时空回溯/加速。**仅单机**(`Level0` 建场;PvP/菜单 `TimeField.current == null` → 全倍率恒 1,零影响)。

### 文件职责(全部新增/上游结构落位)
| 文件 | 职责 |
|---|---|
| `core/config/time_params.gd` | 时间玩法参数总表(全 const 可调):初始1000/上限5000/短时窗400/恢复50每秒/回溯120每秒/加速80每秒/贷款额100/快照20Hz40s/加速相对2x/贷款视效映射/乌鸫300 |
| `core/sim/grain_account.gd` | 颗粒账户纯逻辑:余额与短时窗同扣、窗满溢出进贷款、深度=借额/100、贷满强制锁定、50/s 先还贷后回窗、还清解锁、结晶入账夹上限;五信号 |
| `core/sim/time_field.gd` | 世界时间场(静态 `current`):HASTE 玩家与精英 ×2、普通敌与敌弹 ×1;REWIND 普通实体 ×0 冻结、精英照常;贷款深度给普通敌 ×(1+0.5d);余额耗尽当帧停 |
| `core/sim/world_rewind.gd` | 定频快照环缓(20Hz×40s)+ 反放器:玩家位置/速度/HP/朝向/倒地,非精英敌人位置/速度/HP/存亡/可见,子弹场景路径/位置/速度/归属;**尸体保留**(录制期击杀隐藏待复活,超窗清理;精英不保留);`hold_corpses` 静态由 Level0 同步 |
| `ui/watch_hud.gd` | 程序化像素怀表(挂 hud,**血条/氧条下方**):白短针=总量/上限一圈、红长针=短时窗+贷款(额外1/4圈)、右侧 96px 大数字(定长 0.2s 插值动画逐点跳动)、表心短时余额(贷款深红负数);`tremble()`/`flash_locked()`/`absorb()`;入 `watch_hud` 组 |
| `core/sim/tile_ledger.gd` | 玩家拆砖账本(B7 瓦片回溯):记录破坏格的**改前值**,回拨按 t 降序还原(最新破坏先还原=LIFO);与 WorldRewind 共用时间轴;超窗口裁剪 |
| `scenes/effects/grain_crystal.gd` | 乌鸫击杀结晶:10 枚碎片炸开散落 0.28s → 加速飞向怀表(目标按相机会算到 WatchHud 屏幕中心)→ 先到者吸收(入账+颤抖) |
| `scenes/effects/time_glow.gd` | 时间状态高亮(B13):在实体视觉节点下叠**加色混合**的贴图副本(1 或 2 层),`attach/on/set_color`;不依赖 HDR、不与受击白闪抢 modulate |
| `scenes/effects/afterimage.gd` | 加速残影(B12):`spawn(host, animator, tint)` 取当前动画帧贴图做一个半透明副本,0.26s 淡出自毁;玩家每 0.045s 红/蓝交替生成 |
| `ui/time_symbol_hud.gd` | 屏幕中心模式标志(挂 hud):回溯 `◁ ◁` 浅色快闪 / 加速 `▶ ▶` 紫色,按 `TimeField.current` 模式显隐 |
| `render/post_process.gdshader` + `post_process.gd` | 三效果:`rewind_film`(中心向外辐射底片化,≤200ms ramp)/`haste_dim`(背景压暗,角色靠 modulate 高亮)/`loan_depth`(变亮+红蓝色差);统一入口 `PostProcess.set_time_effects(film, loan, haste)` |
| `core/present/sfx.gd` | `static var pitch_mult` 全局音调系数(贷款越深越尖、加速略升、回溯略降;BGM 接入后同源) |

### 按键
`rewind`(Shift,按住)/`haste`(**鼠标右键**,按住)——Shift 已从 `down`(下蹲)摘绑,old 存档里 down 的 Shift 绑定由 `Settings` 读档时自动迁移摘除;`haste` 的旧键盘绑定(曾用 Ctrl)读档时丢弃回落到右键。

### 纪律与不变量
- **单机闸门**:时间系统只在 `Level0` 单机路径建立;任何 PvP/联机场景不得启用(`TimeField.current` 必须为 null)。
- **精英定义**:`set_meta("elite", true)`(乌鸫 `_ready` 自带)。精英=免疫回溯(不入快照)、加速与玩家同步、击杀掉 300 颗粒。
- **回放期伤害语义(B8)**:普通实体之间不结算伤害(玩家 `take_hit` 早退/普通敌整帧早退/子弹不步进);**但倒飞的子弹穿过精英时照常结算**——`Level0._rewind_elite_hits` 每帧对回放弹×精英做距离判定,每颗弹对同一精英只结算一次(meta `rw_hit_ids`),这就是策划案的「回退造成二次伤害」。快照子弹带 `dmg/impact` 供其复用。
- **瓦片回溯(B7)**已落地:玩家拆砖经 `TileDefs.on_destroyed` → `_on_tile_destroyed` 捕获改前值(清空前从渲染层 atlas 读回)→ `TileLedger` 帧末入账 → 回放时按 `(target, cursor]` 区间 **t 降序** 写回四层(网格/9 环面副本/持久子格/脏块);非玩家破坏(未来事件)走别的口,本阶段只有玩家口径。
- 本轮**不动** `Engine.time_scale`(物理/tween/网络不受扰);倍率分两域落地:**delta 域**(实体物理帧首行:重力/计时器/AI 节拍/动画,子弹位移也在这一域)+ **速度域**(水平运动:玩家 `speed_target × mult`、敌人 `move_and_slide` 前 `velocity.x × mult`)。
- **B12 修正(用户:感受不到加速,只觉跳跃变低)**:根因是 `move_and_slide()` 用**引擎自己的 delta**,只在 `_physics_process` 首行缩放 delta 只改了重力与计时器(所以"坠落变快、跳跃变低、移速不变、敌速无感")。改法:加速一律**作用在速度域**——玩家水平速度目标 ×`HASTE_PLAYER`(1.4)、武器 tick ×1.4、**重力/跳跃保持原样**(跳跃高度不变);普通敌 `velocity.x` ×`HASTE_WORLD`(0.7)叠加其 delta ×0.7(动画/节拍也慢)。同时按用户要求强化可见性:加速时主角与敌人 `modulate` 提亮到 `Color(1.65,1.65,1.65)`(背景被 shader 压暗 → 角色"跳"出来),主角按 0.045s 间隔生成**红/蓝交替半透明残影**(`scenes/effects/afterimage.gd`,取当前动画帧贴图,0.26s 淡出自毁)。回归守卫 = `tests/haste_probe.tscn`。
- **B9 修正(用户 2026-09-26,六条)**:①视效改**覆盖度模型**——过渡由内而外推进、**最终全图统一**(底特律变人导航模式感;不再残留径向渐变/中心亮斑);②新增中心标志 `ui/time_symbol_hud.gd`(回溯 ◁◁ 浅色快闪 / 加速 ▶▶ 紫色,挂 hud);③怀表大数字配色:回溯红 / 加速紫 / 常态白;④加速重标为**双倍率**:玩家与精英 ×1.4、普通敌与敌弹 ×0.7(相对仍 2×,但移速/换弹/击发/冲刺全部肉眼变快、敌明显放慢——修正此前只缩放 delta 导致跳跃手感差、敌速观感无变化的问题);⑤结晶更大更黑更快(4~7.5px 块 / 黑色 / 散开 260~720 / 加速 5200);⑥回溯**补全武器弹量状态**(快照含当前武器类型与下标、背包各格残弹、手持实弹;还原时切回并写回)——"回拨除个人钟/精英/Boss 外一切"。

- **B13(用户:加速=主角时间加快 ⇒ 除主角外一切变慢;精英在加速与回溯都必须是极亮黄)**:把这条**规则**补全,并修掉高亮为什么看不见。
  - **机制**:敌人本身早已随 delta 变慢(移动/攻击间隔/AI 节拍/动画都在 `enemy_base` 首行的 delta 缩放里),但 **`EnemyBullet` 整个覆写了基类的 `_physics_process`** —— 基类首行那句 `TimeField.bullet_delta` 在这条路径上永不执行,于是"加速时敌方子弹一点没慢"(顺带:回溯期间它还在飞)。修法 = 在 `enemy_bullet.gd` 自己补上 delta 缩放 + 回溯整帧早退;另加 `TimeField.world_delta`(加速 ×0.7 / 回溯 0)给掉落武器等世界物件用。
  - **高亮**:`modulate > 1` 在非 HDR 2D 里被夹到 1.0,而且敌人基类的**受击/死亡白闪每帧都把 modulate 写回 WHITE/3.0**,外部写的高亮当帧就被覆盖 —— 这就是"完全看不出高亮、只看到一切都变暗"的原因。改为 `TimeGlow`:在实体视觉节点下叠**加色混合**的贴图副本(角色被压暗的背景衬得更亮,色相可控)。
  - **配色即规则**:加速 → 主角(冷白蓝)+ 场上敌人(暖白,近处 1500px 内);回溯 → **只有精英**;精英在**加速与回溯**两种状态下都是**两层亮黄**("极为亮眼");松开/回 NONE 全部卸掉。
  - 加速压暗由 `0.42 → 0.55`(压太黑会被读成"谁都没高亮"),角色靠加色副本"跳"出来。

### 探针(`-s` 或场景模式)
`tests/grain_account_smoke.gd`(账户八组)· `tests/time_field_smoke.gd`(倍率五组)· `tests/rewind_probe.tscn`(场景:录制/位置+HP 倒退/复活/精英不倒/免疫/松开恢复)· `tests/watch_hud_probe.tscn`(怀表读数/滚动收敛/三 ramp/贷款负数/音调/锁定红闪)· `tests/grain_crystal_probe.tscn`(elite 标/结晶/入账 300/颤抖)· `tests/tile_rewind_probe.tscn`(B7:拆砖入账/回溯后网格与渲染复原)· `tests/rewind_elite_damage_probe.tscn`(B8:回溯前不掉血/倒飞子弹二次伤害/普通怪不结算)· `tests/haste_probe.tscn`(B12/B13:倍率表(含 `world_delta`)/普通敌速度×0.7/**敌方子弹位移×0.7**/主角移速×1.4(关碰撞、等平台期再采,否则空气加速未收敛会偶发误判)/跳跃高度不变/红蓝残影与自行淡出/**高亮规则(加速=主角+近敌、回溯=只有精英、精英两层亮黄、副本不逐帧重建、松开全卸)**/回NONE/颗粒真被扣;走可注入桩输入 `tests/haste_probe_input.gd` —— 跳跃读的是 just_pressed 边沿,探针协程里按下的帧号永远报不到,必须走桩)。

### 检查点分支(用户要求的逐批回退点)
`KH_v0.5.0_B1`(账户) · `_B2`(输入+时间场) · `_B3`(回溯) · `_B4`(视效+怀表) · `_B5`(乌鸫精英+结晶) · `_B6`(音调/红闪/空转+回归) · `_B7`(瓦片随回溯复原) · `_B8`(回溯期精英二次伤害) · `_B9`(视效统一化/加速重标/弹量回溯/结晶改观/中心标志) · `_B10`(加速键位改鼠标右键+存档迁移) · `_B11`(回溯血量不通 HUD:补发 hp_changed) · `_B12`(加速改速度域+高亮+红蓝残影) · `_B13`(敌弹随世界变慢+加色高亮规则+精英亮黄) · `_B14`(地图选择 UI:单机开局选图 + 联机建房选图)。


## 地图选择 UI(2026-09-26,B14)

**目标**:单机进图前、联机建房时都能挑地图,并给每张图一版**开局地形简略图**。

### 新增文件
| 文件 | 职责 |
|---|---|
| `core/sim/map_catalog.gd` | 地图目录的**单一来源**:扫 `res://maps/`(+ exe 旁的开发者地图)、判"能不能打联机"(是否 `player2` 出生点)、**画简略图**(每格 2px 的纯 `Image`,由 UI 侧包纹理)、服务器侧的路径校验 `resolve_pvp_map`。**不引任何 autoload** → `-s` 探针可直接用 |
| `ui/map_picker.gd` | 选图控件(`MapPicker`):卡片=缩略图+地图名+尺寸+联机角标,首项"随机";三处 UI 共用,选中值由调用方接 `picked` 信号决定往哪存 |

### 接入点
- **单机**:`ui/sp_launch_panel.tscn` 的 `VBox/MapSection` + `main_menu._fill_sp_panel`(填控件)/`_enter_level0`(钉图 + **`GameParameters.refresh_map_size()`**)/`Settings.sp_map_path`。
- **联机**:`LobbyPage._add_map_picker(vb)`(基类一节,1v1 / 大乱斗 / 3v3 三页共用)→ 各页 `_player_options()` 带 `"map"` → `server_main` 用 `MapCatalog.resolve_pvp_map` 校验后传给 `MatchBootstrap/TeamHost/RoyaleHost.start_on` → 随 `match_start` 下发,客户端 `PvpSession.map_path` 照旧。存 `Settings.mp_map_path`(三模式共用一条)。
- `server/match_bootstrap.gd`:①`SpawnPicker.reset_cache()`(换图纪律,它的注释点名过);②`far_spawn_from(anchor, grid)` —— **只标了一个出生点的单人图**当联机图时,给 role2 现挑一个环面距离 ≥15 格的地板格(否则两端叠在同一个点上)。

### 纪律
- **联机定图只认仓内 `res://maps/*.cyrm` 且必须有双出生点**:客户端上报的路径不可信(`..`/非 .cyrm/不存在/单人图一律拒),不合规回落 `MatchBootstrap.PVP_MAP`。exe 旁的开发者地图只给单机用(别的机器上没有那个文件)。
- **"选了别的图"必须同步重算世界尺寸**:启动时 `GameParameters` 算的是当时随机图的尺寸,选了不同尺寸的图(factory1v1 150×100 vs demo 125×75)不重算 → 环面回绕/最短路径按错边界。
- 缩略图是**程序生成**的(不是美术资源):瓦片配色沿用 `ui/minimap.gd` 的观感,半砖压暗,出生点画成绿/蓝色块。

### 探针
`tests/map_catalog_probe.gd`(`-s`:目录/双出生点判定/显示名取注释行/简略图尺寸+多色+出生点色块+缓存/联机定图校验矩阵/单人图自动分配 role2 出生点)· `tests/menu_autotest.gd -- --autotest-sp`(**场景级**:单机面板里真的有选图控件 → 点选 factory1v1 → 进关后断言 `MazeGenerator.map_file_path()` 就是它、且 `GameParameters.MAP_WIDTH` = 150×64,少这条"摆了缩略图但进关还是随机图"的假功能照样会过)。
