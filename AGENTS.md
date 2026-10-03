# AGENTS.md(KH_v0.5.0 线)

> 上游工程(原作者)的说明在 `CLAUDE.md`;本文件只记**本线新增的时间玩法(第一阶段)**与纪律。

## 个人钟 · 第一阶段(2026-09-26,B1-B6)

**目标**:个人时间颗粒账户(怀表)+ 时空回溯/加速。**仅单机**(`Level0` 建场;PvP/菜单 `TimeField.current == null` → 全倍率恒 1,零影响)。

### 文件职责(全部新增/上游结构落位)
| 文件 | 职责 |
|---|---|
| `core/config/time_params.gd` | 时间玩法参数总表(全 const 可调):初始1000/上限5000/短时窗400/恢复50每秒/回溯120每秒/加速80每秒/贷款额100/快照20Hz40s/**加速 HASTE_PLAYER=2.0 / HASTE_WORLD=0.5**/贷款视效映射/乌鸫300 |
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
- **B12 修正(用户:感受不到加速,只觉跳跃变低)**:根因是 `move_and_slide()` 用**引擎自己的 delta**,只在 `_physics_process` 首行缩放 delta 只改了重力与计时器(所以"坠落变快、跳跃变低、移速不变、敌速无感")。改法:加速一律**作用在速度域**——玩家水平速度目标 ×`HASTE_PLAYER`、武器 tick 同倍率、**重力/跳跃保持原样**(跳跃高度不变);普通敌 `velocity.x` ×`HASTE_WORLD` 叠加其 delta 同倍率(动画/节拍也慢)。同时按用户要求强化可见性:加速时主角与敌人 `modulate` 提亮到 `Color(1.65,1.65,1.65)`(背景被 shader 压暗 → 角色"跳"出来),主角按 0.045s 间隔生成**红/蓝交替半透明残影**(`scenes/effects/afterimage.gd`,取当前动画帧贴图,0.26s 淡出自毁)。回归守卫 = `tests/haste_probe.tscn`。
- **B9 修正(用户 2026-09-26,六条)**:①视效改**覆盖度模型**——过渡由内而外推进、**最终全图统一**(底特律变人导航模式感;不再残留径向渐变/中心亮斑);②新增中心标志 `ui/time_symbol_hud.gd`(回溯 ◁◁ 浅色快闪 / 加速 ▶▶ 紫色,挂 hud);③怀表大数字配色:回溯红 / 加速紫 / 常态白;④加速重标为**双倍率**:玩家与精英 ×1.4、普通敌与敌弹 ×0.7(相对 2×;**2026-09-26 又被 B16 提到 2.0/0.5**),但移速/换弹/击发/冲刺全部肉眼变快、敌明显放慢——修正此前只缩放 delta 导致跳跃手感差、敌速观感无变化的问题);⑤结晶更大更黑更快(4~7.5px 块 / 黑色 / 散开 260~720 / 加速 5200);⑥回溯**补全武器弹量状态**(快照含当前武器类型与下标、背包各格残弹、手持实弹;还原时切回并写回)——"回拨除个人钟/精英/Boss 外一切"。

- **B13(用户:加速=主角时间加快 ⇒ 除主角外一切变慢;精英在加速与回溯都必须是极亮黄)**:把这条**规则**补全,并修掉高亮为什么看不见。
  - **机制**:敌人本身早已随 delta 变慢(移动/攻击间隔/AI 节拍/动画都在 `enemy_base` 首行的 delta 缩放里),但 **`EnemyBullet` 整个覆写了基类的 `_physics_process`** —— 基类首行那句 `TimeField.bullet_delta` 在这条路径上永不执行,于是"加速时敌方子弹一点没慢"(顺带:回溯期间它还在飞)。修法 = 在 `enemy_bullet.gd` 自己补上 delta 缩放 + 回溯整帧早退;另加 `TimeField.world_delta`(加速 ×`HASTE_WORLD` / 回溯 0)给掉落武器等世界物件用。
  - **高亮**:`modulate > 1` 在非 HDR 2D 里被夹到 1.0,而且敌人基类的**受击/死亡白闪每帧都把 modulate 写回 WHITE/3.0**,外部写的高亮当帧就被覆盖 —— 这就是"完全看不出高亮、只看到一切都变暗"的原因。改为 `TimeGlow`:在实体视觉节点下叠**加色混合**的贴图副本(角色被压暗的背景衬得更亮,色相可控)。
  - **配色即规则**:加速 → 主角(冷白蓝)+ 场上敌人(暖白,近处 1500px 内);回溯 → **只有精英**;精英在**加速与回溯**两种状态下都是**两层亮黄**("极为亮眼");松开/回 NONE 全部卸掉。
  - 加速压暗由 `0.42 → 0.55`(压太黑会被读成"谁都没高亮"),角色靠加色副本"跳"出来。

