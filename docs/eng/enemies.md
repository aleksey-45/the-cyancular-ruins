# 敌人

> 与源码冲突时以源码为准,读前先 `grep` 复核。

继承链 `EnemyBase → EnemyFlyBase → EnemyFlyBird`;`EnemyJumpBird` 与 `EnemyBlackBird` 直接继承 `EnemyBase`。

- `EnemyBase`(CharacterBody2D):导出 `hp` / `contact_damage` / `knockback_strength` / `knock_decay_rate`;状态机 `state`(int,各子类自带 `enum State`),子类覆写 `_ai(delta)` / `_anim_update()`。
- 受击/死亡白闪统一在基类:`_hit_flash_time` 取 `shared.hit_flash`(0.1s)、`_begin_death()` 死亡白闪 `shared.death_flash_time` 0.5s 后销毁;渲染走 `_flash_update()`(默认 modulate 纯白;黑鸟的 silhouette shader 覆写 COLOR,modulate 失效,改覆写 shader 参数)。
- `_set_facing()` 锁转向频率:两次翻转至少间隔 `shared.turn_min_interval` 0.5s。
- 死亡物理与生前一致:尸体继续走同一套 `_physics_process`(重力/摩擦/击退衰减/碰撞),只是 AI 不行动;被后续命中只吃击退不吃伤(`hurt` 的 `is_dead` 分支走 `_apply_knock_only`)。每帧 `move_and_slide()` 后 `_wrap()`;接触伤害走 ContactArea + 环面距离兜底。入 `enemies` 组。
- 回溯保留的尸体(`WorldRewind.hold_corpses`):白闪结束后隐藏待复活,那一刻必须同时 `collision_layer = 0`(复活时还原);飞鸟寻路按「层为 0 即不算障碍」过滤同一个量。不可只隐藏不摘层。精英不保留。
- `EnemyFlyBase`:飞行寻路。A* 按鸟自身飞行碰撞箱 + 场上实体碰撞箱判可走(`_bird_can_pass`);空路径直线兜底;被悬挑墙压到(死区)时水平逃逸;站/飞碰撞箱切换(`_apply_flight_collision`)。寻路参数耦合 `EnemyParams.FlyBird`。LOS / BFS 缓存 TTL ≈ 150ms(@60Hz),障碍只收 ≈600px 内的实体。
- `EnemyFlyBird`:状态机 SLEEP / TAKE_OFF / FLY / SHOOT / CHARGE / RETURN;平抛投弹(预测玩家速度);HP < 25% 单向切 CHARGE 冲撞(穿透无敌帧、撞后自毁);死亡白闪后销毁(物理与生前一致,保留碰撞);返程回家落地入睡。
- `EnemyJumpBird`:近战跳跃怪(跳 / 后跳 / 扑击);死亡物理与生前一致、保留碰撞。
- `EnemyBlackBird`:睡眠 → 随机游走 → 周期性判定玩家另一侧、距玩家 2~6 格(随机)的地板格落点(地板格 + LOS)→ 起飞上跳 → 落地播 disappear → 白闪 → 传送 → appear → 落地 → 带跳跃冲锋 7 伤(穿透无敌帧)→ 大后跳(命中/未命中都)→ 回游走;玩家远离则入睡。数值在 `EnemyParams.BlackBird`。
- **加新敌人** = 一个 `.tscn` + 在 `data/enemies.json` 的 `enemies` 数组加一条(`id` / `name` / `scene` / `color`);`EnemySpawner.TYPES` 是运行时加载结果,不手改。spawner 随机取「地板格」(EMPTY 且正下方 SOLID)布点。
- **数值表**:唯一真相源 = [`core/config/enemy_config.tres`](../../core/config/enemy_config.tres);schema / 默认值在 [`enemy_config.gd`](../../core/config/enemy_config.gd)(`class_name EnemyConfig extends Resource`)。访问入口仍是 [`EnemyParams`](../../core/config/enemy_params.gd),写法不变(`EnemyParams.FlyBird.wake_radius` / `EnemyParams.shared.hit_flash`)。
  - ★ 字段是**扁平 + 前缀**(`shared_` / `jump_bird_` / `fly_bird_` / `black_bird_`),不是 4 个子 Resource —— GDScript 的**内层类不能当 `@export` 类型**(实测 `Export type can only be built-in, a resource, a node, or an enum`)。内层类只作命名空间,每个常量是 `static var x = _CFG.<扁平名>`。
  - ★ 不用 getter:实测 getter→Resource 每次读比 `const` 慢 13.8×,而这些值在敌人 `_physics_process` 里每帧读(`enemy_fly_bird.gd` 单文件 52 处)。故在类加载时读一次;代价 = 改 `.tres` 要重启进程生效。
