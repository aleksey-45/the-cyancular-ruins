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
| `render/post_process.gdshader` + `post_process.gd` | 三效果:`rewind_film`(中心向外辐射底片化,≤200ms ramp)/`haste_dim`(背景压暗+玩家高亮)/`loan_depth`(变亮+红蓝色差);统一入口 `PostProcess.set_time_effects(film, loan, haste, player_uv)` |
| `core/present/sfx.gd` | `static var pitch_mult` 全局音调系数(贷款越深越尖、加速略升、回溯略降;BGM 接入后同源) |

### 按键
`rewind`(Shift)/`haste`(Ctrl)——Shift 已从 `down`(下蹲)摘绑,old 存档里 down 的 Shift 绑定由 `Settings` 读档时自动迁移摘除。

### 纪律与不变量
- **单机闸门**:时间系统只在 `Level0` 单机路径建立;任何 PvP/联机场景不得启用(`TimeField.current` 必须为 null)。
- **精英定义**:`set_meta("elite", true)`(乌鸫 `_ready` 自带)。精英=免疫回溯(不入快照)、加速与玩家同步、击杀掉 300 颗粒。
- **回放期不结算伤害**:玩家 `take_hit` 早退、普通敌整帧早退、子弹不步进(精英照常)。
- **瓦片回溯(B7)**已落地:玩家拆砖经 `TileDefs.on_destroyed` → `_on_tile_destroyed` 捕获改前值(清空前从渲染层 atlas 读回)→ `TileLedger` 帧末入账 → 回放时按 `(target, cursor]` 区间 **t 降序** 写回四层(网格/9 环面副本/持久子格/脏块);非玩家破坏(未来事件)走别的口,本阶段只有玩家口径。
- 本轮**不动** `Engine.time_scale`(物理/tween/网络不受扰),倍率集中在三处 delta 注入(玩家/敌人/子弹物理帧首行)。

### 探针(`-s` 或场景模式)
`tests/grain_account_smoke.gd`(账户八组)· `tests/time_field_smoke.gd`(倍率五组)· `tests/rewind_probe.tscn`(场景:录制/位置+HP 倒退/复活/精英不倒/免疫/松开恢复)· `tests/watch_hud_probe.tscn`(怀表读数/滚动收敛/三 ramp/贷款负数/音调/锁定红闪)· `tests/grain_crystal_probe.tscn`(elite 标/结晶/入账 300/颤抖)· `tests/tile_rewind_probe.tscn`(B7:拆砖入账/回溯后网格与渲染复原)。

### 检查点分支(用户要求的逐批回退点)
`KH_v0.5.0_B1`(账户) · `_B2`(输入+时间场) · `_B3`(回溯) · `_B4`(视效+怀表) · `_B5`(乌鸫精英+结晶) · `_B6`(音调/红闪/空转+回归) · `_B7`(瓦片随回溯复原)。