### B15 修正(2026-09-26,用户:击杀精英怪不掉时间颗粒了)
- **根因**:结晶第二阶段原本是"纯加速度追踪 + 只判**当前点**是否落在 16px 内"。B9 把飞行加速度提到 5200 之后,一帧能跨过目标几十像素 → **隧穿**(永远进不了判定半径 → `_absorb()` 永不触发 → 颗粒不入账;同时"全部分片到齐才自毁"也永不成立 → FX 无限滞留)。B5 的 FX 探针探不到它:那个探针里没有相机/怀表,目标点退化成 FX 自身位置,碎片正好从原点穿回来,所以一直是绿的。
- **修法**(三条纪律,写在 `scenes/effects/grain_crystal.gd` 阶段二上方):①**指数收敛** `v = 到目标位移 × ARRIVE_RATE`(限速 `MAX_FLY_SPEED`)—— 任意距离都收得住、不绕圈、近目标时每帧只有几像素;②**按线段判近** `_segment_hits(prev, now, target, r)` —— 防高速隧穿;③**兜底入账**:阶段二超时(`ABSORB_TIMEOUT`)一律 `_absorb()` 再自毁 —— **颗粒是数值承诺**,绝不能因为特效没飞到就丢掉。诊断字段 `last_absorb_kind`/`last_absorb_t` 供探针断言"是飞到的,不是兜底的"。
- **探针**:新增 `tests/elite_drop_probe.tscn`(**真击杀路径**:找到真乌鸫 → `hurt(9999)` → 断言结晶 FX 出现 → 余额 +300 → 吸收方式必须是 `fly` 而非 `timeout`)。B5 的 `grain_crystal_probe.tscn` 保留(FX 本体)。

### B17 修正(2026-09-27,用户:回溯之后经常被之前击发的榴弹炮炸死)
- **定性**:一半是设计(回溯确实会把榴弹一起倒回去,而倒放方向正是"倒向它刚出膛那一刻"——它就在你脸前;
  松手后世界从倒退点继续,榴弹照常会炸,自伤也是既有规则),另一半是**两份状态没进快照**的真 bug。
- **两个真凶(都在 `WorldRewind._apply_bullets` 的重建路径上,修前叠加发作)**:
  ① **引信**没记(`_fuse_active/_fuse_elapsed/_fuse_duration`)→ 重建出来的榴弹退回"未点燃" ⇒
     a) 在错误时刻爆炸;b) 松手那一帧 `_check_player_contact()` 重新生效,与你重叠的榴弹走 0.1s
     **触碰引信贴脸起爆**。
  ② **开火时由武器注入的字段**(`max_range/gravity_factor/speed/size/bullet_color`,敌方弹另有
     `damage/water_mult`)没记 → 重建弹带着**场景默认值**:`max_range` 默认 0 ⇒ `traveled >= max_range`
     当场成立 ⇒ 榴弹**一松手就在回溯落点触发"超射程爆炸"**。这条比①更致命(不需要挨着你也能炸)。
  另:敌方子弹此前没打 `scene_path` meta → 重建时建不出节点 → 回溯期间直接"消失"(位置也不倒),一并补上。
- **修法**:`BulletBase.rewind_state()/apply_rewind_state()`(状态读写口,`EnemyBullet` 覆写补自己的字段)
  + `WorldRewind` 快照加 `fuse` 字段、实例化时与**每帧**都写回(引信要跟着倒退,不能冻结在按下那一刻)。
  空字典 = 保持原样 → 老快照/无引信弹安全。
- **探针**:`tests/rewind_fuse_probe.tscn`(读写口往返含 max_range/gravity_factor · 回溯重建弹带着引信 ·
  引信与射程**随回溯倒退** · 重建弹的 max_range 必须还原(否则一松手就炸)· 松手后仍"已点燃"并从还原值继续)。
  ★ 已验证它会红:把写回掐掉后同一探针报出 5 条失败,正是用户描述的症状。

### 探针(`-s` 或场景模式)
`tests/grain_account_smoke.gd`(账户八组)· `tests/time_field_smoke.gd`(倍率五组)· `tests/rewind_probe.tscn`(场景:录制/位置+HP 倒退/复活/精英不倒/免疫/松开恢复)· `tests/watch_hud_probe.tscn`(怀表读数/滚动收敛/三 ramp/贷款负数/音调/锁定红闪)· `tests/grain_crystal_probe.tscn`(elite 标/结晶/入账 300/颤抖;★ 它只验 FX 本体,真击杀路径见下)· `tests/elite_drop_probe.tscn`(B15:真击杀乌鸫 → FX 出现 → 余额 +300 → 吸收方式必须是飞到怀表)· `tests/rewind_fuse_probe.tscn`(B17:引信/开火注入字段进快照、随回溯倒退、重建后不再贴脸起爆)· `tests/tile_rewind_probe.tscn`(B7:拆砖入账/回溯后网格与渲染复原)· `tests/rewind_phantom_probe.tscn`(**D2**:尸体隐藏时碰撞层已摘/砖块碰撞随破坏与回溯一致/复活后层还原/全场无「不可见却带碰撞层」的节点 + 幽灵墙抽样;★ 覆盖上限:只验**碰撞**这一维,尸体在隐藏期的接触伤害/爆炸击退/漏标等**未验**——见 D2 的登记)· `tests/rewind_elite_damage_probe.tscn`(B8:回溯前不掉血/倒飞子弹二次伤害/普通怪不结算;★ **本探针 2026-10-03 复跑为既有 FAIL**,见 D2 的登记)· `tests/haste_probe.tscn`(B12/B13/B16:倍率表(含 `world_delta`)/普通敌速度×`HASTE_WORLD`/**敌方子弹位移×`HASTE_WORLD`**/主角移速×`HASTE_PLAYER`(关碰撞、等平台期再采,否则空气加速未收敛会偶发误判)/跳跃高度不变/红蓝残影与自行淡出/**高亮规则(加速=主角+近敌、回溯=只有精英、精英两层亮黄、副本不逐帧重建、松开全卸)**/回NONE/颗粒真被扣;走可注入桩输入 `tests/haste_probe_input.gd` —— 跳跃读的是 just_pressed 边沿,探针协程里按下的帧号永远报不到,必须走桩)。

