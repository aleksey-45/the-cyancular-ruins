# Minecraft 的移动与世界交互资料

## 资料与可参考部分

| 资料 | 可参考部分及边界 |
|---|---|
| Mojang Bedrock：[Player Movement Overview](https://github.com/Mojang/bedrock-protocol-docs/blob/main/additional_docs/PlayerMovementOverview.md)、[Correct Player Move Prediction](https://mojang.github.io/bedrock-protocol-docs/latest/packets/correct-player-move-prediction-packet/) | 输入、预测移动与服务器校正，移动有自己的历史和确认语义 |
| Mojang：[Block Breaking Overview](https://github.com/Mojang/bedrock-protocol-docs/blob/main/additional_docs/BlockBreakingOverview.md)、[Build Action Simulation Rate](https://mojang.github.io/bedrock-protocol-docs/guides/build-action-simulation-rate/) | 方块操作的输入序号与权威结果，世界改变和移动同步分别组织 |
| Mojang：[Set Actor Motion](https://mojang.github.io/bedrock-protocol-docs/latest/packets/set-actor-motion-packet/)、[Server Properties](https://learn.microsoft.com/en-us/minecraft/creator/documents/bedrockserver/server-properties?view=minecraft-bedrock-stable) | 实体运动和服务端策略；协议字段不证明整个客户端内部回滚实现 |
| Mojang：[Movement Protocol Deprecation](https://mojang.github.io/bedrock-protocol-docs/guides/movement-protocol-deprecation/)、[1.21.70 发布说明](https://feedback.minecraft.net/hc/en-us/articles/35256043330189-Minecraft-Bedrock-Edition-1-21-70-Spring-to-Life) | 移动协议会演进，阅读时必须区分版本和模式 |
| Java 26.1：[官方版本元数据](https://piston-meta.mojang.com/v1/packages/b85db8efa37dc2e9d5cb12ee324a42d22fd98c08/26.1.json)、[官方 client.jar](https://piston-data.mojang.com/v1/objects/191771837687b766537a8c4607cb6fad79c533a1/client.jar) | 对该版本字节码的阅读显示方块预测确认和本地玩家调整分别处理；仅适用于所读版本 |

## 可参考的判断

复杂地形、实体和角色交互可以按领域划分协议、预测和确认，不必据此推导全世界客户端回滚。移动恢复仍须考虑实际碰撞世界，方块预测也需要权威确认和错误恢复。Java 与 Bedrock 的设计不能混作一套。

## 当前采用

地形有独立的权威版本、局部补丁和预测历史，移动使用共享模拟及对应 tick 的地形。可靠地形与不可靠 STATE 按版本衔接，恢复只改实际不同的部分。领域划分借鉴此思路，数据结构与算法按本项目的 16px 可破坏地形设计。见[原生地形](native_terrain.md)。
