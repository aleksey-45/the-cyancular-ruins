# 玩家阵营（3v3 分队）缺陷与口径统一 — 设计（2026-09-25）

**一句话**：修两条**已定位**的阵营缺陷（3v3 激光打队友；小地图上"我"那个点与队色撞色），
并把"未知队号"在三个消费点的三种口径统一成一种。

**范围刻意小**：阵营这套是 2026-09-18/21 新建的，走的是"先探针后代码"，比武器那块健康得多
（见 §1.3 已排除的四处）。本次只动被实际观察到的两处 + 一处口径分歧。

---

## 1. 背景

### 1.1 症状（用户 2026-09-25 报的）

1. **颜色认不出谁是谁 —— 只在小地图上有**（身体 / 头顶 ID 都正常）
2. **某些时候有友伤**

### 1.2 根因（两条，均已定位到行）

#### ① 3v3 里激光枪对队友满伤满击退

三条伤害路径的队友口径不一致：

| 路径 | 代码 | 队友 |
|---|---|---|
| 子弹直击 | `server/match_combat.gd:52` `if same_team(shooter_role, int(role)): continue` | **穿透**（不伤害、也不挡弹道）|
| 榴弹直击 | `server/match_combat.gd:81` 同款 | **穿透** |
| **激光** | `scenes/weapons/laser_weapon_base.gd:135-142` | ❌ **无判据** |

激光那段：

```gdscript
	for p in get_tree().get_nodes_in_group("player"):
		if not (p is Node2D):
			continue
		if p == player:  # 射手本人不吃自己这发
			continue
		if p.has_method("is_downed") and p.is_downed():
			continue
		targets.append([p, false])
```

**只排除射手本人。** `same_team` 的全部 7 个调用点都在 `server/`（`match_combat.gd` ×2、
`match_state.gd` ×1、`team_host.gd` ×4），**激光链上一处都没有** —— 因为激光是即时命中、
不走 `_adjudicate_bullets`，它在权威侧**直接**结算伤害。

⇒ 3v3 里拿激光枪烧队友，**且队友既挡不住光束也不被光束挡住**。这条只在场上有人拿激光枪时
发生，与"某些时候"吻合。

#### ② 小地图上"我"那个点与队色撞色

`ui/minimap.gd:35` `SELF_COLOR := Color(0.6, 0.95, 1.0)` = **`#99F2FF`，固定值，不随队**。
3v3 的队友/敌人点由 `team_game._minimap_colors()` 按队给色。

| 你 | 你的点 | 队友点 | 敌人点 | 结果 |
|---|---|---|---|---|
| 蓝队 | `#99F2FF` | `#639BFF`(C_TEAM_A) | `#80F4FF`(C_TEAM_B) | 自己的点与**敌人色**差 Δ=(25,2,0) ⇒ **看起来像敌人** |
| 青队 | `#99F2FF` | `#80F4FF`(C_TEAM_B) | `#639BFF`(C_TEAM_A) | 自己的点与**队友色**差 Δ=(25,2,0) ⇒ **分不清自己与队友** |

**两边都坏，只是坏法不同。** 三个色同属蓝-青系，`SELF_COLOR` 恰好夹在中间。

★ 注意 **1v1 / 大乱斗没有这个问题**：那两处不给颜色提供器（`Minimap.setup` /
`setup_multi` 的两参形式），所有他人点恒为 `ENEMY_COLOR`（红 `#FF6659`），与青色
`SELF_COLOR` 分得开。所以**症状 1 是 3v3 独有**，与用户"只在小地图上有"的观察一致。

### 1.3 查过但干净的（勿重复排查）

| 查了什么 | 怎么查的 | 结论 |
|---|---|---|
| 结算页的队伍分节与配色 | 读 `ui/match_result_payload.gd` 全文 | 干净 —— `for_duel` 根本不用队伍表；`for_team` 的 `C_TEAM_A/B` 用在分节标题上，正确 |
| 3v3 平局文案 | 读 `ui/team_hud.gd:104-113` | **正确**（`mwinner == 0 → "平 局"`），且注释里亲手点名了 `pvp_hud` 那个 1v1 兜底的陷阱 |
| 从 role 推队号（禁止项） | `grep -rn "role % 2\|role/2\|% 2 =="` 全仓 | 无命中（仅两处无关联的无敌帧闪烁代码） |
| 1v1 的 P2 染色 | 读 `scenes/pvp_game.gd::_apply_p2_tint` 与注释 | 结构性正确（P2 == `C_TEAM_B` == 3v3 队 2，同一 token 同一机制），**不是 bug** |

