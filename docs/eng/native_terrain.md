# 原生地形

`GDScript → 指令 → NativeTerrain → 事件 / 快照 → GDScript`

`NativeTerrain` 独占宏观网格、子格材质、HP、版本、预测差分、权威基线、单人回溯和碰撞布局。单人、服务端与客户端预测共用伤害、爆炸扫描和碰撞查询，按用途启用不同历史与输出。

## 指令与读取

`load_terrain()` 装载地图及材质配置。接触伤害、爆炸、权威补丁、检查点恢复和时间回溯通过领域方法同步执行。脚本负责地图解析、场景装配、AI 策略、会话、账户结算和表现；角色、弹丸及预测战斗直接访问原生地形。

网格和子格 getter 返回缓存的只读视图；HP 打包快照在数据版本变化时更新。调用方不得修改这些视图，也不能把持有视图理解成一份独立可写地图。

## 局部提交与输出

16px 子格变化只标记受影响的碰撞分块。正 HP 之间的伤害和恢复只更新 HP；子格存亡改变才更新几何、区域失效标记与显示。每个碰撞块覆盖 12×12 个宏观格，布局缓存保留 4 份，形状按布局复用。

碰撞变化在下一次依赖查询前由 `flush_collisions` 提交，显示由 `flush_visuals` 按最终状态提交到 TileMapLayer。Godot 持有 StaticBody2D、CollisionShape2D 及 3×3 环面副本的节点生命周期。相同占用布局不重复改动物理节点。

网络输出按子格合并最终 HP，每 tick 取出；破坏收益按角色汇总。通知为一次批量变化，恢复不生成新伤害或收益。地形查询与爆炸核使用有界缓存，相关几何变化使依赖失效；角色动态阻挡仍按所处阶段计算。

## 历史

单人历史在记录边界保存变化宏观格的首个改前值，二分定位时间区间后逆序恢复，保留残血与混合材质；结束回溯时裁剪未来。

联机预测保存按 tick 分组的稀疏差分和历史代号。权威确认平移基线、保留尚未覆盖的未来预测，并裁剪确认历史和爆炸核；完整契约见[预测复用](prediction_reuse.md)。

源码：[terrain.h](../../native/simulation/terrain.h)、[terrain.cpp](../../native/simulation/terrain.cpp)、[terrain_query.cpp](../../native/simulation/terrain_query.cpp)。设计依据见[地形边界调研](native_terrain_boundary_research.md)。
