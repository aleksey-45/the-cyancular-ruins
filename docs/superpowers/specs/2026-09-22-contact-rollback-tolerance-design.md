# 贴身回滚:接触期自适应容差(设计)

日期:2026-09-22 · 状态:**已批准,待实现** · 前置文档:`2026-09-12-royale-c2-migration-design.md` §2.1 / §4.4b / §7

涉及文件:`core/net/prediction_rollback.gd`(容差载体)· `scenes/pvp_match_client.gd`(唯一接线点)·
`scenes/player/player.gd`(接触判据)· `tests/brawl_rollback_probe.gd`(扫描与守卫)

## 1. 问题(一句话)

C2 客户端预测里,本地玩家与远端玩家**贴身时的位置分歧**是唯一的回滚来源;
`_close_enough` 的位置容差是"要不要为这点偏差回滚一次"的闸门 —— 而**当前 2px 恰好压在噪声底上**,
于是同一个配置的回滚次数会在"每帧回滚"与"几乎不回滚"之间跳变。

### 1.1 分歧的物理来源

客户端世界里对手只有一具**幽灵体**(`PlayerReplica.GhostBody`),它的位置来自快照 ⇒
比权威**晚**约一个单程延迟。贴身时"本地玩家该被挡在哪"由对手位置决定 ⇒ 客户端按**过去的**
对手位置解算,服务器按**当前的**解算。这是幽灵体存在的代价,也是幽灵体在**必需**的同时**不可能**消除的东西。

### 1.2 为什么频率由容差而非幽灵体精度决定

`2026-09-12-royale-c2-migration-design.md` §2.1 的实测(本次复跑逐项吻合):

| 事实 | 读数 |
|---|---|
| 对手静止时回滚 | **恰好 0**(N=2 与 N=8),分歧 0.23px |
| 幽灵体精度改变回滚次数 | 摘除(修正 75px)/ 准确(2px)/ 推歪(77px)**都是 ~220 次** |
| 容差改变回滚次数 | 1px→2px 在 N=2 上 221→9(−96%) |
| **接触期偏差 vs 容差** | 1/2/4/8px 四档**逐项相同**(中位 1.6 / p95 25~30) |

⇒ **容差决定频率;接触期的那点偏差本来就纠正不动**(回滚从 8 tick 前的权威态重放,落点与不重放几乎一致)。
故"接触期放宽容差"**近似纯赚** —— 这是本设计的全部立足点,也是 §4 必须重新验证的东西(见 §3.4)。

## 2. 目标 / 非目标

**目标**

1. 让贴身缠斗的回滚次数从"贴着阈值跳变"变成"稳定在低位",且**代价可量化、可断言**。
2. 非接触期保持**严格**(2px)—— 那里的位置分歧是真的,要立刻纠正。

**非目标(逐条有据,别顺手做)**

- **不动 `vel` 判据**(20px/s):若它是瓶颈,1px→2px 不可能砍掉 96%。
- **不动玩家物理/碰撞层/掩码**:`local.collision_mask |= 2` 与 3v3 的分队层一个字不改。
- **不动服务端与协议**:`in_contact` 是纯客户端本地量,**不进 `capture_state()`**、不上行。
- **不重开"回滚时把对手身体倒回同代位置"**:已由 §1.2 第 2 行(频率不随幽灵体精度变)**直接排除**,
  与那条证据不足的证伪实验无关(订正项见 §8)。
- **不做幽灵体外推**:实测频率不降、修正量 p95 13px → 47~64px(本次复跑复核)。

## 3. 设计

### 3.1 接触判据(取物理真值)

`scenes/player/player.gd` 新增只读函数:

```gdscript
# 本物理步的滑动碰撞里,有没有"非地形"的碰撞体(= 远端玩家身体所在层)。
# 地形恒为层 1;本地玩家的 mask 里除地形外只有对手幽灵体(1v1/大乱斗层 2,3v3 敌方层 16)。
func touching_player() -> bool:
	for i in range(get_slide_collision_count()):
		var col := get_slide_collision(i)
		if col == null:
			continue
		var co := col.get_collider() as CollisionObject2D
		if co != null and (co.collision_layer & ~1) != 0:
			return true
	return false
```

**为什么是函数不是字段**:`player.gd` 里 `move_and_slide()` 有 **3 个调用点**
(`_physics_process` / `_tick_downed` / `restore_state`)。做成"每处刷新一遍的字段"必然漏一处,
而漏了**不报错**。函数无状态、按需读,没有这个失败模式。

**为什么判层不判组名**:判 `player_replica` 组要在 `player.gd` 里写一个字面量,而
`player_replica.gd` 在 `_ready` 里 `preload("res://scenes/player/player.tscn")` ⇒ 两边互相引用成环;
判 `TeamHost.TEAM_ENEMY_LAYER` 又会把 `server/` 拖进核心玩家类。层判据零字符串耦合,
且层位将来挪动也不用改。

