# 网络频率调研：各家游戏/引擎的 tick、快照下行与输入上行（一手）

> **与同目录三份的分工**：本文**只普查"各家频率是多少"**并把**三个量分开**；**不重复**
> [`netcode-playout-clock-sync-sources.md`](netcode-playout-clock-sync-sources.md)（播放时钟该跟什么）、
> [`netcode-jitter-buffer-practice.md`](netcode-jitter-buffer-practice.md)（深度/速率怎么定）、
> [`netcode-snapshots.md`](netcode-snapshots.md) §3（本仓与主流总对照）。§3 只补答"抖动按毫秒还是按间隔倍数"。
> **纪律**：只引一手（官方博客/文档/公告/源码），二手只当线索并**明说**；每条标 **读了全文** / **只片段**；
> 取不到的逐个列原因（§4）。**真相源排序**：源码 > 探针实测 > 本文档 > 其它。

## 0. 三个量（每一格都要回答它属于哪个）

| 记号 | 量 | 含义 |
|---|---|---|
| **A** | 服务器模拟 tick | 服务器内部逻辑/物理多久走一步 |
| **B** | 快照/状态下行 | 服务器 → 每个客户端，多久发一次状态 |
| **C** | 输入上行 | 客户端 → 服务器，多久发一次输入 |

**为什么先立这表**：三者常**不等**，而二手转述一律叫 "tickrate"。最干净的一手反例在 Quake 3 源码里：
**A=20、B=20、C 的包率上限=30**（§2.1）。来源没说清是哪个量的，本文写 **"来源未区分"**。

## 1. 结论（先说）

1. **取到一手的只有少数几家**：Valorant（Riot 官方博客，A=128）、Halo Infinite（343 官方博客，A=60/30）、
   Rocket League（Psyonix 开发者发言，B=60）、EVE Online（CCP 官方博客，A 基准≈1 Hz）、Quake 3（源码，A=20/B=20/C≤30）。
2. ★ **CS 一族与 BR 一族（Fortnite/Apex/PUBG）本次一个数字都没取到一手**：Valve wiki 被 Anubis 拦、CS2 官方页是 JS 空壳；
   Epic/Respawn/PUBG 官方渠道没有可读的频率正文。这些格子写**未找到一手来源**。
3. **"tickrate" 被混用的活样本**：玩家帖把 tickrate 定义成"服务器每秒发多少次更新"，Riot 员工照这个词回答、
   **既没肯定也没否定 30** ⇒ **LoL 的 30 无 Riot 一手确认**（§2.6）。
4. **rollback 格斗的输入是"每帧交换 + 可靠 UDP + 可选帧延迟"**（GGPO 官方 README 读全文，§2.7）。
5. **§3 那一问的答案**：抖动要**同时**按绝对毫秒与"占间隔的比例"看 —— Gaffer 一手原句把缓冲拆成**两项**：
   丢包保护 = **3× 发送间隔**（等比缩放），抖动余量 = **1–2 帧 @60fps**（≈17–33 ms **绝对**时间，**不**缩放）。

## 2. 逐家清单

| 游戏/引擎 | **A** 服务器 tick | **B** 快照下行 | **C** 输入上行 | 一手来源 | 读全文? |
|---|---|---|---|---|---|
| Quake 3 Arena | **20** | **20**（客户端请求 `snaps`） | usercmd **每帧**生成，**包**率 ≤**30**，带 1 份冗余 | id 源码（GPL） | ✅ 源码 |
| Valorant | **128** | ≈128（"1 frame … broadcast out to clients"） | 未区分 | Riot 技术博客 ×2 | ✅ |
| Halo Infinite | **60**（4v4）/ **30**（BTB、战役 coop） | 未区分（明说**发不全**） | 按帧；服务器侧缓冲 **0–1 帧** | 343 官方博客 | ✅ |
| Rocket League | 未区分 | **60**（"creates network packets 60 times a second"） | 未找到 | Psyonix 开发者发言 | ⚠️ §2.4 |
| EVE Online | **≈1**（原文隐含） | 未找到 | 未找到 | CCP 官方 TiDi 博客 | ✅ |
| GGPO（rollback） | — | — | **每帧交换输入**（+可靠 UDP +可选帧延迟） | GGPO 官方 README | ✅ |
| CS 1.6 / CS:GO / CS2、TF2、Quake Live、Dota 2、WoW、Destiny、Overwatch、Fortnite、Apex、PUBG、Minecraft、Roblox、LoL | **未找到一手** | 同左 | 同左 | — | — |

