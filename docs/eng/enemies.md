# 敌人

> 从 [`CLAUDE.md`](../../CLAUDE.md) 拆出(2026-10-03,**原文逐字未改**)。返回索引:[`CLAUDE.md`](../../CLAUDE.md)。
> 本文件覆盖:敌人(scenes/enemies/)。
> ★ 文档会过期 —— **任何冲突以源码为准**,读之前先 `grep` 复核。

### 敌人(scenes/enemies/)

继承链 `EnemyBase → EnemyFlyBase → EnemyFlyBird`;JumpBird 直接继承 `EnemyBase`:

- `EnemyBase`(CharacterBody2D):`hp/contact_damage/knockback_strength/knock_decay_rate` 导出参数;统一状态机 `state`(int,各子类自带 `enum State`);子类覆写 `_ai(delta)`/`_anim_update()`。**受击/死亡白闪统一在基类**:`_hit_flash_time`(0.1s)与 `_begin_death()`(死亡白闪 `shared.death_flash_time`=0.5s 后销毁)统一计时,渲染走 `_flash_update()`(默认 modulate 纯白;黑鸟因 silhouette shader 覆写 COLOR 而 modulate 失效,覆写本方法改走 shader 参数);`_set_facing()` 锁转向频率(两次翻转至少间隔 `shared.turn_min_interval`=0.5s,防来回抖)。**死亡物理与生前完全一致**——尸体继续走同一套 `_physics_process`(重力/摩擦/击退衰减/碰撞),只是 AI 不行动;尸体被后续命中只吃击退不吃伤(`hurt` 的 `is_dead` 分支走 `_apply_knock_only`)。每帧 `move_and_slide()` 后 `_wrap()`;接触伤害走 ContactArea + 环面距离兜底。入 `enemies` 组。★ **回溯保留的尸体是例外**(2026-10-03):`WorldRewind.hold_corpses` 期间死亡的怪在白闪结束后**隐藏待复活**,那一刻必须**同时摘掉碰撞层**(`collision_layer = 0`,复活时还原)——玩家 mask=5 里含敌人层,「看不见却仍挡人」就是用户报的**虚空碰撞箱**;飞鸟寻路也按「层为 0 即不算障碍」过滤同一个量。守卫 `tests/probe/rewind_phantom_probe`(★ `enemy_logic_smoke` 那条「JumpBird 死亡保留碰撞层」**只覆盖白闪那 0.5s**,覆盖不到隐藏期)。
- `EnemyFlyBase`:飞行寻路。A* 按**鸟自身飞行碰撞箱 + 场上实体碰撞箱**判可走(`_bird_can_pass`);空路径直线兜底;被悬挑墙压到(死区)时水平逃逸;站/飞碰撞箱切换(`_apply_flight_collision`)。寻路参数耦合 `EnemyParams.FlyBird`(当前唯一飞行敌人,接受该耦合)。
- `EnemyFlyBird`:状态机 SLEEP/TAKE_OFF/FLY/SHOOT/CHARGE/RETURN。平抛投弹(玩家速度预测);HP<25% 单向切 CHARGE 冲撞(穿透无敌帧、撞后自毁);死亡白闪后销毁(物理与生前一致,保留碰撞);返程回家落地入睡。
- `EnemyJumpBird`:近战跳跃怪(跳/后跳/扑击);死亡物理与生前一致、保留碰撞。
- `EnemyBlackBird`:绕背瞬移刺客(睡眠→随机游走→周期性判定玩家另一侧、距玩家 2~4 格(随机)的地板格落点(地板格 + LOS)→起飞上跳→落地播 disappear→白闪→传送→闪后空中播 appear→落地→带跳跃冲锋打 6 伤(穿透无敌帧)→大后跳(命中/未命中都)→回游走,玩家远离入睡);死亡白闪后销毁。数值在 `EnemyParams.BlackBird`。
- **加新敌人** = 一个 .tscn + 在 **`data/enemies.json`** 的 `enemies` 数组加一条(`id`/`name`/`scene`/`color` 四个字段;`EnemySpawner.TYPES` 是它的运行时加载结果,**不手改**)。spawner 随机取"地板格"(EMPTY 且正下方 SOLID)布点。编辑器侧内嵌的敌人注册表由 `node level_editor/sync-enemies.js` 从 `data/enemies.json` 重新生成(改了 json 忘跑 → 内嵌那份**静默漂移**;`--check` 只校验不写盘,漂移退出 1 并点名首个差异行;该脚本带**键覆盖守卫**,json 里加了字段没抄进 map 会直接 FAIL)。★ 中文显示名那条链已整体删除(2026-09-17):`display_name` 字段 / `EnemySpawner.DISPLAY_NAMES` / `display_name_of()` / `CombatFeedback.notify_enemy_killed` 全没了(用户裁定单机不要击杀播报;PvP 播报走 `kill_event` 载荷自带名字)。