### 1.4 现状行为，明确**不改**

- **爆炸（榴弹 AoE）对队友满效**：`Explosion.apply_aoe` 的玩家分支不看队伍关系
  （`server/match_combat.gd:78-80` 的注释记着这是**用户 2026 年裁定**：「子弹穿透队友、
  爆炸对队友满效」）。⇒ **本次不动**。所以"友伤"仍会有两个来源，其中一个是有意的。
- **1v1 的 P2 与 3v3 队 2 同色**：结构性的，正确。
- **3v3 下 `Settings.pvp_minimap_show_enemy` 会把队友点一起关**：既有语义，已登记。

---

## 2. 目标与非目标

### 目标

1. 3v3 里激光不再伤害队友，且与子弹/榴弹的"穿透"口径**一致**。
2. 3v3 小地图上"我"那个点可辨认（不再与敌人或队友撞色）。
3. "未知队号"在三个消费点只有**一种**答案。

### 非目标

- 不碰爆炸的队友伤害口径（§1.4，用户既有裁定）。
- 不碰 1v1 / 大乱斗的染色与小地图（那两处无此问题，改动只会引入风险）。
- 不做队伍色常量的整体抽象重构（`C_TEAM_A/B` + 底板色 6 处等），另立计划。
- 不动 `Minimap` 的"他人点"配色语义（3v3 按队、1v1/大乱斗恒红）—— 那是正确的。

---

## 3. 设计

### 3.1 激光：队友从目标列表里排除

**判据从哪来。** 武器够到宿主的**已有先例**就在同一个文件里
（`laser_weapon_base.gd:234`）：

```gdscript
	var host := player.get_parent() if player != null else null
	if host != null and host.has_method("notify_direct_hit"):
		host.notify_direct_hit(player, p)
```

`player.get_parent()` + `has_method` 守卫 —— 单机下父节点是 `WorldViewport`，`has_method` 为假，
自动跳过。**激光照这个形状拿队伍判据**，不要新开一条路。

**新接口**（服务端 `server/match_state.gd`）：把私有的 `_role_of` 包一层公开判据 ——

```gdscript
# 两名玩家是否同队。给**武器**用(它们只拿得到节点,拿不到 role)。
# ★ 1v1 / 大乱斗 / 单机:队伍表为空 ⇒ same_team 恒 false ⇒ 本函数恒 false
#   ⇒ 调用方(激光)的行为与今天**逐字不变**。这是本接口的安全性质,别改成"没表就返回 true"。
func is_friendly(a: Node, b: Node) -> bool:
	if a == null or b == null:
		return false
	return same_team(_role_of(a), _role_of(b))
```

**调用点**（`laser_weapon_base.gd::_damage_path_targets`）：在玩家循环里加一条 `continue` ——

```gdscript
	var host := player.get_parent() if player != null else null
	var team_aware := host != null and host.has_method("is_friendly")
	...
		if team_aware and host.is_friendly(player, p):
			continue     # 队友穿透:与子弹/榴弹直击同口径(不伤害、也不挡光束)
```

**为什么只改权威侧就够**：`laser_weapon_base.gd:61` 的 `if not _authoritative(): return` 门控
（`_authoritative()` 在 `:74`；判据是 `not Level0.pvp_mode`）—— 客户端那份视觉副本**根本不结算伤害**。
所以这条修法**不碰协议、两端无需同版本**。

**与"穿透"的一致性**：子弹是 `continue`（不 break）——队友**不挡弹道**，后面的敌人照打。
激光同一个 `continue` 语义天然成立（激光不是逐帧飞行的弹，但队友被排除出目标列表后，
光束几何照旧穿过他）。

### 3.2 小地图"我"那个点：队色 + 与颜色正交的标记

**要害**：同队同色时，**颜色本身无法区分"我"与队友**。所以不能只把 `SELF_COLOR` 换成队色 ——
那会从"分不清自己与队友"变成"完全分不清哪个是自己"。需要**一个与颜色正交的维度**。

**设计**：

- **3v3（有颜色提供器）**：自己那个点 = `_team_color(PvpSession.role)`（与身体 / 头顶 ID
  **同源**，见 `team_game._team_color`），**外加一圈白描边**（`#FFFFFF`，与队色正交，
  不引入新色相）。