### 2.1 Quake 3 Arena —— 三项在同一份源码里（**读全文**）

来源：[id-Software/Quake-III-Arena](https://github.com/id-Software/Quake-III-Arena)（经 jsDelivr 取原文；`raw.githubusercontent.com` 本机不可达，§4）。

- **A=20**：`sv_init.c` → `sv_fps = Cvar_Get ("sv_fps", "20", CVAR_TEMP );`；`sv_main.c` 的 `SV_Frame()` 用 `frameMsec = 1000 / sv_fps->integer;`
  定步长，不足则 `NET_Sleep(...)`。**为什么 A 与 B 同源**：`SV_SendClientMessages()` 就在同一个 `SV_Frame` 末尾 —— 服务器帧既驱动模拟也驱动发包。
- **B=20（默认）**：`cl_main.c` → `Cvar_Get ("snaps", "20", CVAR_USERINFO | CVAR_ARCHIVE )` ⇒ 客户端**请求** 20 快照/s。
  ★ 与 A 同值但**是两个量**，改一个不改另一个。
- **C**：`cl_input.c` `CL_CreateNewCommands()` 每**客户端帧**生成一个 usercmd（注释 "generate a command for this frame"）；
  发包由 `CL_ReadyToSendPacket()` 限流，`cl_maxpackets` 默认 **30**、夹在 **[15,125]**。`CL_WritePacket()` 注释：
  *"we want to send all the usercmds that were generated in the last few packet, so even if a couple packets are dropped in a row,
  all the cmds will make it to the server"*（+ `cl_packetdup` 默认 1）⇒ **每帧生成、多帧打成一包**，`cl_maxpackets` 才是 C 的包率上限。
- 另：`CL_AdjustTimeDelta()`（`cl_cgame.c`）注释 *"Our ideal time would be to have the adjusted time approach, but not pass, the very
  latest snapshot."*（`RESET_TIME 500`，>100 ms 折半，否则每快照只挪 ±1/2 ms）—— 与"追最新"相反。
- **Quake Live**：`sv_fps` 官方默认值**未找到一手来源**。

### 2.2 Valorant —— Riot 官方技术博客（**两篇读全文**）

[《Peeking into VALORANT's Netcode》](https://www.riotgames.com/en/news/peeking-valorants-netcode) · [《VALORANT's 128-Tick Servers》](https://www.riotgames.com/en/news/valorants-128-tick-servers)

- **A=128**：*"we determined that VALORANT would require 128-tick servers"*、*"process an entire frame within 7.8125ms"*（预算 2.34 ms/帧）。
- **客户端也是 128**：*"clients and servers always update movement, physics, and other related systems with a fixed timestep: exactly 128
  times per second"* ⇒ 渲染帧率与模拟 tick **解耦**（与本仓"渲染=tick"型设计的分野）。
- **B≈128**：缓冲被拆成三项 —— *"0.5 frames - the average time that incoming data must wait… / 0.5 frames - the server target for actual
  network buffering… / 1 frame - a full frame where the move is applied and output (**broadcast out to clients**)"* ⇒ 每个服务器帧都对外广播。
- **C：来源未区分**。只说 *"Each client sends its input and movement results to the server"*、缓冲以 tick 为粒度；**包率没给数**。
- 附带一手公式化表述：*"The duration of buffering is directly dependent on simulation tick rate"*（= §3 的"按帧计"）。

### 2.3 Halo Infinite —— 343 官方博客（**读全文**）

[Halo Waypoint《Closer Look: Halo Infinite's Online Experience》](https://www.halowaypoint.com/en-us/news/closer-look-halo-infinite-online-experience)（作者 Richard Watson, Lead Engineer）

- **A**：FAQ 原句 *"Our 4v4 matches run at a 60hz tick rate, and Big Team Battle games run at 30hz. In the future, online campaign coop will
  run at a 30hz tick rate as well."*
- **B：来源未区分，且明说发不全**：*"Even in a 4v4 arena match there is too much data to send the entire state of the game world every server
  tick, so we only send the information we deem most relevant to the player"* ⇒ 不能由 A 推 B。
- **C**：延迟公式 *"Shooter's Latency to Server + Shooter's Command Buffer + Server Processing Time (**16 - 33ms depending on tick rate**)
  + Target's Latency from Server"*；缓冲 *"For a good connection, this should be either 0 or 1 frame of buffering (so an extra 16ms worst case)"*。
- 顺带一手推论：**"Server Processing Time" = 1/A** ⇒ 可以把"tick → 最坏排队延迟"当 `1/A` 用。

### 2.4 Rocket League —— Psyonix 开发者发言（**二手载体、一手发言人**）

[devtrackers.gg 镜像的 /u/Psyonix_Cone 发言](https://devtrackers.gg/rocket-league/p/b39843cb-psyonix-pls)（原帖在 Reddit；镜像**读全文**）

- 原句 *"The server creates network packets **60 times a second**, but not every replicated actor will have a chance to write to every
  outgoing packet."* ⇒ **B=60**。同一段还确认**有损量化**（位置取整、旋转吸附固定角度），与 [`netcode-snapshots.md`](netcode-snapshots.md) §3 编码行同族。
- ★ **照实说**：这是**开发者本人在 Reddit 的发言**（载体是镜像站），不是官方文档 ⇒ 数值可信度低于 §2.2/§2.3。**A 未区分**。

### 2.5 EVE Online —— CCP 官方博客（**读全文**）

[CCP《Introducing Time Dilation (TiDi)》(2011-04-22)](https://www.eveonline.com/news/view/introducing-time-dilation-tidi)

- **A≈1 Hz（隐含）**：*"have **Destiny, our physics simulation, update at a lower resolution than once per second** as we get overloaded"*
  ⇒ 正常基准是**每秒一次**；同文提到模块 tasklet *"yields after 100 milliseconds of execution"*。
- **为什么值得记**：它是**另一种过载杠杆** —— **把游戏时钟按比例放慢（5%–60% realtime）**，而不是加深缓冲；
  与 [`netcode-playout-clock-sync-sources.md`](netcode-playout-clock-sync-sources.md) §6 第 5 条"主动调速"同思路，且这里**有一手出处**。

### 2.6 其余各家（逐个说"查了什么、为什么没有"）

- **CS 一族**：CS2 官方页 <https://www.counter-strike.net/cs2> 实测 **HTTP 200 但正文只有标题**（JS 空壳）；
  `blog.counter-strike.net` 更新分类页 **404**；Steam 官方新闻 API/RSS `fetch failed` ⇒ **sub-tick 官方原文取不到**。
  `cl_updaterate`/`sv_maxupdaterate`/`cl_interp = cl_interp_ratio / cl_updaterate` 全在 `developer.valvesoftware.com`（**Anubis 1.23.1** 拦截，
  本次实测返回 "Making sure you're not a bot!"）⇒ **A/B/C 官方默认值无一手**。CS 1.6 tick、TF2 的 66 亦**未核实**。
  ★ 这一族正是我们要对照的概念所在，但**这一轮取不到**；要引请改引 §2.1（源码）与 §2.2（Riot）。
- **LoL 的 30**：只有**玩家原帖**说 "league runs at a 30hz tick rate" + [Riot 员工 /u/RiotRayYonggi 的回复](https://devtrackers.gg/leagueoflegends/p/4575c06c-will-we-ever-see-tick-rates-increased-to-60hz)（镜像，**读全文**）。
  原句 *"players are being limited by their ping and not the server's tickrate"*、*"Lower tickrate means more time for the server to
  resolve 'conflicts' … and gives the server time to optimize the packets/information it sends to clients rather than send at 2x the
  frequency without consolidation"* ⇒ **员工没给数**；而"tickrate = 每秒发更新"的**混用定义**恰在玩家帖里。⇒ **30 无一手确认**。
- **Overwatch**：GDC 2017 正文在 **GDC Vault 付费墙**（[本目录文档](netcode-playout-clock-sync-sources.md) §3.3 已核，本次未重试）；
  Blizzard 官方新闻里搜到的 [Defense Matrix](https://overwatch.blizzard.com/en-us/news/23857517/)（**读全文**）通篇讲反作弊，**零 tick 数字**
  ⇒ **无一手**。"命令帧"属 **A 类候选**，只能二手。
- **Fortnite / Apex / PUBG**：官方渠道（Epic 官方新闻与社区帖、EA/Respawn 官方博客、PUBG 官方 Steam 公告）本次**没有翻出给频率的正文**
  （Steam 新闻页是 JS 列表、API 取不到）⇒ **一律未核实，不填数字**。
- **WoW / Destiny / Minecraft / Dota 2**：WoW 的 spell batching 只有**论坛玩家帖**与二手（Wowhead），官方 patch notes 正文未取到；
  Bungie 官方论坛是 **JS 空壳**（"JavaScript is required to use Bungie"）⇒ 两者**无一手**；
  Minecraft 的 20 TPS 只有**社区 wiki** ⇒ **二手，未核实**；Dota 2 的官方 cvar 文档同在 Valve wiki（Anubis）⇒ **无一手**。
- **Roblox**：官方仓库文档 [`creator-docs` `physics/network-ownership.md`](https://github.com/Roblox/creator-docs)（经 jsDelivr，**读全文**）
  只讲**分布式物理与网络所有权**（谁模拟、谁能作弊），**没有任何复制频率数字**，只有 "wait several **network cycles**" 这类定性说法 ⇒ **无一手数字**。

### 2.7 GGPO / rollback 格斗 —— 官方 README（**读全文**）

[pond3r/ggpo `doc/README.md`](https://github.com/pond3r/ggpo)（经 jsDelivr 取原文）

- **输入是"每帧"的量**：*"exchange inputs for all players over the network, only executing a frame of gameplay logic when all players have
  received all the inputs from their peers"*；图表按 "Each frame is separated by a horizontal, dashed line" 组织。
- **打包/可靠性在 UDP 层**：*"The UDP protocol object … also implements the **game input compression and reliable-UDP layer**"*；
  InputQueue *"also implements the **frame-delay** if requested"*。
- ★ **照实说**：README **没有**"每帧发一个包"这句，也**没有**任何频率数字 ⇒ 能说的只有
  "**输入以帧为粒度交换、可压缩、可靠、可加人工延迟**"。它与"快照插值"是**两套不同的上行/下行结构**。

## 3. 专答：快照发送频率 ↔ 可容忍抖动（按毫秒还是按间隔倍数）

### 3.1 Gaffer 原文（[Snapshot Interpolation](https://www.gafferongames.com/post/snapshot_interpolation/)，**读全文**）

> *"My rule of thumb is that the interpolation buffer should have enough delay so that I can lose two packets in a row and still have
> something to interpolate towards. Experimentally I've found that the amount of delay that works best at 2-5% packet loss is **3X the
> packet send rate**. At 10 packets per-second this is 300ms. I also need some extra delay to handle jitter, which in my experience is
> typically only **one or two frames @ 60fps**, so the interpolation videos above were recorded with a delay of 350ms."*

> *"If we send 30 snapshots per-second we can get the same amount of packet loss protection with a delay of 150ms. 60 packets per-second
> needs only 85ms."*

### 3.2 拆成两项（**本文最有用的一条**）

| 项 | 规则 | 随发送率怎么变 | 校验 |
|---|---|---|---|
| **丢包保护** | **3 × 发送间隔** | ★ **等比缩放**（"间隔的倍数"） | 10pps→300、30pps→100、60pps→50 |
| **抖动余量** | **1–2 帧 @60fps** | ★ **不缩放**（≈17–33 ms **绝对时间**） | 三档加同一量级 |
| 合计（原文给的） | — | — | 10pps→**350**、30pps→**150**、60pps→**85** |

⇒ **Gaffer 的口径本来就是"两项"**：一项按倍数、一项按毫秒 —— 只问"按毫秒还是按倍数"会把一手来源读窄。
**他的换算只有在把抖动当绝对量时才自洽**（60pps 时 3×=50，加 ~33 ms 才凑到 85；若抖动也按倍数缩放，三档对不上）。

### 3.3 对我们实测的判断（60 Hz、±16 ms 均匀抖动被吃穿）

- ±16 ms 均匀抖动 ⇒ **峰峰 32 ms**；60 Hz 间隔 16.7 ms ⇒ **抖动 ≈ 1.9 个发送间隔**，即使按 Gaffer 的"抖动只占 1–2 帧"也**正压上沿**。
- ⇒ **判断：主要就是"抖动占间隔的比例太大"**（≈1–2 个间隔）。换成 20 Hz（间隔 50 ms），同样 ±16 ms 只占 **0.64 个间隔**，
  一个间隔的缓冲就吃得下 —— **绝对毫秒没变、比例变了**。这与本仓实测（[`netcode-jitter-buffer-practice.md`](netcode-jitter-buffer-practice.md) §9：
  加深只是线性抬滞后、治不了超出量）一致：**"必须吸收的抖动 / 间隔"这个比值才决定有没有余量**。
- ★ **不给一手加戏**：**没有**一手来源写"插值缓冲要 **N 个快照间隔**"这句话本身 —— Gaffer 的 **3×** 是**丢包**项、抖动项是**绝对**的。
  形式上最接近"N 个间隔"的是 Source 系 `cl_interp = cl_interp_ratio / cl_updaterate`（**比值**参数），但 Valve wiki 被 Anubis 拦，
  本次**取不到一手** ⇒ 该式**只能当二手线索**。
- 可用的替代一手：Riot 明写缓冲深度**以帧计且"直接取决于 tick rate"**（§2.2）、Halo 明写命令缓冲 **0–1 帧**（§2.3）
  ⇒ "缓冲深度写成帧/间隔数"**有一手支持**；把**抖动也写成间隔数**则**没有**原句。

## 4. 取不到的 URL（逐个原因）

| URL | 结果 |
|---|---|
| `developer.valvesoftware.com/wiki/Source_Multiplayer_Networking` | **Anubis 1.23.1 反爬**（返回挑战页，非正文） |
| <https://www.counter-strike.net/cs2> | HTTP 200，正文**只有标题**（JS 空壳） |
| `blog.counter-strike.net/index.php/2023/03/40496/` | **302 到 2013 年一篇匈牙利语无关帖** |
| `blog.counter-strike.net/index.php/category/updates/` | **HTTP 404** |
| `api.steampowered.com/ISteamNews/GetNewsForApp/v2/…`、`store.steampowered.com/feeds/news/app/730/…`、`steamcommunity.com/games/730/rss/` | 本机 **`fetch failed`**（想用官方渠道拿公告正文） |
| `raw.githubusercontent.com/...`（id-Software / pond3r / Roblox 各处） | 本机 **`fetch failed`** ⇒ 全部改用 **jsDelivr** 取上游原文（成功） |
| `technology.riotgames.com/news/peeking-valorants-netcode` | **跨域重定向**到 `riotgames.com`，抓取器拒收 ⇒ 改抓 `riotgames.com` 版（成功） |
| GDC Vault `…/1024001/…`（Overwatch）、`…/1027657/…`（One Frame in Halo Infinite） | **付费墙**；后者只在搜索片段里拿到一行 "16.67 ms" ⇒ 不引 |
| Bungie 官方论坛与 news | 论坛 **JS 空壳**（"JavaScript is required to use Bungie"） |
| 官方 PUBG / Epic / EA 给频率的正文 | 只落到 **JS 列表页** ⇒ 未取到正文 |

## 5. 来源清单与边界

**读了全文**：Quake 3 源码（`sv_init.c`/`sv_main.c`/`cl_main.c`/`cl_input.c`/`cl_cgame.c`）·
Riot [Peeking](https://www.riotgames.com/en/news/peeking-valorants-netcode) 与 [128-Tick](https://www.riotgames.com/en/news/valorants-128-tick-servers) ·
343 [Closer Look](https://www.halowaypoint.com/en-us/news/closer-look-halo-infinite-online-experience) ·
CCP [TiDi](https://www.eveonline.com/news/view/introducing-time-dilation-tidi) ·
Blizzard [Defense Matrix](https://overwatch.blizzard.com/en-us/news/23857517/)（**用于排除**，与频率无关）·
GGPO `doc/README.md` · Gaffer [Snapshot Interpolation](https://www.gafferongames.com/post/snapshot_interpolation/) ·
Roblox `creator-docs`。

**二手载体、说话人一手**：Rocket League（Psyonix 开发者）· LoL（Riot 员工，**未给 30**）。
**只拿到片段**：GDC 2025 论文、Halo GDC "One Frame…"。

**边界（照实）**
1. **"未找到一手" ≠ "没有官方数字"**：只说明**本机在这些入口取不到**（Valve 侧主因是 Anubis；Epic/EA/PUBG/Bungie 侧是 JS 空壳与 API 不可达）。
2. **表格空格一律不填**：任何"看起来合理"的补值都是记忆，不是来源。
3. §3 的比例判断是**Gaffer 两项拆分 + 本仓实测**的推论，**不是**任何来源的原句 ⇒ 与本目录
   [`netcode-jitter-buffer-practice.md`](netcode-jitter-buffer-practice.md) §9/§10 的实测一起读，别单独拿它当权威。
