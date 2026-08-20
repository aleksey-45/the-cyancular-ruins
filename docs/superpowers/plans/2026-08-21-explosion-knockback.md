# 爆炸击退独立向量(大冲击+迅速衰减)Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 爆炸击退改为「大冲击+迅速衰减」:敌人和玩家各自新增独立 `knock_velocity` 向量,指数衰减,叠加在移动速度之上。只改爆炸路径,枪击不变。

**Architecture:** `EnemyBase` 和 `player.gd` 各持有 `knock_velocity: Vector2`。爆炸命中(`set_velocity=true` / `take_hit` 传击退)时设置它(封顶),每帧 `velocity += knock_velocity → move_and_slide() → velocity -= knock_velocity → knock_velocity *= exp(-decay*delta)`。死亡时折入 `velocity` 沿用尸体物理。`explosion.gd` 把真实击退(按距离 falloff、遮挡减半)传给玩家 `take_hit`。

**Tech Stack:** Godot 4.7.1 标准版, GDScript, 冒烟脚本 `extends SceneTree`。

## Global Constraints

- Godot 4.7.1 标准编辑器(非 mono)。console 绝对路径固定。
- **只改爆炸击退**;枪击(现有 `velocity +=`)一律不动。
- 代码注释用中文,与项目现状一致。
- 测试命令(实施者跑 headless 冒烟验证;playtest 由用户跑):
  - `"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . -s res://Tests/enemy_logic_smoke.gd`
  - `"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . -s res://Tests/grenade_smoke.gd`
- 提交只 `git add` 本任务涉及的文件,不 `git add -A`(工作区有其他未提交改动)。

---

### Task 1: 敌人爆炸击退独立向量(EnemyBase)

**Files:**
- Modify: `Scenes/Enemies/enemy_base.gd`
- Test: `Tests/enemy_logic_smoke.gd:602-624`(改「爆炸击退覆盖 vs 枪击叠加」段,加独立向量断言 + 衰减断言)

**Interfaces:**
- Consumes: 无(EnemyBase 现有 `hurt(damage, knock_dir, knock_strength, set_velocity)` / `_apply_hit` / `_physics_process`)。
- Produces: `EnemyBase.knock_velocity: Vector2`、`EnemyBase.knock_decay_rate: float = 15.0`、`EnemyBase.max_knock_velocity: float = 2500.0`。`set_velocity=true` 语义改为「设 `knock_velocity`(封顶),不覆盖 `velocity`」;死亡时 `velocity += knock_velocity` 后封顶 `max_death_fly_speed`。

- [ ] **Step 1: 改测试(先写失败断言)**

把 `Tests/enemy_logic_smoke.gd` 的 `# ── 爆炸击退覆盖(纯径向)vs 枪击叠加 ──` 整段替换为:

```gdscript
	# ── 爆炸独立击退向量(大冲击+迅速衰减)vs 枪击叠加 ──
	var ov_grid: Array[Array] = []
	for _y in range(60):
		var row_o: Array[int] = []
		row_o.resize(60)
		row_o.fill(MazeGenerator.EMPTY)
		ov_grid.append(row_o)
	MazeGenerator.current_grid = ov_grid
	var ov := fb_scene.instantiate()
	ov.global_position = Vector2(1000, 400)
	root.add_child(ov)
	await physics_frame
	# 枪击(默认叠加):原速度 500 + 击退 300 = 800
	ov.velocity = Vector2(500, 0)
	ov.hurt(1, Vector2.RIGHT, 300.0)
	_check(is_equal_approx(ov.velocity.x, 800.0), "枪击击退叠加 500+300=800")
	# 爆炸(set_velocity=true):设独立击退向量,不覆盖移动速度
	ov.velocity = Vector2(500, 0)
	ov.hurt(1, Vector2.RIGHT, 300.0, true)
	_check(is_equal_approx(ov.knock_velocity.x, 300.0), "爆炸设独立击退向量 300")
	_check(is_equal_approx(ov.velocity.x, 500.0), "爆炸不覆盖移动速度(500 保留)")
	_check(is_equal_approx(ov.knock_velocity.y, 0.0), "爆炸击退纯径向(y=0)")
	# 击退向量随帧指数衰减
	var ov0: float = ov.knock_velocity.x
	for i in range(5):
		await physics_frame
	_check(ov.knock_velocity.x < ov0, "爆炸击退向量随帧衰减")
	ov.free()
	MazeGenerator.current_grid = []
```

