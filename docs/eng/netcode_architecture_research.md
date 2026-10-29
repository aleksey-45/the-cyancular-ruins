# 联机基础资料

## 资料与可参考部分

| 资料 | 可参考部分 |
|---|---|
| Quake III：[cg_predict.c](https://github.com/id-Software/Quake-III-Arena/blob/master/code/cgame/cg_predict.c)、[bg_pmove.c](https://github.com/id-Software/Quake-III-Arena/blob/master/code/game/bg_pmove.c)、[sv_client.c](https://github.com/id-Software/Quake-III-Arena/blob/master/code/server/sv_client.c)、[msg.c](https://github.com/id-Software/Quake-III-Arena/blob/master/code/qcommon/msg.c) | 共享移动核心、按命令预测、服务端消费输入、快照字段差分 |
| Teeworlds：[gamecore.h](https://github.com/teeworlds/teeworlds/blob/master/src/game/gamecore.h)、[gameclient.cpp](https://github.com/teeworlds/teeworlds/blob/master/src/game/client/gameclient.cpp)、[server.cpp](https://github.com/teeworlds/teeworlds/blob/master/src/engine/server/server.cpp) | 结构化输入、共享角色核心、按 intended tick 保存和执行输入 |
| DDNet：[gamecore.cpp](https://github.com/ddnet/ddnet/blob/master/src/game/gamecore.cpp)、[预测世界](https://github.com/ddnet/ddnet/blob/master/src/game/client/prediction/gameworld.cpp)、[smooth_time.cpp](https://github.com/ddnet/ddnet/blob/master/src/engine/client/smooth_time.cpp) | 集中角色状态、显式预测世界和时间平滑；交互模型应按具体玩法选择 |
| Valve：[Source Multiplayer Networking](https://developer.valvesoftware.com/wiki/Source_Multiplayer_Networking)、[Lag Compensation](https://developer.valvesoftware.com/wiki/Lag_Compensation) | 本地预测、远端插值和服务端历史命中查询是不同机制 |
| Source SDK：[prediction.cpp](https://github.com/ValveSoftware/source-sdk-2013/blob/master/src/game/client/prediction.cpp) | `ComputeFirstCommandToExecute` 在确认和误差条件满足时复用已预测命令；复用的是状态，不是完整物理查询结果 |
| GGPO：[InputQueue](https://github.com/pond3r/ggpo/blob/master/src/lib/ggpo/input_queue.cpp)、[Sync](https://github.com/pond3r/ggpo/blob/master/src/lib/ggpo/sync.cpp) | 比较预测输入和实际输入，找最早失效点并重算后缀；其输入同步模型不等于权威 STATE 模型 |
| Backroll：[Development Guide](https://github.com/provencher/Backroll/blob/master/Documentation/DevelopmentGuide.md) | 固定步进、完整恢复数据、避免重放重复副作用；不要求放弃场景引擎 |
| Unity Netcode：[Optimizations](https://docs.unity3d.com/Packages/com.unity.netcode@1.5/manual/optimizations.html)、[Prediction Details](https://docs.unity.cn/Packages/com.unity.netcode@1.5/manual/prediction-details.html) | 有效预测备份复用、结构变化的恢复风险、部分回退时的交互时间线 |
| GNS v1.6.1：[API 头文件](https://github.com/ValveSoftware/GameNetworkingSockets/blob/v1.6.1/include/steam/isteamnetworkingsockets.h) | lane 的可靠、有序范围与连接发送/接收语义；跨 lane 不保证顺序 |
| Riot：[VALORANT Netcode](https://www.riotgames.com/en/news/peeking-valorants-netcode) | 输入到达余量、缓冲与模拟差异需要分别处理，不能将本地积压等同于网络延迟 |
| PhysX：[CCT Geometry Cache](https://nvidia-omniverse.github.io/PhysX/physx/5.4.1/docs/CharacterControllers.html#invalidating-internal-geometry-caches) | 缓存附近几何候选，运动仍计算接触；与完整查询结果缓存不同 |
| Maddy Thorson：[Celeste and TowerFall Physics](https://www.maddymakesgames.com/articles/celeste_and_towerfall_physics/index.html) | 用清楚的轴向移动、碰撞与推动规则表达平台角色运动 |

### 补充资料

| 资料 | 可参考部分 |
|---|---|
| Valve，Yahn Bernier，2001：[Latency Compensating Methods](https://www.gamedevs.org/uploads/latency-compensation-in-client-server-protocols.pdf) | 本地移动/武器预测、远端插值与服务器历史命中查询分工；文中的 100 ms 是显示方案实例，不是碰撞代理的通用数值 |
| Glenn Fiedler：[Networked Physics](https://gafferongames.com/post/networked_physics_2004/)、[State Synchronization](https://gafferongames.com/post/state_synchronization/)、[Snapshot Interpolation](https://gafferongames.com/post/snapshot_interpolation/)、[Snapshot Compression](https://gafferongames.com/post/snapshot_compression/) | 完整外推状态、量化一致性、显示误差衰减、碰撞响应和字段压缩；平滑不能修复模拟规则分歧 |
| Riot：[Gameplay Consistency Update 2](https://playvalorant.com/en-us/news/game-updates/valorant-gameplay-consistency-update-2/)、DDNet：[client.cpp](https://github.com/ddnet/ddnet/blob/master/src/engine/client/client.cpp) | 低帧率、切出窗口、缓冲恢复和输入余量反馈；RTT 不能描述全部处理延迟 |
| Photon：[Physics Forecast](https://doc.photonengine.com/fusion/v2/manual/physics/physics-forecast)、Godot：[Physics Interpolation](https://docs.godotengine.org/en/4.7/tutorials/physics/interpolation/physics_interpolation_introduction.html) | 外推目标仍需物理约束，显示插值与固定物理 tick 分开 |
| GNS：[状态与配置定义](https://github.com/ValveSoftware/GameNetworkingSockets/blob/v1.6.1/include/steam/steamnetworkingtypes.h)、[带宽估计讨论 #108](https://github.com/ValveSoftware/GameNetworkingSockets/issues/108) | 读取发送排队与连接状态时按具体版本解释；不能只看 RTT 决定消息是否仍新鲜 |

## 当前采用

共享原生角色核、显式 epoch/序号/目标 tick、持续输入冗余、动作独立 ACK 与过期、平滑输入时钟；实时状态以新替旧，可靠事件有界排队。应用层依据 tick、版本与权威覆盖处理跨 lane 迟到。

STATE 先比较同 tick 状态、有效命令和实际依赖；保留有效前缀并合批重放。远端显示插值和碰撞代理独立。地形使用局部几何失效及有界查询缓存，没有实现 PhysX 的候选收集算法。协议和窗口见[联机系统](netplay.md)，复用见[预测历史](prediction_reuse.md)。
