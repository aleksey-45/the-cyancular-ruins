# 敌人

单人关卡按地图的 `# enemy TYPE X Y` 元数据生成敌人。类型、场景与编辑器显示色来自 [enemies.json](../data/enemies.json)。数值由敌人场景和 [EnemyParams](../core/config/enemy_params.gd) 提供。`EnemyBase` 继承 `ServerBody`，持有活动碰撞形状并统一处理水体、击退、受击闪白和死亡状态。

| 类型 | 行为 |
|---|---|
| `jump_bird` | 地面巡逻，蓄力起跳接近玩家，后撤调整距离，并向玩家扑击 |
| `fly_bird` | 起飞巡逻，瞄向预估位置投弹。进攻时生命低于 25% 会发起自毁冲撞 |
| `black_bird` | 乌鸫在玩家附近醒来，寻找玩家身后的落点，传送、落地突进再后跳。击败后掉落 300 颗粒 |

飞行鸟在环面格上进行 A* 寻路，检查飞行碰撞箱、实心地形、水和附近实体的当前碰撞包围盒。站立与飞行切换形状，跨接缝跟随路径点时使用最短位移。 [飞行与寻路](../scenes/enemies/enemy_fly_bird.gd)

普通敌人死亡后仍短暂受重力和碰撞影响。单人回溯录制保留隐藏的尸体并关闭其碰撞，回到死亡前时恢复。乌鸫在回溯期间继续行动，时间加速时与玩家同速。 [EnemyBase](../scenes/enemies/enemy_base.gd) · [乌鸫](../scenes/enemies/enemy_black_bird.gd)
