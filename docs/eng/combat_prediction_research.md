# 战斗预测资料

## 资料与可参考部分

| 资料 | 可参考部分及边界 |
|---|---|
| Blizzard：[Networking Scripted Weapons and Abilities](https://media.gdcvault.com/gdc2017/Presentations/Reed_Dan_NetworkingScriptedWeapons.pdf) | 武器/能力的命令帧和可恢复状态，明确输入、瞄准和实体状态 |
| Epic：[FPredictionKey](https://dev.epicgames.com/documentation/en-us/unreal-engine/API/Plugins/GameplayAbilities/FPredictionKey) | 预测操作身份、确认/拒绝和副作用去重；API 对属性、伤害等有适用限制，不能据此宣称所有死亡都可安全预测 |
| Riot：[VALORANT Hit Registration](https://playvalorant.com/en-gb/news/dev/the-state-of-hit-registration/) | 即时开火表现与权威命中确认分工 |
| DDNet：[projectile.cpp](https://github.com/ddnet/ddnet/blob/master/src/game/client/prediction/entities/projectile.cpp)、[laser.cpp](https://github.com/ddnet/ddnet/blob/master/src/game/client/prediction/entities/laser.cpp) | 已知攻击在预测世界内推进，碰撞与玩法需要共享规则 |
| Photon Quantum：[Game Events](https://doc.photonengine.com/quantum/v3/manual/quantum-ecs/game-events) | 用可辨认事件驱动表现，在重复模拟和确认之间处理去重 |
| Unity：[Ghost Spawning](https://docs.unity.cn/Packages/com.unity.netcode%401.5/manual/ghost-spawning.html) | 预测生成与权威实体匹配，生成身份和恢复边界需明确 |
| NetherRealm：[8 Frames in 16ms](https://media.gdcvault.com/gdc2018/presentations/Stallone_Michael_8FramesIn16ms.pdf) | 检查点、对象生存期与视觉副作用的恢复成本 |

### 商业游戏公开行为

| 资料 | 可参考部分及边界 |
|---|---|
| Valve：[CS2 命中与布娃娃预测更新](https://store.steampowered.com/news/posts/?appids=730&enddate=1733866481&feed=steam_announce%2F1000) | 预测表现可被确认或撤销；公开的是射手视角反馈，不能推出客户端有最终伤害或死亡裁决权 |
| Valve：[CS2 2024-08-14 更新](https://store.steampowered.com/news/posts/?appids=730&enddate=1724364740&feed=steam_community_announcements) | 稍延后受击减速以减少瞬移，代价是短暂保持速度；本项目没有采用该时序调整 |
| DICE：[Battlefield V 2019-02-12 更新，PDF 第 2 页](https://eaassets-a.akamaihd.net/dice-commerce/Casablanca/Update_Notes/20190212-01/Battlefield_V_Chapter_2_Lightning_Strikes_Update_12022019_FINAL.pdf) | 伤害消息节奏、HP 恢复和死亡后不同攻击类型的处理；不宜统一取消死者的全部攻击 |

## 当前采用

本地即时开火，稳定攻击 ID 对齐弹丸、爆炸和命中结果。已知攻击使用共享弹道、伤害、冲量、遮挡和地形规则预测本地影响。网络确认先比较实际执行结果及权威覆盖，再决定失效范围；一致确认不重复施加。

地形变化在后续接触查询前提交，音画按首次事件播放，重放静默。未知远端操作和近距离攻击仍需权威信息补齐。当前边界见[原生战斗](native_combat_simulation.md)与[确认规则](prediction_reuse.md)。