- [ ] **Step 2: 跑测试确认失败**

Run: 冒烟命令(enemy_logic_smoke.gd)
Expected: FAIL —— `ov.knock_velocity` 不存在,报 `Invalid get index 'knock_velocity'`(运行时错误),且「爆炸不覆盖移动速度」断言失败(旧实现把 velocity 覆盖成 300)。

- [ ] **Step 3: 实现 EnemyBase 独立击退向量**

`Scenes/Enemies/enemy_base.gd`:

(a) 在 `max_death_fly_speed` 导出(第 15 行)之后加:

```gdscript
	# 爆炸专属击退向量:独立于 AI 移动速度,每帧叠加后指数衰减(大冲击+迅速衰减)
	var knock_velocity: Vector2 = Vector2.ZERO
	# 击退向量指数衰减率(越大停得越快;约 0.15s 衰减到 ~10%)
	@export var knock_decay_rate: float = 15.0
	# 爆炸设 knock_velocity 时的封顶(防止大击退把活怪轰出屏)
	@export var max_knock_velocity: float = 2500.0
```

(b) `_physics_process`(第 76-89 行)叠加与还原 —— `_anim_update()` 之后、接触伤害之前加 `velocity += knock_velocity`;`move_and_slide()` 之后、`_wrap()` 之前加还原 + 衰减:

```gdscript
	_ai(delta)
	_anim_update()
	# 爆炸击退向量叠加:独立于 AI 移动速度,叠加后 move_and_slide 再还原,指数衰减
	velocity += knock_velocity
	# 接触伤害:物理 Area 覆盖常规情况;环面接缝处欧氏距离不重叠,用环面距离兜底
	# contact_damage<=0 时跳过:零伤也会触发玩家 take_hit 消耗 iframe 并击退。
	if contact_damage > 0 and (_player_overlapping or toroidal_dist_to_player() <= CONTACT_RADIUS):
		var p := get_tree().get_first_node_in_group("player")
		if p != null and p.has_method("take_hit"):
			p.take_hit(global_position, contact_damage)
	if _hit_flash_time > 0.0:
		_hit_flash_time = maxf(_hit_flash_time - delta, 0.0)
		if _hit_flash_time == 0.0:
			modulate = Color.WHITE
	move_and_slide()
	velocity -= knock_velocity
	knock_velocity *= exp(-knock_decay_rate * delta)
	_wrap()
```

(c) `_apply_hit`(第 105-111 行)改为设独立向量 + 死亡折入:

```gdscript
	if set_velocity:
		# 爆炸:设独立击退向量(封顶),不覆盖移动速度;死亡时折入尸体速度
		knock_velocity = knock_dir.normalized() * minf(ks, max_knock_velocity)
	else:
		velocity += knock_dir.normalized() * ks
	if hp <= 0:
		velocity += knock_velocity
		knock_velocity = Vector2.ZERO
		# 死亡:限制尸体飞行速度(爆炸级击退 2500 会把尸体瞬移出屏,压到可看的速度)
		if velocity.length() > max_death_fly_speed:
			velocity = velocity.normalized() * max_death_fly_speed
```

同时把第 101 行 `_apply_hit` 的注释更新为:`set_velocity=true(爆炸):设独立击退向量 knock_velocity(封顶),不覆盖移动速度;false(枪击):叠加到原速度。`

- [ ] **Step 4: 跑测试确认通过**

Run: 冒烟命令(enemy_logic_smoke.gd)
Expected: `SMOKE OK`(含新断言「爆炸设独立击退向量 300 / 爆炸不覆盖移动速度 / 爆炸击退纯径向 / 爆炸击退向量随帧衰减」,以及旧「枪击击退叠加 500+300=800」仍通过)。

- [ ] **Step 5: 提交**

```bash
cd "E:/Workspace/godot/the-cyancular-ruins"
git add Scenes/Enemies/enemy_base.gd Tests/enemy_logic_smoke.gd
git commit -m "feat: 敌人爆炸击退改独立向量(knock_velocity)大冲击迅速衰减, 不覆盖移动速度"
```

---

### Task 2: 玩家爆炸击退独立向量(player + PlayerParams)

**Files:**
- Modify: `Scenes/Player/player.gd`
- Modify: `Globals/playerParams.gd`
- Test: `Tests/enemy_logic_smoke.gd`(在 Task 1 的 ov 段之后、`if _failures.is_empty():` 之前插入)