### 检查点分支(用户要求的逐批回退点)
`KH_v0.5.0_B1`(账户) · `_B2`(输入+时间场) · `_B3`(回溯) · `_B4`(视效+怀表) · `_B5`(乌鸫精英+结晶) · `_B6`(音调/红闪/空转+回归) · `_B7`(瓦片随回溯复原) · `_B8`(回溯期精英二次伤害) · `_B9`(视效统一化/加速重标/弹量回溯/结晶改观/中心标志) · `_B10`(加速键位改鼠标右键+存档迁移) · `_B11`(回溯血量不通 HUD:补发 hp_changed) · `_B12`(加速改速度域+高亮+红蓝残影) · `_B13`(敌弹随世界变慢+加色高亮规则+精英亮黄) · `_B14`(地图选择 UI:单机开局选图 + 联机建房选图) · `_B15`(修:击杀精英不掉颗粒 —— 结晶飞不进怀表) · `_B16`(加速拉到夸张档:主角 ×2.0 / 其余 ×0.5,并覆盖游泳与攀爬) · `_B17`(修:回溯后被自己榴弹炸死 —— 子弹快照补齐引信与开火注入字段) · `_B18`(cyrm v4 游戏侧选项 A:碰撞/破坏下沉 16px 子格)。


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

### B16 调整(2026-09-26,用户:"还是没明显感觉到加速,做得夸张一点")
- **倍率**:`HASTE_PLAYER 1.4 → 2.0`、`HASTE_WORLD 0.7 → 0.5`(相对差 4 倍)。语义仍是"主角时间加快":
  玩家/精英的移动、开火/换弹节拍、冲刺**全都 ×2**;普通敌人、敌方子弹、掉落武器**全都 ×0.5**。
- **补上两条漏网的主角路径**(否则一下水/上梯"加速"就没了):`swim_component`(水平游速与上浮/下沉)
  与 `climb_component`(梯/链上下)同样吃 `TimeField.player_speed_mult()`。重力/跳跃**照旧不动**
  (跳跃高度不变是有意为之:加速若连重力一起缩放,手感会变成"跳得又低又飘")。
- 残影间隔 0.045 → 0.03s(2× 下拖尾才跟得上)。
- 回归:`tests/haste_probe.tscn` 判据带同步(主角 1.75~2.25、敌人与敌弹 ≤0.65),连跑两次
  实测 敌速×0.50 / 敌弹×0.50 / 主角移速×2.00~2.06。

## cyrm v4 游戏侧(2026-09-28,B18;上游 origin/main 已并入 v4 编辑器)

**用户拍板(§3 选项 A)**:`current_grid` 永远是 **64px 格级**(20 个逻辑调用方零改动);
只有**碰撞箱**和**破坏**按 **16px 子格**算。上游依据:`docs/2026-09-20-cyrm-v4-handover.md`
(作者写的游戏侧交接文档)与 `level_editor/core.js`(新编辑器,v4 读写都在那边,旧
structure-editor.html 已退休)。

- **格式层**(上一批,已并入用户快照 KH_v0.5.0_P1):`MapFormatV4`(头/deflate/CRC/层块)、
  `MapFormat.load_subgrid`、两张官方图已转 v4。★ 本批补上交接文档 §6.2 的炸弹防御:
  body_size ≤ 64MB(解压前拦)、裸 body 恒等式、sub 尺寸须为 4 的倍数。
- **会话态**:`MazeGenerator.current_subgrid`(16px 子格纹理表,`WorldBuilder.load_grid`
  与格级网格一起装填;v3/旧图由 `MapFormat.expand_cells_to_subgrid` 把 2×2 掩码 ×2 展开)。
- **碰撞**(`collision_builder.gd`):`SUB_TS 32→16`(子格 250×150→500×300),`build_sub`
  消费子格表(空则从格级展开兜底),块换算 ×4;**已摧毁子格不产生碰撞**。
- **破坏**(`tile_defs.gd`):`sub_hp` 子格 HP 表(逐子格 = 纹理 hp)+ `damage_sub`/
  `restore_sub`/`sub_alive` + `on_sub_destroyed(sub, pre_hp)` 回调;**整格 16 子格全部死光
  才把格级网格清零** —— 逻辑层只在"整格没了"时才看到变化。
- **渲染**(`level_0.gd`):16px 图集 = 22 纹理 × 16 象限 = **352 块**(取角:象限由
  X%4/Y%4 推出;预生成"65536 形状"的老路在 v4 下是 6GB,死路);`_paint_maze` 铺子格
  (9 环面副本,偏移单位变子格);`_on_sub_destroyed` 清 16px 格+记账本+脏块;
  账本条目从 `{cell,v}` 改为 **`{sub,hp}`**,`_restore_sub` 还原 HP/贴图/碰撞并在需要时
  从基线复活格级网格;`reset_destructibles` 子格表一并回基线。
