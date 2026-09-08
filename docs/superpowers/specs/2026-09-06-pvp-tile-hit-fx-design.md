# PvP 打墙命中反馈(TileHitFx)设计

日期:2026-09-06
范围:`scenes/weapons/bullet_base.gd`(撞墙分支 + `_damage_tile_at`)。不改协议、不改网格权威、不涉及爆炸/敌人。

## 问题

PvP 下本地玩家子弹是**视觉副本**(`apply_damage=false`,Level0.pvp_mode 下 weapon 出弹即视觉)。`bullet_base.gd` 撞墙分支:

```gdscript
if apply_damage:
    _damage_tile_at(col.get_position(), col.get_normal())   # 视觉副本跳过整段
```

→ 视觉副本打可破坏砖(树叶/树干):不 damage 本地 grid(正确,避免幽灵墙),**但也不播任何粒子**。射手打墙"无命中反馈";只有服务器把整块拆掉广播 `tile_destroyed`,客户端才在破坏格播一次碎片(pvp_client.gd:241)。体感 = "打半天没反应,整块碎才闪一下"。

**单机对照**:单机子弹 `apply_damage=true`,`_damage_tile_at` 命中即 `damage_tile` + `TileHitFx.spawn`(bullet_base:152-153),已满足"扣血就播"。无需改。

## 目标

PvP 客户端视觉副本撞可破坏砖 → **本地即时播一次 TileHitFx 碎片**(纯视觉),与单机一致的命中反馈;damage 仍只由权威(服务器)裁决,客户端不拆本地 grid,不破坏幽灵墙纪律。

## 方案

把 `_damage_tile_at` 拆成两个职责,让"播碎片"不依赖 `apply_damage`:

1. `_damage_tile_at(pos, normal)` 内部改为:
   - 探格找到非 0 格 + `bullet_destroyable`(原逻辑);
   - **无条件 `TileHitFx.spawn(get_viewport(), pos, tex)`**(纯反馈);
   - **`damage_tile` 仅在 `apply_damage` 时调用**(damage 是权威侧职责)。
2. 撞墙 else 分支去掉 `if apply_damage:` 包裹,直接调 `_damage_tile_at(...)`,使视觉副本也走探格+播碎片。

行为矩阵(改动后):

| 场景 | apply_damage | 播碎片 | damage_tile(改 grid) |
|---|---|---|---|
| 单机子弹命中可破坏砖 | true | ✓(同现状) | ✓(同现状) |
| PvP 服务器权威子弹命中可破坏砖 | true | ✓(headless 不可见,无副作用,同现状) | ✓ |
| PvP 客户端视觉副本命中可破坏砖 | false | **✓(本次新增反馈)** | ✗(保持,无幽灵墙) |
| 任何子弹命中不可破坏墙(石头) | - | ✗(探格非 bullet_destroyable,return) | ✗ |

约束保持:
- 视觉副本**绝不** damage 本地 `MazeGenerator.current_grid` / hp_grid(幽灵墙根因,现状已守,本次不破坏)。
- 拆墙渲染仍由服务器 `tile_destroyed` 事件驱动客户端清瓦片(不改)。
- 爆炸路径 `Explosion._damage_tiles` **不纳入**(爆炸自身有 explosion 动画;拆墙由 tile_destroyed 清瓦片)。用户已确认。
- PvP 视觉副本弹道与服务器略异(散布随机):播碎片位置用客户端自身碰撞点——只作即时反馈,不影响权威,可接受。

## 文件

- **Modify** `scenes/weapons/bullet_base.gd`
  - 撞墙 else 分支(约 95-106):去 `if apply_damage:` 包裹,恒调 `_damage_tile_at`,更新注释(视觉副本=播碎片不拆格)。
  - `_damage_tile_at`(约 136-154):`TileHitFx.spawn` 无条件;`TileDefs.damage_tile` 加 `if apply_damage:` 守卫;更新函数注释。

## 测试

- 视觉副本不拆格 + 播碎片,headless 可断言:探格逻辑已是纯函数式分支。做一个轻量冒烟或并入现有?
  - 直接可复用:bullet 撞墙分支需要物理世界+子弹移动,较重。
  - 务实做法:加一个针对性 scene 冒烟 `tests/bullet_tile_fx_smoke.gd`:建含一列可破坏砖(树叶 15)+ 一列不可破坏墙的世界,放一颗 `apply_damage=false` 子弹射向可破坏砖,步进数帧,断言:
    a) `MazeGenerator.current_grid` 该格**未变**(无 ghost damage);
    b) 世界 viewport 下新增了 CPUParticles2D(TileHitFx 播了);
    c) 另发一颗打不可破坏墙,无粒子。
  - 若实现成本过高,冒烟可退化为"探格判定 + spawn 条件"的源码级检查(参考 player_contract_smoke 风格)。
- 回归:`enemy_logic_smoke` + 三个 PvP 冒烟(twin/reconcile/match)须保持绿。

## 不做(范围外)

- 不改协议 / 不加 tile_hit RPC(客户端本地判定,0 延迟,用户已选)。
- 不加服务器广播命中事件。
- 不改爆炸拆砖反馈。
- 不给永久墙加"撞墙扬尘"(撞不可破坏墙仍无粒子,同现状)。
