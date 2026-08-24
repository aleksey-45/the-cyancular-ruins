# BlackBird 敌人设计

日期: 2026-08-24
状态: 已确认

## 背景

新增地面敌人「BlackBird」（黑鸟）。贴图 `assets/textures/black_bird.png`(200×200, 48px 帧)与场景 `Scenes/Enemies/EnemyBlackBird.tscn` 已就位(含 run/take_off/wake_up/fall_asleep/jump_backward/sleep 六动画),但场景未完成(无脚本/scale/碰撞层/数值)。

核心玩法: 睡眠 → 随机游走 → 周期性判定能否瞬移到**玩家面朝反方向**的地面落点 → 起飞动作后**瞬移** → 落地 → **带跳跃的地面冲锋**打 6 伤 → **大后跳**(命中/未命中都后跳) → 回到游走 → 玩家远离后入睡。是一个绕背瞬移的刺客型近战怪。

## 需求确认(与用户敲定的决策)

- **"角色后方" = 玩家面朝反方向**(背刺位),不是黑鸟所在位置的对面,也不是随机一侧。
- **冲锋 = 带跳跃的地面冲锋**(保持重力,遇墙/落差自动小跳翻越),不是直线水平冲刺。
- **大后跳**: 命中(6 伤)和未命中(超时)都触发,后跳落地后回游走。
- **落点有效性 = 地板格 + LOS**(`has_line_of_sight(落点格, 玩家格)`),不用地面 BFS(会把站在 1 格台阶上的玩家判为不可达,冲锋本可跳过)。
- **contact_damage = 0**: 只有冲锋打 6 伤;游走/后跳接触不扣血。
- **死亡无专用动画** → 白闪闪烁后销毁(同 FlyBird 模式)。
- demo.txt 加 3 个 `black_bird` 出生点便于直接测试。

## 架构

`EnemyBlackBird extends EnemyBase`(地面敌人,同 JumpBird 模式)。不用 `EnemyFlyBase` 飞行寻路——黑鸟全程着地(冲锋/后跳受重力),飞行碰撞箱/悬停不适用。

### 状态机

```
SLEEP → WAKE → WANDER → TAKE_OFF ──瞬移+落地──> CHARGE → BACK_HOP → WANDER …
  ↑                                                        │
  └────────────── 玩家离开范围入睡 ←───────────────────────┘
```

`enum State { SLEEP, WAKE, WANDER, TAKE_OFF, CHARGE, BACK_HOP }`

| 状态 | 行为 |
|---|---|
| SLEEP | 播 `sleep`。玩家进 `wake_radius` → WAKE,播 `wake_up` |
| WAKE | 播 `wake_up` 一次性 → WANDER |
| WANDER | 播 `run`,左右随机换向(`wander_min_t`~`wander_max_t`)。每 `flank_check_interval` 试一次瞬移判定:目标点 = 玩家位置 + 玩家面朝反方向 × `flank_distance`,周围 `flank_search_cells` 半径内搜「地板格」(EMPTY 且正下方 SOLID,环面取模);判定 = 地板格 且 `has_line_of_sight(落点格, 玩家格)`。找到 → TAKE_OFF。玩家距离 > `sleep_radius` → 播 `fall_asleep` → SLEEP |
| TAKE_OFF | 播 `take_off` 一次性(原地,给玩家预警)。播完 → 瞬移: `global_position = 落点格中心上方 teleport_drop px`,状态 CHARGE(带落地判定) |
| CHARGE | 播 `run`(快),重力保持,水平高速冲向玩家;`is_on_wall()` → 自动小跳(`charge_jump_velocity`)。命中玩家(`_player_overlapping` 或环面距离 ≤ CONTACT_RADIUS)→ `take_hit(pos, 6, ignore_iframes=true)` → BACK_HOP。超时 `charge_timeout` 未命中 → BACK_HOP。朝向随 `velocity.x` |
| BACK_HOP | 播 `jump_backward`。速度 = 远离玩家方向 × `back_hop_away` + `back_hop_up`。落地(`is_on_floor` + 冷却)→ WANDER |