- **伤害源**:`explosion.gd` 的 `destructible_cells` → **`destructible_subs`**(16px 圆扫,
  炸出圆洞而非整格消失),扣血与受击碎片表现共用;`bullet_base._damage_tile_at` 命中点
  映射到子格(探测 0/8/16px 沿法线)。
- **已知边界**:①`beam_trace`(激光 DDA)仍格级 —— 部分破坏的格对激光仍算挡(保守);
  ②四层渲染(前景/后景/背景)未做,需要作者交接文档 §5.2 的"前景层顺序"决策;
  ③16px 铺贴量 ~20 万 set_cell,autotest 实测可接受。
- **探针**:`tests/subcell_probe.gd`(-s:子格表装填/HP/单子格摧毁不清格/全灭清格/还原;
  ★ `-s` 里必须显式 `TileDefs.load_defs()`,否则全走缺省表)· `tile_rewind_probe` 适配 16px
  (渲染断言查该格 16 子格)。

## 一键联机 · EasyTier 虚拟局域网(2026-09-28,P1)

**动机**:3Mbps 公网服扛不住联机带宽(8 人大乱斗上行 ~4Mbps);EasyTier 组虚拟网后
玩家间 P2P 直连(家宽上行 30Mbps+),服务器进程跑在房主机器上,公网服退役。
交互抄 MCTier(PCL-CE 同款模式):房主「一键开网」出邀请码 → 朋友粘码 → 完事。

### 文件职责
| 文件 | 职责 |
|---|---|
| `tools/easytier/easytier-core.exe`(+`wintun.dll`/`Packet.dll`/`WinDivert64.sys`) | 官方 EasyTier v2.6.4 内核**原样打包**(Apache-2.0)。★ 五件套缺一不可:Packet.dll/WinDivert64.sys 是加载器静态依赖,缺了**不报错、进程 exit 127 秒退**(实测踩坑);git 里 *.exe 被 ignore,提交须 `git add -f` |
| `tools/easytier/et_elevate.ps1` | 提权垫片·未提权端:游戏 → 它 → `Start-Process -Verb RunAs`(UAC)→ helper。**纯 ASCII+CRLF**(ps1 编码纪律)。★ **含空格的路径必须手工内嵌双引号**(`('"{0}"' -f $path)`)——Windows PowerShell 5.1 拼接 `-ArgumentList` 数组**不加引号**,user:// 路径里的 "The Cyancular Ruins" 会在第一个空格处截断 → 提权进程静默退出、UAC 点了也白点(P1 实测踩坑,游戏→垫片那跳是 Godot 起进程、引号规范,所以只炸这一跳) |
| `tools/easytier/et_helper.ps1` | 提权垫片·提权端:读 session.json → 防火墙规则(幂等删加:内核本体全放行;host_mode 加游戏服 UDP 7777+7800~8299)→ 隐藏窗口拉内核(stdout/stderr 重定向到会话目录)→ **守护循环**(stop.flag / 游戏进程退出 / 内核死亡,任一即杀内核收摊)。游戏本体**永不提权** |
| `core/net/easytier_link.gd` | 内核链路(纯静态,零 autoload):解包五件套到 `user://easytier/`(尺寸比对跳过重拷)、`host_start`(随机网名+24位密码,固定 `10.126.126.1`)/`join`(粘码,`--dhcp` 取号,超时回退随机手动 IP 一次)/`stop`、邀请码 `CYR1-`+base64(json{n,s,p,h})(节点列表随码走,防跨节点组不上网)、ipconfig 网卡轮询(按 `--dev-name cyr_et` 找段,**本地化无关**:标题行冒号结尾+正则取 IP)、**网段占用预检**(别的网卡已有 10.126.126.x → 报错请先停手动开的 EasyTier GUI/MCTier) |
| `ui/one_click_net.gd` | 一键联机面板(全屏遮罩+居中面板,三联机页共用,MapPicker 同款模式):建房/加入两态、邀请码剪贴板**自动识别预填**、一键复制、失败带内核日志尾巴;就绪发 `net_ready(虚拟IP,是否房主)` |
| `scenes/lobby_page.gd` | 基类新增 `_add_one_click_net(pos)`/`_on_one_click_net_ready`:房主路径复用 `LocalServer.restart()` 开服 + `_request_list` 连大厅;三页各一行摆钮(1v1 x=640 / 大乱斗·3v3 x=750,y=114) |
| `Tests/easytier_probe.tscn` | 单机双节点探针(**管理员**运行):解包→邀请码往返→两内核经局域网 IP 互联(★回环 127.0.0.1 有绑定怪癖必失败,勿用)→网卡落位→`new peer added` 组网断言→stop.flag 收摊。探针网段用 10.147.147.x 避开生产段 |
| `Tests/lobby_parse_smoke.tscn` | 联机页解析冒烟:load() 三大厅页+新脚本不实例化。★ 存在理由:`--check-only --script` 不加载工程认不出 NetBus 等 autoload,**对联机页必然假阴性** |