**Interfaces:**
- Consumes: 无。
- Produces: `Player.take_hit(source_pos: Vector2, damage: int, ignore_iframes: bool = false, knockback: float = -1.0)`(`knockback<0`=旧固定击退,`>=0`=爆炸设 `knock_velocity`);`Player.knock_velocity: Vector2`;`PlayerParams.player_knock_decay_rate: float = 12.0`。

- [ ] **Step 1: 写失败测试**

在 `Tests/enemy_logic_smoke.gd` 的 `ov.free()` / `MazeGenerator.current_grid = []`(Task 1 段结尾)之后、`if _failures.is_empty():` 之前插入:

```gdscript
	# ── 玩家爆炸击退独立向量:take_hit 传击退 → 向量生效并衰减 ──
	var pk := player_scene.instantiate()
	pk.global_position = Vector2(1000, 400)
	root.add_child(pk)
	await physics_frame
	pk.take_hit(Vector2(800, 400), 5, false, 800.0)
	_check(is_equal_approx(pk.knock_velocity.x, 800.0), "玩家爆炸击退设独立向量")
	var pk0: float = pk.knock_velocity.x
	for i in range(5):
		await physics_frame
	_check(pk.knock_velocity.x < pk0, "玩家击退向量随帧衰减")
	pk.free()
```

(注:`player_scene` 已在冒烟测试第 197 行声明,同一函数作用域内可用。)

- [ ] **Step 2: 跑测试确认失败**

Run: 冒烟命令(enemy_logic_smoke.gd)
Expected: FAIL —— `pk.take_hit(..., 4 参)` 因现有 `take_hit` 只有 3 参报参数过多;`pk.knock_velocity` 不存在。

- [ ] **Step 3: 实现玩家独立击退向量**

`Globals/playerParams.gd`,在 `player_hit_knockback_up`(第 39 行)后加:

```gdscript
	const player_knock_decay_rate: float = 12.0  # 爆炸击退向量指数衰减率(越大停得越快)
```

`Scenes/Player/player.gd`:

(a) 在战斗变量区(`downed` 声明,第 41 行)后加:

```gdscript
	var knock_velocity: Vector2 = Vector2.ZERO  # 爆炸专属击退向量(独立于移动速度,指数衰减)
```

(b) `take_hit`(第 237-253 行)签名加 `knockback: float = -1.0`,按值分路:

```gdscript
func take_hit(source_pos: Vector2, damage: int, ignore_iframes: bool = false, knockback: float = -1.0) -> void:
	# ignore_iframes: 特殊攻击(如冲撞)穿透无敌帧,但命中后照常刷新 iframes。
	if downed or (iframes > 0.0 and not ignore_iframes):
		return
	# 冲刺被打断:否则下一帧 is_charge 分支会用冲刺速度覆盖本次击退
	is_charge = false
	charge_timer = 0.0
	hp -= damage
	iframes = PlayerParams.iframes_time
	var away := (global_position - source_pos).normalized()
	if away == Vector2.ZERO:
		away = Vector2(-float(facing_direction), 0.0)
	if knockback < 0.0:
		# 常规命中:固定击退直接覆盖(原行为)
		velocity.x = away.x * PlayerParams.player_hit_knockback
		velocity.y = away.y * PlayerParams.player_hit_knockback - PlayerParams.player_hit_knockback_up
	else:
		# 爆炸:设独立击退向量(叠加,不覆盖移动),随帧指数衰减
		knock_velocity = away * knockback
	hp_changed.emit(hp, max_hp)
	if hp <= 0:
		_downed()
```

(c) `_physics_process` 执行移动段(第 229-234 行)叠加 + 还原 + 衰减:

```gdscript
	# ---------- 爆炸击退向量叠加(独立衰减,不污染移动速度) ----------
	velocity += knock_velocity

	# ---------- 执行移动 ----------
	move_and_slide()
	velocity -= knock_velocity
	knock_velocity *= exp(-PlayerParams.player_knock_decay_rate * delta)

	# 环面回卷：玩家只能在中间副本，离开时取模送回
	global_position = MazeGenerator.wrap_to_range(global_position,
			GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
```

(d) `_downed()`(第 291 行)清残留击退:

```gdscript
func _downed() -> void:
	downed = true
	knock_velocity = Vector2.ZERO  # 倒地锁速,清掉残留冲击
	if _weapon != null:
```

