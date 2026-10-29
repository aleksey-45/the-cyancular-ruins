# LoL、CS 与预测范围

## 资料与可参考部分

| 资料 | 可参考部分及证据边界 |
|---|---|
| Valve：[Source Multiplayer Networking](https://developer.valvesoftware.com/wiki/Source_Multiplayer_Networking)、[Lag Compensation](https://developer.valvesoftware.com/wiki/Lag_Compensation) | 本地输入预测、远端插值、服务端历史命中查询各自负责不同时间和对象 |
| Source SDK：[prediction.cpp](https://github.com/ValveSoftware/source-sdk-2013/blob/master/src/game/client/prediction.cpp) | 保存命令与预测字段，在条件满足时复用结果；该公开代码不能当作 CS2 完整现状 |
| Riot：[Art of Spell Casting 1](https://www.riotgames.com/en/news/art-of-spell-casting-part-1)、[Part 2](https://www.riotgames.com/en/news/art-of-spell-casting-part-2) | 本地施法反馈、请求排队、服务器确认与取消，按操作选择预测范围 |
| Riot：[Approach to Anti-Cheat](https://www.riotgames.com/en/news/riots-approach-anti-cheat) | 服务器权威和信息可见性约束，客户端不一定拥有完整世界信息 |
| Riot 工程师：[Game Engineers AMA](https://www.reddit.com/r/leagueoflegends/comments/dib488/we_are_league_game_engineers_ama/) | 当时对 Yuumi Q 输入与路径的说明，可用于理解本地表现和服务器处理分工，不外推全部技能 |
| Riot：[Determinism](https://www.riotgames.com/en/news/determinism-league-legends-introduction) | Chronobreak 面向确定性服务端恢复，不能推出普通 LoL 客户端重放整场团战 |

## 可参考的判断

复杂玩家交互并不要求所有客户端完整重放所有玩家。决定预测范围的是本地需要的即时反馈、服务器权威边界和能够重建的依赖。远端显示状态与参与本地碰撞的代理应区分；服务器历史命中查询不能代替客户端恢复。

### 历史命中查询细节

Valve 的 [2016-09-09 更新](https://blog.counter-strike.net/2016/09/15820/)涉及历史姿态与旋转，[2016-10-28 更新](https://blog.counter-strike.net/2016/10/16846/)涉及特定队友规则；[player_lagcompensation.cpp](https://github.com/ValveSoftware/source-sdk-2013/blob/master/src/game/server/player_lagcompensation.cpp)提供公开实现参考。历史命中查询需要完整姿态和规则，单纯恢复一个位置不足以概括其行为。本项目没有移植 Source 的整套命中补偿。

## 当前采用

本地角色即时响应，远端显示插值，碰撞使用有明确时间的代理。已知攻击预测本地影响，未知交互由权威补齐。重放前检查本地状态和依赖，不根据另一款游戏的名称决定重放范围。实现见[本地预测](local_prediction_design.md)。
