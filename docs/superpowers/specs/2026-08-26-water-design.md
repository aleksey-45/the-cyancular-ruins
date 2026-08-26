# 水(Water)设计

日期:2026-08-26
状态:已获批,待实现

## 目标

在 2D 平台 demo 中实现水体:分层渲染 + 水面晃动、浮力/游泳物理、溺水、FlyBird 避水、爆炸衰减、子弹阻力、水粒子效果。地图里由用户(编辑器)画水,**游戏侧自动判定水面**。

## 已确认的关键决策

- 三种鸟**物理上统一浮力**(落水都会浮);FlyBird 寻路把水当障碍(**只挡自身碰撞箱压到的水格**,正下方是水照常可飞)。
- 主角:水里水面/水下**都能水平游**,按上=上浮、按下=下沉,默认浮水面弹簧贴线;水下扣血不做。
- 落水鸟会**朝玩家水平游**(JumpBird/BlackBird 覆写钩子);无玩家时钩子给零 → 一直浮着(干瞪眼可接受)。
- **浮着不算溺水**:中心低于水面线才算 submerged,累计 5s 后每 1s 扣 5。
- 水的爆炸衰减 **25%**(目标所在格是水 → 伤害/击退 ×0.25)。
- 所有子弹(玩家 + 敌人)在水里受**速度方向阻力**(指数减速)。
- 水面溅水花、水体上浮气泡;仅**移动中**发射。

## 1. 瓦片与地图

- **纹理 21 = 水体**(structure.png row2 col0 纯蓝块)、**纹理 22 = 水面**(row2 col1 顶部亮线块)。两者 `type: "liquid"`。
- `Globals/tile_defs.json` 加 21/22:`hp=1`、`bullet_destroyable=false`、`explosion_destroyable=false`、`elastic=false`、**`explosion_decay=0.25`**。
- `Globals/tile_defs.gd`:`MAX_TEXTURE` 20→22;新增 `explosion_decay_of(texture)`(逐格,回落全局 `explosion_decay()`)。
- `Globals/maze_generator.gd`:v2 纹理字符加 `L`=21、`M`=22(`_texture_char_to_value` + `_value_to_texture_char`)。
- 地图只存 21(水);22 由渲染自动派生。编辑器调色板扩到 22。

## 2. 渲染(水体/水面分层 + 晃动)

- `Level0._create_wall_tileset()`:砖提取循环 20→22,atlas 16×22(`texture_of-1` 映射行,tex21→行20,tex22→行21)。
- `Scenes/Level0.tscn` 加两个 TileMapLayer:`WorldViewport/WaterLayer`、`WorldViewport/WaterSurfaceLayer`。
- `Level0._paint_maze` 分流(3×3 环面副本):
  - liquid 且上方非 liquid → `WaterSurfaceLayer`(atlas 行 21);
  - liquid 且上方也是 liquid → `WaterLayer`(atlas 行 20);
  - 其余 → `WallLayer`(现状不动)。
  - 上方判定 toroidal:`posmod(y-1, rows)`。
- **水面晃动**:`Level0._process` 里 `WaterSurfaceLayer.position.x = round(sin(water_time × sway_speed) × sway_amp)`;水体层不动。整数取整保像素级干净。
- `GameParameters`:`water_sway_amp=2.0`、`water_sway_speed=0.8`。

## 3. 水物理(`Globals/water.gd`,`class_name Water` 静态,仿 TileDefs)

- `is_liquid(tex)` → `TileDefs.type_of(tex) == "liquid"`。
- `is_in_water(pos)` → 该点所在格是 liquid。
- `surface_y_at(pos)` → 所在列向上扫到最顶 liquid 格,返回其顶边 y(px);点不在水里时返回 `pos.y`(无水面则不平拉)。
- `submerged(center, surface_y)` → `center.y > surface_y`。

### 主角(`Scenes/Player/SwimComponent`,与 ClimbComponent 同风格,根每帧调用)

- 判水:脚底点 `(center.x, feet.y)` 在水格。
- 在水中:重力/跳跃/土狼/下蹲/冲刺**整体跳过**,改为:
  - 水平:左右键照常,`velocity.x` 缓动向 `horizontal × player_swim_speed`;
  - 垂直:按上 → `-player_swim_up`;按下 → `+player_swim_down`;无输入 → 弹簧回水面(`feet` 贴 `surface_y`);
  - 不扣血(水下扣血未做)。