- **1v1 / 大乱斗（无提供器）**：**保持不变**（`SELF_COLOR` 青 vs `ENEMY_COLOR` 红，分得开，
  没有这个问题）。⇒ `SELF_COLOR` **不删**，只是 3v3 那一路不再用它。

**接口**：`Minimap` 已经有第三个参数"颜色提供器"（`setup_multi` 的第三参，
`Callable()` 默认）。自己那个点的颜色走**同一个提供器**，**入参就是 `PvpSession.role`**
（与 `_minimap_colors()` 回填他人点时用的是同一套 role 键，不引入第二种标识）。
判定"要不要走提供器"的闸门与 `ui/minimap.gd:43` 现有那句同源：**提供器是默认的
`Callable()` 就用 `SELF_COLOR`，否则问它**。

**不新增参数** —— 新增参数要改三处调用点，而它们在两个不同场景里（`pvp_game` / `royale_game` /
`team_game`），漏改一处的表现是"那个模式的小地图自己那个点没了"，不报错。

★ 描边的具体粗细/是否改成方形属**表现细节（Minor）**，实现时定即可 —— 但"必须有正交维度"
这条不是 Minor：去掉它就等于没修。

### 3.3 "未知队号"的口径统一

今天三个消费点三种答案：

| 消费点 | 队号不在 {1,2}（含 0）时 | 位置 |
|---|---|---|
| 服务端配碰撞层 | `push_error` + **什么都不配**（保持层 2 / 掩码 7） | `server/team_host.gd::_apply_team_layers` |
| 客户端取颜色 | 返回**中性亮白** | `scenes/team_game.gd::_team_color` |
| 客户端配幽灵体层 | 落到 `else` = **层 16 = 队 2 的层** | `scenes/team_game.gd::_ghost_layer_of` |

**前两者是自洽的**（"不属于任何队"）；**第三者不是** —— 它把"未知"当成了队 2。
后果是客户端与服务器对同一具身体**放不同的层**：服务端在层 2，客户端幽灵体在层 16。
而两队掩码不同（队 1 = `1|4|16`、队 2 = `1|4|2`），所以队 2 的玩家在服务端**会**被那具身体挡住、
在客户端**不会** ⇒ C2 每帧分歧。

**统一成"不属于任何队"**（与服务端的"什么都不配 = 保持层 2"逐值对齐）：

```gdscript
func _ghost_layer_of(role: int) -> int:
	match _team_of_role(role):
		1: return 2
		2: return TeamHost.TEAM_ENEMY_LAYER
	return 2   # 表外/表未到:与服务端"什么都不配"(保持层 2)对齐,不再落到队 2 的层
```

★ 今天这条**在生产路径上到不了**（3v3 worker 的 `team_map()` 恒非空），所以修它是"消除一个
静默不对称"，不是修一个可见 bug。**照实登记这一点**，别把它说成用户报的症状。

---

## 4. 已知边界与残余（登记，不修）

1. **爆炸仍对队友满效**（§1.4）。所以修完激光之后，3v3 里仍会有友伤，来源只剩爆炸 ——
   这是**有意的**，别把它当回归。
2. **大乱斗的小地图上所有他人点恒为红色**（无颜色提供器）。对手身体有各自色相，但小地图上
   分不出谁是谁。用户没报，本次不动。
3. **`_team_color` 的表外分支返回中性亮白**，而服务端对表外是"保持默认层"。两者的"未知"
   在**颜色**与**碰撞**上仍不是同一个概念（一个说"都不是"，一个说"维持默认"）。本次只把
   客户端自己的两处（颜色 / 幽灵体层）对齐，**没有**在服务端引入"未知"这个概念。登记。
4. **队号 0 的玩家在服务端仍会被队 2 挡、不被队 1 挡**（因为服务端什么都不配 = 层 2 + 掩码 7，
   而队 1 掩码含 2、队 2 掩码含 2 —— 其实两队都会挡它）。⇒ 统一之后两端一致，但"未知队号
   的人与所有人互挡"这条性质**保持**（"多挡一层"比"少挡一层"安全）。

---

## 5. 验收判据

