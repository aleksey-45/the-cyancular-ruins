# 网络频率调研：各家游戏/引擎的 tick、快照下行与输入上行（一手）

## 0. 三个量

| 记号 | 量 | 含义 |
|---|---|---|
| A | 服务器模拟 tick | 服务器逻辑 / 物理多久走一步 |
| B | 快照 / 状态下行 | 服务器 → 每个客户端，多久发一次状态 |
| C | 输入上行 | 客户端 → 服务器，多久发一次输入 |

三者常不等，转述材料常把它们混用一个 "tickrate"。区分不了时写"未区分"。

## 1. 本仓

| 量 | 值 | 位置 |
|---|---|---|
| A | 60Hz | Godot 物理 tick |
| B | 30Hz | `MatchState.SNAPSHOT_HZ` |
| C | 30Hz | 采样与上行同频，`PacketInputSource.TICKS_PER_RECORD = 2` |
| tick 域 | 60Hz | 快照 `tick` 每包 +2，一个包跨 2 个物理 tick |

## 2. 逐家清单

| 游戏 / 引擎 | A 服务器 tick | B 快照下行 | C 输入上行 |
|---|---|---|---|
| Quake 3 Arena | 20 | 20（客户端请求 `snaps`） | 每帧生成，包率 ≤30，带 1 份冗余 |
| Valorant | 128 | ≈128（每个服务器帧广播） | 未区分 |
| Halo Infinite | 60（4v4）/ 30（BTB、战役 coop） | 明说发不全，未区分 | 按帧；服务器侧缓冲 0–1 帧 |
| Rocket League | 未区分 | 60 | 未取得 |
| EVE Online | ≈1 Hz（原文隐含） | 未取得 | 未取得 |
| GGPO（rollback） | — | — | 每帧交换输入（+ 可靠 UDP + 可选帧延迟） |
| CS 一族、TF2、Quake Live、Dota 2、WoW、Destiny、Overwatch、Fortnite、Apex、PUBG、Minecraft、Roblox、LoL | 未取得 | 同左 | 同左 |

## 3. 缓冲深度的两项拆分（Gaffer 口径）

| 项 | 规则 | 随发送率 |
|---|---|---|
| 丢包保护 | 3 × 发送间隔 | 等比缩放 |
| 抖动余量 | 1–2 帧 @60fps ≈ 17–33 ms | 不缩放（绝对时间） |
| 合计 | — | 10pps → 350 ms；30pps → 150 ms；60pps → 85 ms |

- 本仓只用这套配方的**下界**一档：固定 playout 4 tick（≈67ms）+ 抖动深度补偿（上限 4 tick），不做 3 × 发送间隔 那种等比丢包保护。

## 4. 边界

- 表格空格一律不填：没有数字就写"未取得"，不补猜值。
