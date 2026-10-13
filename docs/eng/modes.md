# 对战模式与结算

房间由 [RoomSession](../../server/room_session.gd) 管理，所有模式共享 [AuthorityWorld](../../server/authority_world.gd)、[MatchRules](../../server/match_rules.gd) 和 [PvpMatchClient](../../scenes/pvp_match_client.gd)。不存在模式专属服务端继承链或同步客户端。

| 模式 | 开局 | 单局 / 整场胜负 | 复活 |
|---|---|---|---|
| 1v1 | 两人加入自动开始 | 先到 5 杀赢一局，两局获胜 | 阵亡者 2 秒后；存活对手重置到出生点 |
| 3v3 | 两队各三人，房主开始 | 队伍先到 9 杀赢一局，两局获胜 | 2 秒后选择远离存活敌人的地面点 |
| 大乱斗 | 2–8 人，房主可添加 AI | 默认 300 秒，击杀最多获胜；并列为平局 | 2 秒后选择安全点 |

回合先倒计时 3 秒，单局结束停留 4 秒，随后交换双方出生点、恢复地图并重新下发基线。大乱斗时长由房间选项指定。武器、弹药、地形、统计和胜负均由服务端裁决。

队伍 1 使用碰撞层 2，队伍 2 使用层 16；双方掩码包含地形和敌方角色层，队友互相穿行。远端碰撞代理与服务端采用相同分层。普通弹丸与激光穿过队友，爆炸保留对友军和自身的范围伤害。

[AI 控制器](../../server/ai/ai_navigator.gd)向 AiInputSource 写入输入，由相同 ActorStep 执行。Beta 采用服务端自身回溯与加速，所有模式共用同步和表现，详见 [联机说明](netplay.md)。

受害者倒地前归因窗口内的同队伤害参与者计助攻。评分由 [ScoreRules](../../core/sim/score_rules.gd) 统一计算：

```text
penalty = (team_damage + self_damage) / 5 + team_kills * 100
kscore = kills * 100 + assists * 50 + dealt / 5 - deaths * 50 - penalty
acs = kscore / rounds
```

[结果数据适配器](../../ui/screens/match_result_payload.gd)将统一回合统计转换为 [结果面板](../../ui/screens/match_result.gd) 的模式展示。在线玩家确认返回后，服务端释放权威世界，在同一连接上发送原房间状态，保留房间码、席位和 token。房主退出或宽限到期则关闭房间，不进行房主迁移。