**三处对齐(不变量)**

- **3v3 队友**:幽灵体层 2、本地 mask 不含 2 ⇒ 根本不产生滑动碰撞 ⇒ 不判接触 ⇒ 与"队友不互挡"一致。
- **倒地**:`_tick_downed` 照样 `move_and_slide` ⇒ 倒地期间照常判定。
- **对手主动撞我**:幽灵体瞬移进本地玩家身体时,由 `move_and_slide` 的 depenetration 报成滑动碰撞。

### 3.2 容差载体

`core/net/prediction_rollback.gd`:

```gdscript
# 接触期的位置容差。★ 先与 pos_tol 同值(2.0)落地 —— 此时行为与今天**逐字相同**,
# 便于"先只改探针、先红给现状看"(见 §7 步骤 1);扫描出结论后**只改这一行**。
const DEFAULT_CONTACT_POS_TOL := 2.0

var contact_pos_tol: float = DEFAULT_CONTACT_POS_TOL
# 接入方每物理步写一次:本帧是否正在贴身。默认 false = 今天的行为。
var in_contact: bool = false
```

`_close_enough` 的位置那一条改为:

```gdscript
var tol := contact_pos_tol if in_contact else pos_tol
if _pos_dist(a.get("pos", Vector2.ZERO), b.get("pos", Vector2.ZERO)) > tol:
	return false
```

★ `down` / `hp` 仍**精确比较**,`vel` 仍 20px/s —— 它们才是"真事件"的防线:
击退会同时把速度打飞(≫20px/s),复活瞬移位移 ≫ 任何容差。**位置容差不必独自承担这件事**,
这正是它能取到比接触噪声 p95(25~30px)更大一档的原因。

### 3.3 接线(唯一一处)

`scenes/pvp_match_client.gd` 的 `_physics_process`(三个客户端共用):

```gdscript
if _rollback != null:
	if _have_prev_seq:
		_rollback.in_contact = _local.touching_player()   # ← 新增,必须在 reconcile() 之前
		_rollback.note_post_step(_prev_sent_seq, _local.capture_state())
		_rollback.reconcile()
```

- **必须在 `reconcile()` 之前**:`reconcile()` 是消费方。
- 读到的是**本帧或上一物理步**的接触态(取决于节点处理序:基类是父节点、通常先跑)。
  **两种都对** —— 接触是持续量,边界上多/少一次回滚无影响。

### 3.4 取值:探针扫描(先量后定)

`tests/brawl_rollback_probe.gd` 新增 `Variant.CONTACT8 / CONTACT16 / CONTACT32` 三档(N=2/4/8),并:

- **hint 按生产同款喂**:读 `P` 上一次步进留下的滑动碰撞(调 `P.touching_player()`),
  **不是**探针自己那个 `|o.x - A.x| < 90` 的几何代理 —— 那会验成另一个东西。
- **喂的时刻与生产同款**:在 `ctrl.advance(recA)` **之前**写 `ctrl.in_contact`。

**判据(三条,缺一条本改动就可能空转)**

1. **hint 命中率** > 0,且与探针的接触占比同量级。★ 最危险的假绿形状:判据永不触发 ⇒
   CONTACT 档读数逐字等于 2px 档,而探针照打全 ✓(本仓被抓过四次这类形状)。
2. **接触期偏差不得因放宽而显著变大**:中位 ≤ 3px、p95 ≤ 35px(今天 1.6 / 25~30)。
   ★ 这是本次扫描的**核心问题** —— 文档只验到 8px 的"逐项相同",**32px 没人测过**,
   §1.2 那条"白拿"的前提必须在**要用的档位**上重新成立。
3. **变异只打红自己那一相**:`in_contact` 恒 false ⇒ CONTACT 档读数退回 2px 档(N=4 ≈181)。

**定值规则**(扫描后按实测填 `DEFAULT_CONTACT_POS_TOL`,依据写进该常量的注释):

- 扫描档 = {8, 16, 32}。**在满足判据 2 的档位里取最小的那个**(软接触最小)。
- 若三档全满足判据 2(即接触期偏差在上界内与容差无关,§1.2 那条"白拿"在 32px 上仍成立),
  取 **16** —— 离接触噪声 p95(25~30px)**仍有余量**、软接触又只有体宽(80px)的 1/5。
- 若**没有**任何一档满足判据 2(偏差随容差显著变大),则本设计的前提不成立:
  停下来重估(退路见 §6 第一条),**不许**硬填一个"看起来能压住次数"的值。

## 4. 守卫