### 纪律与不变量
- **导出只给客户端 preset 加了 `tools/easytier/*`**(服务器 exe 不带 25MB 内核);客户端体积 40.8→~66MB(方案 A,用户拍板)。★ **验收标准 = 客户端 exe ≈66MB**:P1 实测踩坑——include_filter 的 `tools/easytier/*` 被并行会话的合并吞掉(编辑过但未落进提交),v.1.2.0 首个 exe 41.6MB 无内核,从 exe 点一键联机必然"内核文件缺失";而编辑器里 res:// 文件在、测试全绿——**编辑器测试证明不了导出包的完整性**。
- **生产网段 = EasyTier 默认 DHCP 池 `10.126.126.0/24`**(MCTier 同款):房主手动 .1 + 朋友 DHCP 天然同段;改网段须同时改 `SUBNET_PREFIX`/`HOST_IP`/预检。
- **会合节点**:官方公共节点 `public.easytier.top` **不存在**(NXDOMAIN,别再用);默认双协议回落海波节点 `us01.225284.xyz:11010`(udp+tcp,实测可达,2026-09-28)。自建会合点:任意 VPS 跑 `easytier-core.exe -p <本机公网IP:11010>` 即可,协调流量每秒几 KB。
- **提权**:每次开网/加入弹一次 UAC(创建 TUN 网卡必须);从管理员终端跑探针则免弹。
- **清理**:helper 按游戏 PID 守护,游戏退出即杀内核;`EasyTierLink.stop()` 写 stop.flag 收摊。绝不按映像名全杀(会误杀用户手动开的 EasyTier GUI)。
- **P1 提权链修复(2026-09-29,用户实测"点了 UAC 仍卡在开网")**:根因=上表 et_elevate 的空格路径截断;修复后全链实测通过——点 UAC 后 **2 秒**内 `cyr_et` 网卡拿到 `10.126.126.1`、TCP+UDP 双协议连上海波会合节点、防火墙三条规则落位、stop.flag 收摊干净。诊断套路:**`s0/core.log` 的 mtime 没刷新 = helper 没跑到拉内核那一步**(先查防火墙规则存在性,再手动 `-File et_helper.ps1` 复现,最后才怀疑提权转发)。
- **P1 ipconfig 解析修复(2026-09-29,提权通了仍报"开网失败")**:根因=段头判定只看"冒号结尾",而每段第一行字段"连接特定的 DNS 后缀 . . . . . . . :"(中英文皆然)同样冒号结尾 → 段标记当场被翻掉 → IPv4 行被跳过 → **网卡 2 秒就绪、游戏却等满 60 秒超时**(现场:网建成、内核活、双连节点,只有解析器瞎)。修法=`_is_adapter_header`:冒号结尾**且不含 ". ." 点串**(ipconfig 固定排版,语言无关);`_adapter_ips` 与 `_foreign_subnet_owner` 共用。★ 验证 ipconfig 解析必须**重放真实输出**(bash `grep -A6` 会绕过游戏解析路径,P1 两轮都栽在这)。
- **P1 导出包 RegEx 陷阱(2026-09-30,"开网流程内部出错"真根因)**:自定义裁剪模板**没编 regex 模块** → 导出包里 `RegEx` 类未声明 → easytier_link.gd **整个脚本解析失败**(一行 Parse Error 只在启动期闪过)→ 点击时 `host_start()` 无声返回 null。编辑器是完整引擎所以全绿。修法=ipconfig 解析改纯字符串(`_ip_after_colon`:取最后一个冒号后的尾巴、前缀匹配+纯数字校验);**全仓纪律:要进导出包的脚本禁用 RegEx**(`grep -rn "RegEx" core/ ui/ scenes/ server/` 应为空)。诊断基建:`-- --auto-host-net` 命令行钩子(进主菜单即自动走 host_start 全程并打印后退出)+ `[ET]`/`[ETDIAG]` 步进日志 —— 导出环境复现命令:`The Cyancular Ruins.exe --headless -- --auto-host-net`(stderr 完整可捕获,UAC 需人点)。
- **P1 端口分配改最小空闲(2026-09-30,用户裁定"一个大厅不需要管很多对局")**:`WorkerLauncher.pick_port` 从"唯一递增"改为**从 7800 起取最小空闲**(占用集合并发安全性不变,公共服第二局自然拿 7801)。自建服一局打完端口归还,下一局**还是 7800** —— 朋友的防火墙/转发规则只需写一个端口,也为"朋友端免 TUN 的端口转发模式"铺路。

## D1:大乱斗房间选色(2026-09-29,KH_v0.5.0_P1_D1)

**用户报告**:"联机房间的自我角色颜色自定义没有运用到实战"。**排查结论:协议与染色链路本来就是通的,断的是 UI 入口**——色相滑条只长在「建房面板」,而建房面板**一进等待室就隐藏** ⇒ 房主建完房改不了、**加入者全程没见过选色 UI**。