- 出水(脚底脱离水面线)→ 恢复普通物理。
- `PlayerParams`:`player_swim_speed / player_swim_up / player_swim_down / player_swim_accel`。

### 敌人(`EnemyBase._physics_process` 统一接入)

- 落水(脚底在水格)→ 跳过重力累积,浮力弹簧贴水面;水平速度缓动向 `_water_swim_dir()`(基类钩子默认 `Vector2.ZERO` = 漂着)。
- `EnemyJumpBird` / `EnemyBlackBird` 覆写 `_water_swim_dir()` = `toroidal_dir_to_player()`。
- `EnemyParams.shared`:`bird_swim_speed=260.0`。

## 4. 溺水(敌人)

- `submerged`(中心低于水面线)→ 累计 `_water_time`;出水即清零。
- `_water_time > drown_delay` 后每 `drown_interval` 调 `hurt(drown_damage, Vector2.ZERO)`(无击退)。浮在水面不算。
- `EnemyParams.shared`:`drown_delay=5.0`、`drown_interval=1.0`、`drown_damage=5`。

## 5. FlyBird 避水

- `EnemyFlyBase._bird_can_pass`:候选格 `TileDefs.is_blocked(...) or Water.is_liquid(...)` → 不可走。**只挡自身飞行箱压到的水格;正下方是水不挡**(可飞越大湖面)。

## 6. 爆炸衰减 25%

- `tile_defs.json` 逐格 `explosion_decay`(水 0.25,缺省回落全局 0.75);`TileDefs.explosion_decay_of(tex)`。
- `Explosion.apply_aoe`:对每个目标,所在格是 liquid → 伤害/击退再 × `explosion_decay_of(tex)`(0.25)。LOS 遮挡 75% 逻辑不变。

## 7. 子弹阻力

- `BulletBase` 加 `_apply_water_drag(delta)`:位置在水格 → `velocity_vec *= exp(-water_bullet_drag × delta)`。
- `BulletBase._physics_process` 与 `EnemyBullet._physics_process` 都调用(共享方法,防逻辑漂移)。
- `GameParameters.water_bullet_drag=2.0`。

## 8. 水粒子(`Scenes/Effects/water_fx.gd`)

- `class_name WaterFx extends Node2D`,自驱动;运行期 `add_child` 挂到主角(`player._ready`)与所有敌人(`EnemyBase._ready`),不改 .tscn。
- 每帧读父实体:不在水里 → 不发射;在水里但 `velocity.length() < move_threshold` → 不发射(**移动才有粒子**)。
- 两种模式:
  - **水面 → 溅水花**:脚底距水面线 ≤ splash_band,在 `(center.x, surface_y)` 每隔 ~0.15s 撒一簇(UP、spread ~40°、带重力回落、浅蓝白)。
  - **水体 → 上浮气泡**:在 `(center.x, feet.y)` 每隔 ~0.12s 撒一簇(UP、spread ~10°、无重力微升速、小半透明浅蓝)。
- 复用 `tile_hit_fx` 的 4×4 白贴图缓存 + 染色,一次性 `CPUParticles2D` 播完自毁。
- 参数(`GameParameters`):`water_fx_move_threshold=40.0`(低于此速度不发射)、`water_fx_splash_band=20.0`(脚底距水面线 ≤ 此值算溅水花)、`water_fx_splash_interval=0.15`、`water_fx_bubble_interval=0.12`。

## 9. 编辑器

- `editor/structure-editor.html`:`buildPalette` 循环 `t<=20` → `t<=22`(swatch 背景已支持第 3 行)。
- `node editor/sync-tiles.js` 重新生成 `editor/tile_defs.js`(带上 21/22 定义)。

## 10. 测试(用户自跑)

- `Water` 静态助手可 `-s` 直接测。
- 冒烟/探针扩展:水面线判定、溺水计时、FlyBird 水格不可走、爆炸目标在水里 ×0.25、子弹水中减速。

## 不做(本次范围外)

- 玩家水下扣血 / 呼吸条。
- 鸟的复杂游泳动画与状态机(仅水平朝玩家漂移)。
- 水流/横向推动。
- 子弹入水后弹道改变(仅阻力)。
- 水花/气泡的音效。
