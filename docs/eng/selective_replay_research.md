# 局部重放与因果依赖

## 资料与可参考部分

| 资料 | 可参考部分及边界 |
|---|---|
| Roblox 公开申请：[Flexible Netcode Architecture](https://patents.google.com/patent/US20260108808A1/en) | 描述按依赖关系选择回退范围的思路。专利说明不是商业部署效果证据 |
| Netfox：[修改回滚对象](https://foxssake.github.io/netfox/latest/netfox/tutorials/modifying-objects-during-rollback/)、[NetworkRollback](https://github.com/foxssake/netfox/blob/main/addons/netfox/rollback/network-rollback.gd)、[交互反例 #383](https://github.com/foxssake/netfox/issues/383) | 部分对象单独重放可能漏掉推动；新的接触也可能进入原本为空的范围。问题中的反例不能直接当作所有版本现状 |
| Unity：[Introduction to Prediction](https://docs.unity.cn/Packages/com.unity.netcode@1.5/manual/intro-to-prediction.html)、[Prediction Edge Cases](https://docs.unity.cn/Packages/com.unity.netcode@1.5/manual/prediction-details.html) | A/B 回到 tick 10、C/D 留在 tick 20 会产生交互误差；有依赖实体可分组，但组越大重算越多 |
| Epic：[Character Movement](https://dev.epicgames.com/documentation/en-us/unreal-engine/understanding-networked-movement-in-the-character-movement-component-for-unreal-engine)、[Networked Physics](https://dev.epicgames.com/documentation/en-us/unreal-engine/networked-physics-overview) | 本地 autonomous proxy 重放，远端简化代理和平滑；复杂物理可采用更大范围重模拟 |
| Epic：[Chaos Island Manager](https://dev.epicgames.com/documentation/en-us/unreal-engine/API/Runtime/Chaos/FPBDIslandManager)、[Collision Resim Cache](https://dev.epicgames.com/documentation/unreal-engine/API/Runtime/Chaos/Chaos/Framework/FPhysicsSolverBase/SetUseCollisionResimCache?application_version=5.5) | 物理岛与重模拟缓存提供另一种分组思路，不等于应用层任意实体可独立重放 |
| Photon：[Quantum Prediction Culling](https://doc.photonengine.com/quantum/v3/manual/prediction-culling)、[Fusion Physics](https://doc.photonengine.com/fusion/v2/manual/physics/physics-overview) | 限制预测范围或选择不同代理精度；共享 RNG 等隐含依赖也要隔离 |
| Psyonix：[Rocket League](https://media.gdcvault.com/gdc2018/presentations/Cone_Jared_It_Is_Rocket.pdf) | 动态接触对时间线敏感，代理精度和重算范围需要取舍 |
| Bauer 等，SIGSIM-PADS 2015：[Efficient Inter-Process Synchronization](https://user.it.uu.se/~bengt/Papers/Full/pads15.pdf) | 离散事件模拟的因果依赖与同步；是方法参考，不是角色碰撞的直接实现 |

## 可参考的判断

局部重放必须说明读写依赖、对象所处 tick/阶段、遗漏依赖时的恢复策略。只记录已经发生的接触不够，新轨迹可能进入原本为空的查询。只重放本地角色也不能把其他碰撞对象固定在当前显示位置。

## 当前采用

本地完整预测、远端只读运动代理。记录并复核实际几何和阶段依赖，包括空查询；同 tick 锚点与命令一致时保留前缀。无法证明有效时恢复权威锚点，网络触发请求在一个接纳批次合并。

没有构建全世界通用因果图、Chaos 物理岛或任意实体独立回滚框架。具体规则见[本地预测](local_prediction_design.md)和[历史复用](prediction_reuse.md)。
