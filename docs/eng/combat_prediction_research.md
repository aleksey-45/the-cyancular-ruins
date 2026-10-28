# 大型游戏的命中、死亡与运动预测

调研日期：2026-10-24。以下按各资料发表时公开的机制分析；代码范围未公开的部分不推定实现。本项目当前代码见 [CombatPrediction](../../core/net/combat_prediction.gd) 和 [PredictionRollback](../../core/net/prediction_rollback.gd)。

## 预测的边界

开火预测、命中表现、伤害预测和死亡预测是不同的选择。枪口火光与弹道可以立即出现，命中音效可以等待确认；本地模拟可以暂时进入倒地状态，战绩、掉落和复活仍由服务端结算。服务端权威决定谁的结果有效，客户端预测决定确认到达前如何响应。

### VALORANT：开火立即响应，命中等待确认

Riot 的 [The State of Hit Registration](https://playvalorant.com/en-gb/news/dev/the-state-of-hit-registration/) 明确区分枪口火光、曳光与命中确认。客户端立即表现开火，服务端按射击时间回查角色位置和动画姿态，裁决后返回命中特效与音效。命中反馈因此包含网络往返和处理时间。

[Peeking into VALORANT’s Netcode](https://www.riotgames.com/en/news/peeking-valorants-netcode) 还说明：服务端处理致命一击后，拒绝死者之后的射击。死者在获知死亡前仍可能看见本地开火。不能仅凭本地开火或命中特效断定最终伤害成立。

对本项目的启示：未知的远端攻击无法提前获知；收到权威死亡后，必须恢复死亡所在 tick 的状态再重放，不能让旧的存活分支继续生成有效行为。

### Counter-Strike 2：可撤销的伤害表现，单独处理受击减速

Valve 在 [2024 年 11 月与 12 月更新](https://store.steampowered.com/news/posts/?appids=730&enddate=1733866481&feed=steam_announce%2F1000) 中公开了身体命中、爆头和击杀布娃娃的预测设置，并说明它们可能受尚未知晓的死亡、受击扰动和减速影响而出错。后续更新使未及时获得确认或纠正的预测布娃娃恢复。该资料证明的是射手视角的表现预测，不能据此认定客户端拥有最终伤害裁决权，也未公开本地受害者是否提前锁定自己的死亡控制。

更贴近运动校正的是 [2024-08-14 更新](https://store.steampowered.com/news/posts/?appids=730&enddate=1724364740&feed=steam_community_announcements)：服务端稍微延后受击减速，以减少受击时瞬移；代价是受击者短暂保留原移动速度。

对本项目的启示：提前出现的死亡反馈必须可恢复；改变移动的受击效果需要双方一致的生效时间。CS2 的减速调整是玩法时间规则的改变，不能直接当作本项目击退参数或客户端平滑参数。

### Overwatch：武器状态有明确的恢复、复制与重放接口

Dan Reed 的 GDC 2017 [Networking Scripted Weapons and Abilities in Overwatch](https://media.gdcvault.com/gdc2017/Presentations/Reed_Dan_NetworkingScriptedWeapons.pdf) 描述了服务端权威的 Statescript。PDF 第 51 页区分远端复制与本地回滚、复制、重新模拟；第 56–57 页给状态和动作提供回滚接口；第 60 页列明历史数据范围。

尤其需要注意：Statescript 的历史不包含其他组件的数据，文档举例包括 health 与 filtering。因此，这份资料支持“可重放的武器与能力状态”，不支持“Overwatch 会完整预测所有人的 HP 和死亡”这一断言。

对本项目的启示：模拟状态的恢复与一次性音画反馈分开；明确哪些数据参加重放，不能遗漏影响下一 tick 的状态。

### Apex Legends：共享弹道，区分网络问题与模拟错误

Apex 首席工程师的 [服务器与网络深度说明](https://www.ea.com/games/battlefield/news/servers-netcode-developer-deep-dive) 解释：客户端预测弹道，可能出现血花和声音，但服务端不认可伤害；成因既包括网络，也包括弹道和碰撞模拟错误。文中列出过非点状弹丸的计算问题，并介绍用命中箱、轨迹与服务端日志定位。

对本项目的启示：弹丸尺寸、连续检测、接触顺序和角色姿态需要对照。伴随命中的校正仍须逐条建立因果，不能自动归入公网抖动。

### Halo Infinite：区分死亡通知延迟、模拟分歧与带宽不足

343 的 [Online Experience](https://www.halowaypoint.com/news/closer-look-halo-infinite-online-experience) 将命中分歧分成确定性问题、相关状态传输不足，以及客户端尚未获知死亡。说明中的旧模型拒绝已死亡玩家后续射击，对近战另有处理；还讨论了双方处在不同时间线时的角色碰撞问题。

这份资料描述的是其旧模型；官方 [March Update Preview](https://www.halowaypoint.com/news/march-update-preview) 已说明后续更换了网络模型。

对本项目的启示：死亡边界上的射击、近战与已飞行弹丸需要明确规则。碰撞必须使用预测时间的实体状态，显示用的远端插值位置不能直接充当当前预测碰撞体。

### Battlefield V：伤害顺序、反馈节奏和死亡边界分别处理

DICE 的 [2019-02-12 更新说明，PDF 第 2 页](https://eaassets-a.akamaihd.net/dice-commerce/Casablanca/Update_Notes/20190212-01/Battlefield_V_Chapter_2_Lightning_Strikes_Update_12022019_FINAL.pdf) 包括伤害序列的时间节奏、每包可携带的伤害更新数量、错误 HP 的恢复，以及死亡后的伤害规则。它区分普通子弹与榴弹、火箭等弹体，避免一概取消死者的所有攻击结果。

对本项目的启示：命中事件应保留原 tick 和顺序；传输中一起到达的伤害不应失去模拟时序。死亡也不等于删除此前已发射的榴弹。

### Rocket League：强物理交互需要一致的预测世界

Psyonix 的 GDC 2018 [It IS Rocket Science!](https://media.gdcvault.com/gdc2018/presentations/Cone_Jared_It_Is_Rocket.pdf) 分析了“预测车辆撞上插值球”导致两条时间线冲突的问题。最终方案使用输入缓冲和物理预测；需要纠正时，恢复相关物理实体的历史，再推进至当前时刻。讲稿也明确：球较可预测，其他车辆较难预测，纠正有计算成本。

这不是射击或死亡预测的直接范例，但对本项目的角色阻挡和强击退很相关：参与一次交互的模拟对象必须处于一致的时间线上。

## 本项目的 150 px 现场

保存的现场中，角色剩余 1 HP。tick 1864 的步枪命中造成 4 点伤害，应进入倒地状态；仅推进受力而保持存活，会让 tick 1866 再产生一次服务端不存在的重狙命中。后者的强冲量显著放大了轨迹分歧。

离线对照使用保存的角色状态、输入与远端提示，并在对应 tick 注入日志记录的两次接触向量。仅受力分支复现 150.384 px 差异，与原日志位置相差 0.000244 px；完整致死状态分支与较新权威分支的最终位置差为 0 px。该实验验证此处因果，不是完整网络和弹丸几何重放，也不代表其他实战校正已消失。

## 对当前设计的分析

本项目的弹丸具有飞行时间和强击退，HP、存活状态又会影响后续命中与碰撞。因此，已知攻击的预测需要覆盖相关模拟状态：伤害、倒地、朝向、击退、接地及动作许可。单独预测一个速度向量不足以维持后续模拟一致。

当前实现由完整 STATE 恢复权威基线，再按 tick 重放输入和已知攻击。HIT 携带权威结果；即使本地弹丸已经结束，结果仍可进入相应阶段。攻击 ID、tick、目标和命中来源区分一次逻辑命中。逻辑在每次重放时重新计算，音画反馈只表现一次。战绩、地形破坏、掉落和复活仍由服务端裁决。

这些资料不能证明死亡预测一定优于等待确认。需要同时衡量两种预测错误：未预测到实际死亡，以及预测死亡后被服务端恢复存活。验证时还应核对死亡后的后续假命中、确认覆盖时的重复受力，以及碰撞姿态能否完整恢复。减少校正次数不能替代这些行为验证。

Epic 的 [FPredictionKey](https://dev.epicgames.com/documentation/unreal-engine/API/Plugins/GameplayAbilities/FPredictionKey) 可补充理解预测副作用的撤销、确认去重和依赖关系。该 API 文档也列出 damage/healing 元属性与 Execution 的预测限制；它是框架参考，不能作为某款大型游戏完整预测伤害的证据。