- **实证手段**:`tests/royale_probe.gd` 的 claim 原先恒报 `hue:0.0`(非零路径从未测过);改为 c1=137/c2=246 两个可互相区分的值,并在 match_sync 应答断言 **hues 双向带值**(自己那份命中 + 对面那份在表)→ 全绿,证明 `_on_player_options 归档 → _claim_hues → match_sync → _apply_peer_hues/副本染色` 整链健康。
- **修复**:选色行从建房面板**搬进等待室面板**(`royale_lobby._build_wait_panel`,所有成员开局前可改;即选即存 `Settings.pvp_color_hue`,开局 claim 时随 player_options 上发)。1v1 个人色相停用(P2 固定队色)、3v3 队色固定——皆设计使然,不动。
- **验证**:解析冒烟 6/6;真链路探针双端全部通过(hues 双向回包 + 123 快照)。实战视觉效果(自己染色 + 他人副本染色)由实机联机验收。
### B20(P2 第二批,已完成):Beta 入口 + 独立房间池 + 建房页时间参数
- **入口**:主菜单 `Beta` 按钮(大乱斗下方,弱化样式)→ `scenes/beta_menu.tscn`:画框型卡片 = 图标(程序化怀表 `WatchHud.build_dial_texture()`(已改静态)+ 红 `Royale`/蓝 `Team` 字)+ 模式名 + 简介 + 版本(beta_0.0)。两张卡:**错乱大乱斗**→royale_lobby、**时空 3v3**→team_lobby。
- **beta 态传递**:`PvpSession.beta_mode`(reset() 一律复位;Beta 页 `enter_mode` 后置真)。两个大厅页读它:标题加「· Beta 时间玩法」、建房面板挂 9 行时间参数(`LobbyPage._add_time_params`,值住 `time_rules: TimeRules`,建房/上报前 clamp)。
- **独立房间池**(判据三件套,双侧):①创建载荷带 `{"beta":true,"time":{...}}`(`_beta_payload()`,普通态空合入);②`royale_join/team_join` **签名加第 4 参 beta**,服务器双向拒(普通页进 Beta 房 / Beta 页进普通房各一条文案);③列表载荷带 `beta` 字段,客户端按 `PvpSession.beta_mode` 过滤(royale 在循环内 continue,team 用 filter 后的 `visible_rooms`)。1v1(`join_room`)与普通模式行为零变化。
- **跟随改的调用点**:`tests/lobby_visibility_probe`(royale/team join 直调补 `false`)、`tests/royale_bound_probe`(同);`kh_l1_probe` 只查方法名,不受影响。★ `royale_bound_probe` 在本机当前负载下**基线也超时**(stash 对照过),判环境问题非回归。
- **探针**:`-- --autotest-beta`(主菜单→Beta 页:两卡/名字/版本号在→点错乱大乱斗→royale_lobby 且 beta_mode=真→时间参数 9 行滑条在→`_player_options()` 带 time)全绿;`autotest-royale/team/mp` 与 `kh_l1/lobby_visibility` 全绿;--import 零错误。

### B21(P2 第三批,已完成):服务器权威颗粒经济 + 拆砖事件修复
- **`server/time_economy.gd`**(新):每 role 一份 `GrainAccount`(规则来自房主 options["time"] → `TimeRules.from_dict`)+ 四条缝 —— `award_kill`(得被击杀者余额×比例,被击杀者不减)/`award_damage`(每点×4,归因口径 = TeamHost 逐人伤害同源:meta last_damager + ATTRIB_WINDOW 新鲜度,自伤/归因不到/同队谁都不给)/`award_blocks`(每 16px 子格 ×10)/`tick`(回复)。纯逻辑,-s 可测。
- **宿主接线**:`MatchHost._init` 建 economy(options["time"] 非空;普通局恒 null 全短路)·`_physics_process` tick + 10Hz `_rpc_all_ext("time_state")` · `MatchCombat._on_player_hit` 伤害入账(基类一处钩住三宿主;`MatchState._fresh_attacker_role` 上提)· 击杀入账挂 RoyaleHost 倒地边沿与 TeamHost._record_down 异队分支 · 拆砖入账挂 `_on_sub_destroyed`。
- **★ 修了 B18 的 PvP 回归**:worker 此前只连格级 `on_destroyed`,而 B18 后破坏走 `damage_sub` → **子格破坏事件从不广播**(客户端幽灵墙 + 本地预测与服务端碰撞分歧)。现在 `damage_sub` 带第 4 参 `owner`(射手节点,`on_sub_destroyed(sub, pre_hp, owner)` 三参回调),worker 连子格回调(清 16px 持久子格 + 脏块 + `NetBusExt.sub_destroyed` 广播 + 拆砖入账),客户端 `pvp_match_client._on_remote_sub_destroyed` 清本地渲染/碰撞;`_on_remote_tile_destroyed`(格级,重连补态/老路径)改为拆 16 子格。
- **协议**:新 RPC 全在 **NetBusExt**(纪律:原 NetBus 逐字节不动,防与原版大厅失联):`sub_destroyed(sub)` / `time_state(payload)`(authority,reliable)+ `_rpc_all_ext`。
- **客户端怀表**:`PvpMatchClient._setup_beta_time_hud()`(royale/team 两对局场景在 HUD 后调用;beta_mode 自短路)——挂 WatchHud(与单机同位 24,124)到 `Level0.grain_account` 的**镜像账户**;`time_state` 每包写字段,怀表自滚动。普通联机/单机零影响。
- **探针**:`tests/time_economy_smoke.gd`(-s:四缝公式 + 过滤口径 + 夹上限)全绿;time_rules/grain_account/subcell/map_v4 与 autotest-beta/sp 回归全绿。

