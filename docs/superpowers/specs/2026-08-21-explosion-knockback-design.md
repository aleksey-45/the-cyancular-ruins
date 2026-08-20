# 爆炸击退重做:大冲击 + 迅速衰减(独立击退向量)

日期:2026-08-21
状态:设计已确认(用户)

## 背景与问题

- 当前爆炸击退是「一次性覆盖 `velocity`」(`_apply_hit` 的 `set_velocity=true`)。但活着的敌人下一帧就被自己的移动逻辑接管:
  - 飞鸟 AI 每帧 `_follow_path`/`_glide_to` 把 `velocity` 设回 `fly_speed`(320),大冲击只生效 1 帧(瞬时跳 ~83px)就被盖掉。
  - 地面怪(JumpBird)靠 `GROUND_FRICTION=0.85`/帧慢慢滑,又远又飘。
- 玩家被爆炸击退固定为 `PlayerParams.player_hit_knockback=400`,不随爆炸强度缩放;地面移动代码 `_approach(brake_ground=16)` 每帧快速吃掉击退,所以几乎看不出被炸飞。

## 目标

- 爆炸击退 = 大冲击 + 迅速衰减,独立于移动速度结算。
- **只改爆炸路径**;枪击(叠加击退)保持不变。
- 敌人和玩家都上独立击退向量。

## 设计

### 敌人(`EnemyBase` / 两子类)

- 新增 `knock_velocity: Vector2`。
- 爆炸命中(`_apply_hit` 的 `set_velocity=true`)→ `knock_velocity = knock_dir.normalized() * ks`(**不再覆盖 `velocity`**)。
- 每帧移动结算前叠加:AI 设好 `velocity` 后,`velocity += knock_velocity`;`move_and_slide()` 后 `knock_velocity *= exp(-knock_decay_rate * delta)`。
- 死亡:把 `knock_velocity` 折进 `velocity`(沿用现有尸体滑动 + 水平阻力 + 重力);冲撞死清速逻辑不变;仍受 `max_death_fly_speed` 封顶。
- 新导出参数:
  - `knock_decay_rate: float = 15.0`(指数衰减率;约 0.15s 衰减到 ~10%)
  - `max_knock_velocity: float = 2500.0`(设置 `knock_velocity` 时的封顶,防止 5000 把活怪轰出屏)

### 玩家(`player.gd`)

- 新增 `knock_velocity: Vector2`。
- `take_hit` 增加 `knockback: float = -1.0` 参数:
  - `-1`(默认)= 旧行为:固定 `player_hit_knockback` 直接设 `velocity`。
  - `>=0`(爆炸)= 设 `knock_velocity = away * knockback`(叠加,不覆盖移动)。
- 每帧 `move_and_slide()` 前 `velocity += knock_velocity`,后 `knock_velocity *= exp(-player_knock_decay_rate * delta)`。
- 玩家移动代码每帧 `_approach` 会把速度额外拉向输入目标,叠加后自然形成「大冲击 + 迅速衰减」。

### 爆炸调用点(`explosion.gd`)

- 敌人:已传 `set_velocity=true`,语义改为「设 `knock_velocity`」。
- 玩家:`p.take_hit(center, dmg, false, falloff_knockback)`(含遮挡减半后的击退值)。

### 新参数汇总

| 位置 | 参数 | 默认 |
|---|---|---|
| `EnemyBase` | `knock_decay_rate` | 15.0 |
| `EnemyBase` | `max_knock_velocity` | 2500.0 |
| `PlayerParams` | `player_knock_decay_rate` | 12.0 |

## 测试

- `Tests/enemy_logic_smoke.gd`:爆炸命中活着的鸟 → `velocity`(移动本体)不被覆盖,`knock_velocity` 独立衰减(隔几帧变小)。现有「枪击叠加 500+300=800」断言必须仍通过(枪击不受影响)。
- `Tests/grenade_smoke.gd`:现有爆炸相关断言保持通过;补玩家断言——`take_hit(center, dmg, false, knock)` 后 `knock_velocity` 非零且随帧衰减。

## 边角

- 冲撞死/受击死沿用现有逻辑(`knock_velocity` 折入 `velocity` 后走死亡物理)。
- 睡着的鸟被炸:`velocity` 未被 AI 设值,叠加 `knock_velocity` 后滑出,衰减后停。
- 玩家倒地(`downed`):清空 `knock_velocity`(倒地逻辑已锁速度,避免残留冲击)。
- 枪击、接触伤害、冲撞冲击(`_apply_charge_impact`)等非爆炸击退一律不动。