| 要防的静默失效 | 落点 | 形态 |
|---|---|---|
| `pvp_match_client` 漏喂 hint(漏了 = 静默退回 2px) | `tests/rollback_fidelity_probe.gd` | 源码级:`in_contact` 的赋值出现在 `reconcile()` **之前**(与它已守的 `map_px` 同款) |
| `_close_enough` 读错档(恒用 `pos_tol`) | `pvp_reconcile_smoke`(`-s`) | 纯逻辑:接触真/假两个方向各断言一次 |
| 层判据前提失效(玩家身体将来挪到层 1) | 源码级/探针 | 断言"玩家身体层位 ≠ 地形层位" |
| 探针新档是空转 | `brawl_rollback_probe` | §3.4 判据 1(命中率)+ 判据 3(变异) |

## 5. 基线读数(2026-09-22 实测,供扫描对照)

`tests/brawl_rollback_probe.tscn`,末行 `BRAWL ROLLBACK PROBE: ALL-OK`:

| 变体 | N=2 | N=4 | N=8 | 修正中位 |
|---|---|---|---|---|
| 对手静止(健全性) | **0** | — | **0** | 0.0 px |
| 幽灵体摘除(负向对照) | 224 | — | 249 | 75 px |
| 1px | 221 | 222 | 162 | 2~4 px |
| **2px(今天)** | **9** | **181** | **13** | 3.8~6.3 px |
| 4px | 7 | 36 | 6 | 3.7~6.5 px |
| 8px | 5 | 3 | 5 | 7.9~13.4 px |
| 幽灵体外推(已证伪) | 222 | 229 | 199 | p95 47~64 px |

接触期偏差:1/2/4/8 四档**逐项相同**,中位 1.6 / p95 25~30 px。

★ 文档记的 2px 档 N=4 为 75~89,本次 181 —— 与文档自己那条"N≥4 读数本身离散大"
(2px 档 N=8 三次跑出过 **13/17/128**)是同一现象。**这正是立项理由**:阈值贴着噪声底时,
读数在"每帧回滚"与"几乎不回滚"之间跳变。目标不是"压到 0 次",是**让阈值离噪声底足够远**。

## 6. 已知边界(照实登记,不粉饰)

- **软接触**:容差放宽后,贴身时本地玩家可能停在离权威位置最多 `contact_pos_tol` 的地方
  (屏幕上"陷进去"或"差一点没贴上")。这是本改动**唯一**的手感代价;大小由取值定,存在性无法消除。
- **接触判据的边界**:幽灵体只浅浅嵌进本地玩家体内、未触发 recovery 时报不出滑动碰撞 ⇒
  退回严格容差 ⇒ 退化成本改动之前的行为(不会更坏)。
- **扫描环境是合成世界**:层隔离 + 手工输入脚本,量的是 C2 控制器本身(三模式共用);
  真链路里别的分歧源(复活瞬移/换边/击退)不在覆盖内。
- **3v3 的分队层**不在本探针里,归 `team_host_probe` ⑩ / `team_room_smoke` ⑨② 管。

## 7. 落地顺序

1. **只改探针**:加 CONTACT 族 + §3.4 三条断言,**先红给现状看**
   (`contact_pos_tol == pos_tol` 时 CONTACT 档必须逐字等于 2px 档),把读数交用户过目。
2. `PredictionRollback` 两个字段 + `_close_enough` 一行分支。
3. `player.touching_player()` + 基类一行接线。
4. 扫描 → 定值 → §4 守卫 → 跑回归(`pvp_reconcile_smoke` / `replica_ghost_probe` /
   `pvp_twin_smoke` / `rollback_fidelity_probe`;**真链路两条(`royale_c2_probe` / `reconnect_probe`)归用户跑**)。
5. 更新 CLAUDE.md 的 §网络与 PvP(C2 那段)与 §测试(探针清单)。

## 8. 文档订正项(顺带,不阻塞)

`2026-09-12-royale-c2-migration-design.md` §2.1 把"回滚时把对手身体倒回同代位置"判为
**机制不可行**,依据是「重放期间把 **restore 目标**整体 +5000px → 回滚数一字不变」。

- 那条实验移动的是 **restore 目标**,不是幽灵体;且当时读数已接近饱和 ⇒ **它不构成**"同帧移动的
  静态刚体对 `move_and_slide` 不可见"的证据。
- **但结论不变**:§1.2 第 2 行(频率与幽灵体精度无关)已足以排除该方案。
- 建议改写为:"本方案由『回滚频率不随幽灵体精度变化』直接排除",把那两张表降格为历史留档。

## 9. 不变量一览(实现时逐条自查)

1. `in_contact` 不进 `capture_state()`、不上行、服务端零感知。
2. 非接触期容差恒为 `pos_tol`(2.0),逐位不变。
3. `contact_pos_tol` 默认值 == `pos_tol` ⇒ 常量填值之前,行为与今天逐字相同。
4. 3v3 队友仍完全不产生接触(层判据与分队层天然一致)。
5. `player.gd` 不新增任何 import(不引 `server/`、不引 `player_replica`)。