1. **新探针（激光）**：真建一个 `TeamHost`（`role_peers` 传空 + 手工摆位，与
   `tests/team_host_probe.gd` 同款手法），把**队友**放在光束路径上、**敌人**放在队友后面，
   断言：队友**不掉血**、且敌人**照常掉血**（后半条是"穿透"的鉴别点 —— 只写"队友不掉血"
   的话，把整个玩家循环删掉也能过）。
   ★ 反证：把 `continue` 去掉，探针必须红。
2. **新探针（小地图）**：`Minimap` 喂一个颜色提供器，断言自己那个点的**底色 == 队色**
   （不是 `SELF_COLOR`），且**描边存在**。（必须真渲染 —— `minimap_circle_probe` 已有先例。）
3. **既有探针全绿**，逐个点名：`team_host_probe`（③ 队伍表逐值 / ⑩ 分队碰撞层）、
   `team_table_probe`（③④ 子弹穿队友 / 爆炸满效）、`team_disconnect_probe`、
   `team_room_smoke`（⑨②⑨③⑨⑤）、`hue_tint_probe`（守卫 C/D/E）、`minimap_circle_probe`、
   `laser_weapon_smoke`、`enemy_logic_smoke`。
   ★ 特别注意 `team_table_probe` 的 ③④：**它们断言的是子弹与爆炸**，激光不在其中 ——
   这正是这条 bug 能存活至今的原因（见 §1.2 ①）。
4. **实机**：3v3 一局，一人拿激光枪对着队友的方向开火 —— 队友不掉血、且身后的敌人掉血。

---

## 6. 计划拆分

| # | 计划 | 覆盖 | 碰协议? |
|---|---|---|---|
| 1 | **激光不打队友** | §3.1 | 否（只改权威侧） |
| 2 | **小地图自己那个点 + 未知队户口径** | §3.2 + §3.3 | 否 |

计划 1 与 2 **完全独立**（不同文件、不同模式面），可并行；计划 2 内部两件事同属
"客户端口径统一"，放一起。

---

## 7. 本设计明确不做的事（后续独立计划）

- **队伍色与常量的单一来源**：`C_TEAM_A/B` / `SELF_COLOR` / `NAME_COLOR`，以及底板色 6 处
  （3 个 const + 2 个 `.tscn` 字面量 + 1 处内联）。它们与本 spec 的"认不出谁是谁"是**两回事**
  （那些是维护性冗余，不是可读性缺陷），另立计划。
- **大乱斗小地图的对手点带上个人色相**（§4.2）。
- **`Minimap.setup_multi` 的第三参改成必填**（今天默认 `Callable()`，1v1/大乱斗走默认分支）
  —— 本次不动，因为改它要碰三处调用点。

## 8. 已排除的伪发现（勿重复排查）

1. **结算页的队伍配色** —— 读全文，干净（§1.3）。
2. **3v3 平局被念成「P2 获胜」** —— `ui/team_hud.gd` 已正确（§1.3）。CLAUDE.md 里
   "这条留给以后加 HUD 的人"那段警告**已经被处理过了**，别再照着它去找 bug。
3. **从 role 推队号** —— 全仓无命中（§1.3）。
4. **1v1 的 P2 与 3v3 队 2 撞色** —— 结构性正确（同一 token 同一机制），不是 bug。
5. **"GUI / 小地图控件吃掉鼠标"** —— 与本 spec 无关，且已推翻（见武器 spec §10）。

---

## 附：事实核验清单

| 事实 | 怎么核的 |
|---|---|
| 激光伤害路径无队伍判据 | 读 `laser_weapon_base.gd:130-164` |
| `same_team` 的 7 个调用点全在 `server/` | `grep -rn "same_team" --include=*.gd scenes core server ui` |
| 激光伤害只在权威侧结算 | `laser_weapon_base.gd:61` 的 `_authoritative()` 门控 + `:74` 定义 |
| 武器够到宿主的既有形状 | `laser_weapon_base.gd:234`（`player.get_parent()` + `has_method("notify_direct_hit")`）|
| `_role_of` 在服务端存在 | `server/match_state.gd:139` |
| `SELF_COLOR` 与两个队色的数值关系 | `ui/minimap.gd:35`、`ui/ui_factory.gd:132-133`；Δ 为手算 |
| 1v1 / 大乱斗不给颜色提供器 | 读三处 `Minimap.setup*` 调用点 |
| 爆炸对队友满效是既有裁定 | `server/match_combat.gd:78-80` 的注释 |
| `_ghost_layer_of` 表外落到 16 | 读 `scenes/team_game.gd:207-208` |