- [ ] **Step 4: 跑测试确认通过**

Run: 冒烟命令(enemy_logic_smoke.gd)
Expected: `SMOKE OK`(含「玩家爆炸击退设独立向量 / 玩家击退向量随帧衰减」;既有玩家相关断言仍通过)。

- [ ] **Step 5: 提交**

```bash
cd "E:/Workspace/godot/the-cyancular-ruins"
git add Scenes/Player/player.gd Globals/playerParams.gd Tests/enemy_logic_smoke.gd
git commit -m "feat: 玩家爆炸击退独立向量(take_hit 支持传击退), 不覆盖移动速度"
```

---

### Task 3: 爆炸把击退传给玩家(explosion.gd)

**Files:**
- Modify: `Globals/explosion.gd`
- Test: `Tests/grenade_smoke.gd`(StubPlayer 记录第 4 参 + 玩家击退断言)

**Interfaces:**
- Consumes: Task 2 的 `Player.take_hit(source, damage, ignore_iframes=false, knockback=-1.0)`。
- Produces: `Explosion.apply_aoe` 对玩家调用 `take_hit(center, dmg, false, knockback)`(击退 = `_falloff(d, radius, max_knockback) * (0.5 if blocked else 1.0)`)。

- [ ] **Step 1: 改测试(StubPlayer 记录击退 + 断言)**

`Tests/grenade_smoke.gd`:

(a) StubPlayer 类(第 22-32 行)加记录字段与第 4 参:

```gdscript
class StubPlayer:
	extends CharacterBody2D
	var hit_log: Array = []
	var knock_log: float = -1.0
	func _init() -> void:
		add_to_group("player")
		collision_layer = 2
		collision_mask = 0
	func take_hit(_source_pos: Vector2, damage: int, _ignore_iframes: bool = false, knockback: float = -1.0) -> void:
		hit_log.append(damage)
		knock_log = knockback
	func is_downed() -> bool:
		return false
```

(b) `_test_aoe` 里「玩家友伤满值 35」断言(第 106-108 行)后追加击退断言:

```gdscript
	exp.apply_aoe(Vector2(200, 200), 128.0, 35, 900.0)
	_check(p.hit_log.has(35), "玩家友伤满值 35")
	_check(is_equal_approx(p.knock_log, 900.0), "玩家受击收到满值击退 900")
	p.free()
```

- [ ] **Step 2: 跑测试确认失败**

Run: 冒烟命令(grenade_smoke.gd)
Expected: FAIL —— `GRENADE SMOKE OK` 出现前,「玩家受击收到满值击退 900」失败(`knock_log` 仍为初始 `-1.0`)。

- [ ] **Step 3: 实现 explosion.gd 传击退给玩家**

`Globals/explosion.gd`,玩家分支(第 25-29 行)改为:

```gdscript
	var p := tree.get_first_node_in_group("player")
	if p != null and p.has_method("take_hit") and not (p.has_method("is_downed") and p.is_downed()):
		var d := _dist(center, (p as Node2D).global_position)
		if d <= radius:
			var blocked := has_grid and not _has_los(center, p as Node2D, grid)
			var mult := 0.5 if blocked else 1.0
			# 击退随距离衰减传入玩家(独立击退向量结算)
			p.take_hit(center, int(_falloff(d, radius, max_damage) * mult), false,
					_falloff(d, radius, max_knockback) * mult)
```

- [ ] **Step 4: 跑测试确认通过**

Run: 冒烟命令(grenade_smoke.gd) + 冒烟命令(enemy_logic_smoke.gd)
Expected: `GRENADE SMOKE OK`(含「玩家受击收到满值击退 900」)且 `SMOKE OK`。

- [ ] **Step 5: 提交**

```bash
cd "E:/Workspace/godot/the-cyancular-ruins"
git add Globals/explosion.gd Tests/grenade_smoke.gd
git commit -m "feat: 爆炸把击退传给玩家 take_hit(独立击退向量结算)"
```

---

## 完成标准

- `enemy_logic_smoke.gd` 与 `grenade_smoke.gd` 均 `OK`。
- 枪击击退、冲撞冲击、接触伤害等非爆炸路径代码未改动。
- 玩家 playtest:被榴弹近爆轰开是「明显一推、迅速收住」,不是缓慢漂移;敌人被炸同理,且飞行敌人的 AI 寻路不被击退向量破坏。