### B22(P2 第四批,已完成):加速 ×3(只快自己)+ 双侧视效
- **输入协议**:`PacketInputSource` 加 `BIT_HASTE(128)`(held 段;两端同版本纪律同 BIT_RELOAD);解码端 `haste_held()` 直读。pack 编码端在唯一来源 `pack_record` 里加一位。
- **服务器**:`MatchHost._physics_process` 在快照前定格加速态 —— 按住位 + 账户可耗 ⇒ 该 role 的 `player.pvp_haste_mult = rules.haste_mult(默认 3.0)`,烧 `haste_burn`(70/s);**只乘自己**(移动/开火/换弹/冲刺经 player 速度域,别的角色/子弹/世界一概不动)。快照 world 包每 role 带 `haste` 位。
- **player.gd**:新增 `pvp_haste_mult`(服务器/本地预测写);`_speed_mult` 计算 = TimeField(单机)或 pvp_haste_mult(PvP)—— 单机路径零变化。
- **客户端**:`_tick_beta_time`(物理帧):本地预测(按住+镜像可耗 ⇒ 写自己的 pvp_haste_mult;**烧颗粒只在服务器**,镜像 10Hz 校正,避免双份漂移)。视效:自己 = 冷白蓝加色高亮 + 0.03s 红蓝交替残影(单机同款);他人 = 暖白高亮 + 0.06s 红/蓝两张淡副本(重影)+ 头顶像素字 `▶▶ 3x`(倍率取自 time_state 下发)。royale/team 场景快照消费时给副本打 `haste` meta;`_all_replicas()` 由两子类覆写。
- **已知边界**:①加速的全屏压暗(haste_dim)未在 PvP 接(单机走 Level0._tick_time_visuals,PvP 场景无该驱动;如需可在 pvp 场景直接 set_time_effects);②自己的弹速未乘 ×3(SP 里玩家弹走 bullet_delta 的 TimeField,PvP 的 TimeField 为 null)—— **PvP 里子弹常速**,与本批"只快自己(角色行动)"的语义先保持一致,弹速倍率要不要乘待用户实测后定。

### B23(P2 第五批,已完成):回溯(只回溯自己)+ 免伤 + 双侧视效
- **协议**:`BIT_REWIND(256)`(held 段)+ `rewind_held()`;与 BIT_HASTE 同款两端同版本纪律。
- **服务器**(`MatchHost` 的 `_tick_beta_rewind`,快照前跑):每 role 环缓(**20Hz**,深度 = rules.rewind_buffer_seconds,默认 12s/240 帧)只存**自己**的状态(位置/速度/HP/朝向/弹量 wmags/widx/wlive,与单机 WorldRewind._snapshot_player 同构)+ **自己的子弹**(pos/vel/rewind_state 含引信)。按住+可耗+未倒地 ⇒ 进入:输入源 frozen、`time_rewinding` meta(免伤闸)、烧 150/s;游标 3×→1× ramp 倒放,逐帧写回自身与自己的子弹;**自己的子弹照常伤害他人**(写回位置/速度/引信,不重建已消亡弹 —— 已爆的榴弹不复活,已知边界)。颗粒烧空/松手 ⇒ 退出,世界从倒退点继续。**不能复活**:倒地即禁入。
- **免伤闸**:`player.take_hit` 首行统一判 `TimeField 回溯态(单机) or time_rewinding meta(PvP)` —— 一处闸住子弹/榴弹/爆炸/接触全部来源,单机零变化。
- **快照**:每 role 带 `rewind` 位 + `trail`(回溯中每 3 帧一个位置点,≤10 个)。
- **客户端**:own = 本地预测(冻结本地输入源 + 免伤 meta;**位置不本地预测**,吃 C2 权威写回)+ **底片只作用于世界图层与自己**(`scenes/effects/time_film.gdshader`:coverage 由内而外推进,挂 wall/water/水面层与本地玩家;敌方副本不挂 —— 用户裁定)+ 中心 ◁◁ 符号。others = 回溯者副本满覆盖底片色 + 沿 trail 的**时间切片残像**(底片色,1 秒渐隐,AfterImage)。
- **已知边界**:①倒放不重建已消亡子弹;②客户端 C2 期间倒放位置依赖权威写回(回滚手感未实测);③顶针数的 HP 广播走 combat.emit_signal(与 SP rewind_restore 同源做法)。

### B24(P2 第六批,收尾):全量回归 + 导出
- 回归(全绿):watch_hud / elite_drop / tile_rewind / rewind_fuse(场景)+ time_rules / grain_account / time_economy / subcell / map_catalog / map_format_v4(-s)+ autotest-sp / autotest-beta + pvp_room_smoke(1v1 建房/加入/开局链路未受 P2 改动破坏)+ --import 零错误。
- exe 已重导出(2026-09-29 12:30)含全部 P2 批次;管线哨兵完好。
- **实机待验清单**(给用户):Beta 页两卡 → 建房(9 项参数可调)→ 加入对局 → 怀表显示余额/回拨/贷款负数 → 右键加速(自己 ×3+高亮+残影;他人视角 ▶▶3x+红蓝重影)→ Shift 回溯(免伤、自己+世界底片、他人看你的底片色+轨迹残像;回溯中的子弹伤人)→ 击杀/伤害/拆砖颗粒入账 → 贷满锁定与解锁。