落地阶段: 瞬移后重力下落,`is_on_floor()` 触发冲锋;加 `landing_timeout` 兜底(防 is_on_floor 未触发卡死,参考 FlyBird 落地 bug 教训)。

## 数值(EnemyParams.BlackBird 新嵌套类)

```gdscript
class BlackBird:
    const wake_radius: float = 950.0     # 苏醒
    const sleep_radius: float = 1200.0   # 玩家离开此距离 → 入睡
    const wander_speed: float = 240.0    # 游走速度
    const wander_min_t: float = 0.7      # 换向间隔下限
    const wander_max_t: float = 1.8      # 换向间隔上限
    const flank_check_interval: float = 1.6  # 游走中瞬移判定周期
    const flank_distance: float = 400.0  # 玩家后方目标距离(px)
    const flank_search_cells: int = 3    # 理想落点周围搜索半径(格)
    const teleport_drop: float = 60.0    # 瞬移到落点上方高度(px)
    const landing_timeout: float = 0.6   # 落地兜底
    const charge_speed: float = 1100.0   # 冲锋速度
    const charge_damage: int = 6         # 冲锋伤害(穿透无敌帧)
    const charge_timeout: float = 1.2    # 冲锋超时 → 未命中后跳
    const charge_jump_velocity: float = -650.0  # 遇墙自动跳
    const back_hop_up: float = -720.0    # 大后跳高度
    const back_hop_away: float = 460.0   # 大后跳距离
    const death_flash_time: float = 0.5  # 死亡白闪时长
```

场景导出: `hp 30`、`contact_damage 0`、`knockback_strength 200`、`scale 2.5`(同 JumpBird ~120px)、`collision_layer 4`、`collision_mask 7`。

## 死亡

覆写 `hurt()`: 继承基类 `_apply_hit`(白闪+击退),hp≤0 → `is_dead=true`,白闪闪烁 `death_flash_time` 后销毁;物理与生前一致(走基类 `_physics_process`)。参照 FlyBird 的白闪模式。

## 文件改动

1. `Globals/enemyParams.gd` — 加 `class BlackBird`
2. `Scenes/Enemies/enemy_black_bird.gd` — 新脚本(状态机 + 瞬移/冲锋/后跳)
3. `Scenes/Enemies/EnemyBlackBird.tscn` — 补 script/scale/collision 层/hp/contact_damage/knockback
4. `editor/enemies.json` — 注册 `black_bird` → EnemyBlackBird.tscn(含 name/color)
5. `editor/structure-editor.html` — ENEMY_REGISTRY 同步加一行
6. `map/demo.txt` — 加 3 个 `black_bird` 出生点(地板格)
7. `Tests/enemy_logic_smoke.gd` — 加 BlackBird 冒烟 Task
8. `CLAUDE.md` — 敌人列表加 BlackBird

## 测试(冒烟测试加一个 Task)

- 唤醒: 玩家进 wake_radius → WAKE → WANDER
- 游走: 状态为 WANDER,水平速度 ±wander_speed
- 落点判定: 构造墙/地形,验证只有地板格 + LOS 通才触发瞬移
- 瞬移+落地: TAKE_OFF 播完位置跳到落点上方,落地后进入 CHARGE
- 冲锋: 水平速度 = charge_speed 朝玩家;命中玩家 6 伤穿透无敌帧
- 大后跳: 命中/超时后进入 BACK_HOP,远离玩家方向
- 回游走: BACK_HOP 落地 → WANDER
- 入睡: 玩家远离 → fall_asleep → SLEEP
- contact_damage = 0: 接触不触发 take_hit
- 死亡: 白闪后销毁,保留碰撞/物理

## 验证

1. headless 跑冒烟测试 `-s res://Tests/enemy_logic_smoke.gd`(SMOKE OK)
2. headless 启动 `--quit-after 90` 无脚本报错
3. 用户 playtest(瞬移手感、冲锋速度、后跳幅度)