### D1(P2 debug 线,2026-09-29 用户两项裁定):弹速随加速 ×3 + PvP 压暗(仅发动者视角)
- **弹速**:weapon_base 出弹时读**射手**的 `pvp_haste_mult` > 1 ⇒ 该发弹速 ×同倍率(局部变量,不动 bullet_speed 成员 —— 霰弹逐弹 ×会累积、跨发会永久变快)。max_range 不动:飞得更快、射程不变(与单机 bullet_delta 的距离上限语义一致)。单机 pvp_haste_mult 恒 1,零影响(不会与 TimeField.bullet_delta 双乘)。★ 激光是即时光束,无弹速概念,不涉及。
- **压暗**:pvp 客户端 `_haste_dim_t`(100ms ramp,与单机同款)只驱动**本地**的 PostProcess.set_time_effects(0,0,t) —— 组里取 post_process,只碰 haste_dim,film/loan 恒 0;他人屏幕完全不受影响(压暗是本人视角状态,不随快照广播)。
- 验证:autotest-sp/beta + haste_probe 全绿;--import 零错误。

### D2(P2 debug 线,2026-10-03 用户报「时间回溯还是会导致有些时候有虚空碰撞箱」):保留尸体的碰撞层
- **症状**:单机回溯玩久了,会撞在**空处** —— 看不见的墙。
- **根因**(`scenes/enemies/enemy_base.gd`):录制期为回溯保留的尸体(`WorldRewind.hold_corpses` → `_rewind_hold`)在死亡白闪结束后走到那条"隐藏待复活"分支,原实现只做 `visible = false` + `set_physics_process(false)` —— **碰撞层没摘**。玩家 `collision_mask = 5` 含**敌人层(值 4)** ⇒ 一具看不见却仍在层 4 的 CharacterBody2D 就是一堵看不见的墙,一直挡到尸体超窗被 `expire_corpses` 释放(窗口 `SNAP_SECONDS` = **40s**)。★ 触发条件只是"在敌人死掉的位置走过" ⇒ 用户说的**有些时候**。
- **修法**:隐藏尸体时 `_rw_held_layer = collision_layer; collision_layer = 0`;`rewind_restore` 的**复活分支**还原。★ 改**碰撞层**而非禁用碰撞多边形:飞鸟的 `_apply_flight_collision` 自己管站/飞两个多边形的 `disabled`,基类插手会和它互相打架;层与多边形启停正交。★ 白闪那 0.5s **不摘**(那时尸体还看得见、挡人合理)。
- **同源的第二处**:`enemy_fly_base._collect_obstacles` 把附近敌人一律当寻路障碍,隐藏尸体(层已 0、物理上可穿)仍被算进去 ⇒ 飞鸟会绕一个空位置。改为**跳过 `collision_layer == 0` 的实体**(判据取"还挡不挡路",与物理同口径;白闪期照旧算障碍)。
- **顺带的行为变化(有意)**:子弹此前会撞在隐藏尸体上被吸收(`collision_mask = 5` 含敌人层),现在会**穿过去**继续飞 —— 与"那里什么都没有"一致。
- **验证**:新探针 `tests/probe/rewind_phantom_probe.tscn` 四相(见下)。★ **变异验证过**:把 `collision_layer = 0` 那行换成 `pass`,探针当场红 3 条(相① 层仍 4 + 物理查询命中自身 + 相④ 点出 `/root/Level0/WorldViewport/EnemyJumpBird (CharacterBody2D, layer=4)`);还原后重新绿。回归:`enemy_logic_smoke`(SMOKE OK)/ `rewind_probe` / `tile_rewind_probe` / `haste_probe` / `squash_host_enemy_probe` 全绿。
- **★ 覆盖上限(照实登记)**:
  - 探针只验**碰撞**这一维。隐藏尸体仍参与的两处**未验、未改**:① `Explosion.apply_aoe` 按 `enemies` 组遍历,隐藏尸体照吃击退(`is_dead` → `_apply_knock_only`)⇒ 复活那一帧会带着**陈旧 `knock_velocity`** 飞出去(`rewind_restore` 不还原它);② 同一条 AoE 会对它调 `CombatFeedback.hit_marker()` ⇒ 炸一个隐形尸体会在屏幕上闪一个命中 X。两处都**先于本次改动就存在**,不是本次引入。
  - 不能靠"把尸体移出 `enemies` 组"来一并解决:组被 `record()`(要把它写进快照才可能被复活)与 `expire_corpses` 依赖。
- **★ 相邻的既有红(非本次引入)**:`tests/rewind_elite_damage_probe.tscn` 现报 `FAIL(1): 回溯期未发生二次伤害(HP 30→30)`。已按本仓纪律在 **`git show HEAD:` 的干净树上连跑两次复核** —— 两次同为 FAIL ⇒ **与本次改动无关**,未修。
- **★ 一条守卫的覆盖比它读起来小**:`enemy_logic_smoke` 的 `_check(jdc.collision_layer == 4, "JumpBird 死亡保留碰撞层")` 在**死后 1 个物理帧**断言 —— 那时还在白闪期(且 `hold_corpses` 在冒烟里恒 false),**覆盖不到**隐藏期待复活那一段。别把它当成这条修复的守卫。
