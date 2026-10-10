# playout 时钟的目标该是什么：一手来源调研

> **这份文档是什么**：只回答一个问题 —— 客户端的**播放时钟**该拿什么当目标？我们把目标设成了
> `latest`（**最新已收到**的快照 tick），于是时钟在追一个**锯齿**。这里把相关一手来源读完、落纸。
> **怎么用**：动 `PlayoutClock` 控制律之前读本文件；现状与实测在 [`netcode-snapshots.md`](netcode-snapshots.md) §5.3，本文件**不重复**它 §3 的「主流对照」。
> **纪律**：只引一手；每条标**读了全文** / **只拿到摘要**；来源与本问题是「支持 / 无关 / 相反」都明说；取不到的逐个列在 §7。**真相源排序**：源码 > 探针实测 > 本文档 > 其它。

---

## 1. 结论（先说）

1. **没有任何一手来源主张「时钟目标 = 最新收到的样本」。** NTP `clock_filter()` = **8 级移位寄存器里挑 delay 最小的一格**（再按 `1/2^i` 加权，
   RFC 5905 §10）；RTP 把到达偏差压成**一阶平滑估计 J**（RFC 3550 §6.4.1 + 附录 A.8）；Valve 的插值目标时间是 `客户端时间 − 插值延迟`，
   **与"最后一个包什么时候到"无关**。
2. **但"按到达速率估计"这个说法，本调研没有在一手来源里找到对应原句。** 找到的是三类：① 从整窗样本里**挑最小值**（NTP §10）；
   ② **一阶平滑**（RTP A.8）；③ 按 talkspurt 的**"尖峰"**自适应加保护（Ramjee 1994，**只摘要**）。三类都是**估一个鲁棒统计量**，
   都不是"追最新"；**不要**把 ③ 说成"按速率估计"——摘要没这么说。
3. **术语**：这病的准确名字**不是** clock wander / phase noise —— NTP 把扰动分成 **network jitter**（PLL 更合适）与
   **oscillator wander**（FLL 更合适）（RFC 5905 §11.3），而 `clock wander` 指**振荡器**漂移，与我们的病不是一回事。
4. **最深的一条（推论，非来源原话）**：`mean = playout − 0.93`、而 ±16ms 的**超出量**（≈5.8 tick）与 playout 无关 —— 这与"一个约 1 tick 幅度、
   被抖动打宽的**参考步进**"一致：均值由**步进幅度**定，尾部由**步进边沿 + 抖动**定，**都不由缓冲深度定** ⇒ 加深缓冲治不了它（本仓实测已证）。
5. 下一步最该改的 5 条见 §6，其中**来源之间的真矛盾**（PLL vs FLL 适用条件）也写在 §6，不调和。

---

## 2. Ramjee 等 1994（adaptive playout 的经典）

- 出处（标题/作者/年份/会议/页码已核实）：**R. Ramjee, J. Kurose, D. Towsley, H. Schulzrinne, "Adaptive playout mechanisms for
  packetized audio applications in wide-area networks", INFOCOM '94, pp. 680–688 vol.2, 12–16 June 1994,
  DOI 10.1109/INFCOM.1994.337672**（[IEEE Xplore 记录](https://ieeexplore.ieee.org/document/337672)，**只拿到摘要与元数据**）。
- 摘要原句：比较四种**自适应调整 playout 延迟**的算法；结论是"**explicitly adjusts to the sharp, spike-like increases in
  packet delay** which were observed in the traces"的算法，在**同样的平均 playout 延迟**或**同样的最大缓冲**下丢包率更低。
- ⇒ 关系：**支持**"深度要跟观测到的抖动特性走"，且**引入"尖峰"概念**（瞬态大幅上跳要单独处理，不是靠"追最新"吸收）。
- ★ **照实说**：**正文未读**（IEEE 付费墙，`openAccessFlag: F`）⇒ **不**引它正文的算法步骤（talkspurt 首包估计、spike 阈值都不引）；
  它的"按尖峰自适应"是不是"按速率估计"，**只读摘要无法证实**。**无关**的一面：它讲**音频 playout 延迟**，不涉及"渲染时钟 vs 服务器 tick"
  这种**两时钟映射** ⇒ 能支持"别追最新"，但给不出我们的时钟控制律。

## 3. 游戏 netcode：Gaffer / Valve / Overwatch

### 3.1 Gaffer —— **没有**专门讲"估计服务器时钟/速率"的文章（已核实）

- 核实方式：[文章总索引](https://www.gafferongames.com/)（**读了全文**，含全部 30 篇标题）里**不存在**时钟/时间同步主题的文章；
  `/post/clock_synchronization_in_games/` 实测 **HTTP 404**。⇒ "Gaffer 有专文讲 clock sync"**不成立**。
- 相关两篇（都**读了全文**）：[Snapshot Interpolation](https://www.gafferongames.com/post/snapshot_interpolation/) 明确承认"**有些帧收到两个包、
  有些帧一个都收不到**"（与我们 ±16ms 实测的 20.8%/24.5% 是同一现象），解法是**缓冲**而非追最新，**深度建议 = 发送间隔的 3 倍**
  （理由：能连丢两个包还有东西可插值）＋"抖动通常一两帧" ⇒ 10pps 下 **350ms**，并给出 30pps→150ms、60pps→**85ms** 的换算；
  [State Synchronization](https://www.gafferongames.com/post/state_synchronization/) 给抖动缓冲 **4–5 帧 @60Hz**，目的是让包**按序、均匀**吐出。
  ★ 这是**接收侧排包**缓冲、**不是**渲染插值缓冲，两篇的深度**不可混用**。
- ⇒ 关系：**支持**"抖动是常态、深度按容忍度选"；**不支持**"时钟目标设最新"。**但**两篇都**没有**讲"客户端时钟怎么跟服务器时钟"
  （例子用序号/帧号推进，不讨论时钟漂移估计）⇒ **本问题第 2 问的前半是 Gaffer 的缺口**，不是我们的疏漏。

### 3.2 Valve《Source Multiplayer Networking》（Yahn W. Bernier, 2003）

- **一手性说明**：原文在 `developer.valvesoftware.com`，现被 **Anubis** 拦截（返回 Proof-of-Work 页，**非正文**）。
  我用的可读全文是[中译全文](https://www.cnblogs.com/sun-shadow/p/19715823)（**读了全文**）⇒ ★ **引的是原文语义，载体是二手译本**。
- 原文**明确**说了三件与本问题直接相关的事：① 插值目标时间 = `当前客户端时间 − 插值时间差`，在**位置历史**里**前后夹逼**；
  ② **"简单的『向最新目标移动』的插值方案在包间隔不固定时表现更差"**（英译 "The simple move to latest goal interpolation schemes
  don't behave as well … under these conditions"）—— **这正是我们的旧实现**；③ 默认 **20 更新/s、插值 100ms**；
  **丢包就把插值时间提到 200ms**，代价是延迟。
- ⇒ 关系：**支持**（②几乎是点名批评"追最新目标"）。★ **与我们的具体病无关**：它讲的是**空间上的目标选择**，
  **没有**讲"播放时钟该跟什么"（原文假定时间是 `客户端时间 − 常数`）。

### 3.3 Overwatch（Timothy Ford, GDC 2017, "Overwatch Gameplay Architecture and Netcode"）

- **一手性说明**：GDC Vault **付费墙**，只拿到标题/简介/讲者（[页面](https://gdcvault.com/play/1024001/Overwatch-Gameplay-Architecture-and)）；
  可读的是[腾讯 GAD 实录的转载中译](https://www.sohu.com/a/148848770_466876)（**读了全文**，但转了三道）⇒ **只当线索级证据**。
- 相关说法（**转述，非一手**）：① 模拟频率固定，**把计算机时钟换算成固定命令帧序号**（16ms/帧，电竞 7ms）；② 客户端常态**领先**
  服务器約「半个 RTT + 一帧」⇒ 领先量是**算出来的常数**，不是追出来的；③ **time dilation**：丢包时客户端**故意把帧率调快**
  （16ms→15.2ms）以**让服务器侧输入缓冲变大**，恢复后反向调回。
- ⇒ 关系：**支持**（②说明主流把"早多少"当**参数**）；③ 提示**速率可以被有界地主动调**，比"追样本"高一个层次。**但**它是转述，**不能**钉数值。

## 4. 通用时钟同步：NTP 与 RTP

### 4.1 RFC 5905（NTPv4）——可直接照搬的是 `clock_filter()`

[全文](https://www.rfc-editor.org/rfc/rfc5905.txt)（**读了全文**，重点 §4、§8–§11.3、附录 A.5.2）。

- **§10 Clock Filter Algorithm**：样本元组 `(theta, delta, epsilon, t)` 进 **8 级移位寄存器**；**按 `delta` 升序排序**，取**最小 delay 那一格**输出；
  dispersion 按 `epsilon_i / 2^i` 加权（越老权重越低）；jitter `psi` = 各样本对最小 delay 样本的 **RMS**。⇒ **"从一窗样本里挑最小延迟样本"** 正是
  "别追瞬时到达"的规范做法，只花一窗时间就把排队尖峰挡在输出外 —— 与我们的"追 `latest`"**正相反**。
- **§8/§9.2**：`theta = ½[(T2−T1)+(T3−T4)]`、`delta = (T4−T1)−(T3−T2)`；`epsilon` 以 **PHI=15ppm** 线性增长 ⇒ "误差**显式建模、允许它有界存在**"，不是每包归零。
- **§11.3**：纪律是 **PLL 与 FLL 的混合**；原句：**"a PLL usually works better when network jitter dominates, while an FLL works better when
  oscillator wander dominates"**。⇒ 关系：**支持**"过滤/选样优于追最新"与"误差要建模"；**不能**直接照搬 §11.3 的组合 —— 我们**没有真实振荡器漂移**
  （tick 由我们自己 60Hz 定，漂移是自造的），FLL 那一半没有对应物（见 §5、§6 末尾）。

### 4.2 RFC 3550（RTP）——只给"抖动估计"，**不给** playout 长度

[全文](https://www.rfc-editor.org/rfc/rfc3550.txt)（**读了全文**，重点 §6.4.1、§6.4.4、附录 A.8）。

- **§6.4.1**：`D(i,j) = (Rj − Ri) − (Sj − Si)`（**相对传输时间**之差），**一阶平滑**：`J(i) = J(i−1) + (|D(i−1,i)| − J(i−1))/16`；原文称该算法是
  *the optimal first-order estimator*，增益 `1/16` 是噪声抑制与收敛速度的折中；**附录 A.8** 给了等价实现代码。
- ★ **关键边界（照实说）**：RTP **本身不规定 playout 延迟**，只**测量并上报**抖动（§1 明说 "RTP itself does not provide any mechanism to
  ensure timely delivery"）⇒ **不能**拿它当"playout 该设多少"的依据；能拿的是**"抖动要平滑估计"**这一点。⇒ 关系：**支持**"用一阶平滑估计抖动"；**无关**于"播放时钟的目标"。

## 5. 这个病叫什么（术语，逐个带出处）

| 候选术语 | 出处 | 是否贴我们的病 |
|---|---|---|
| **network jitter vs oscillator wander** | RFC 5905 §11.3 | ✅ 最有用的对立：我们的扰动属 **network jitter**；我们的"漂移"是**自造的参考步进**，不是振荡器漂移 |
| **PLL vs FLL** | RFC 5905 §11.3 | ✅ 纠偏是**纯比例 + 死区**（≈只看相位的弱 PLL），**没有频率状态** ⇒ 没有能"记住速率"的积分器 |
| **Clock filter（最小延迟选样）** | RFC 5905 §10 | ✅ 治的正是我们缺的东西：**参考抖动** |
| **一阶估计器 / 指数加权抖动** | RFC 3550 §6.4.1 + A.8 | ✅ 同族（滤参考，不追样本） |
| **spike-like increases in packet delay** | Ramjee 1994 摘要（**只摘要**） | ⚠️ 支持"尖峰单独处理"，但我们的"锯齿"是**本地生成**的，不是网络尖峰 |
| **clock wander / phase noise / sawtooth** | 无一手来源 | ❌ **未找到**用它描述"参考被周期性重置"的说法；`clock wander` 指**振荡器**漂移，**不要**硬套 |

**不用未证实术语的准确描述**：播放时钟是一个**每来一个包就把参考重置到新样本**的相位跟随器；参考 `latest − playout`
是**阶梯/锯齿**，误差里因此含一个**与缓冲深度无关的常驻分量**（幅度 ≈ 一个发送间隔，被抖动打宽）。

★ 旁证但非同类：[OPODIS 2025《Formalizing Rollback Netcodes…》](https://drops.dagstuhl.de/storage/00lipics/lipics-vol361-opodis2025/LIPIcs.OPODIS.2025/LIPIcs.OPODIS.2025.pdf)
（**读了全文**相关小节）只谈**输入/回滚**的延迟与安全，且假设各客户端 tick 已同步 ⇒ 与本问题**无关**。

## 6. 结论：下一步最该改什么（每条挂来源）

1. **参考从"最新包"换成"过滤后的样本"**：至少做 NTP §10 那种**一窗最小延迟选样**（或 RTP §6.4.1 的一阶平滑）。
   **判据**：参考的一阶差分从"0/1 跳变"变平滑，`mean = playout − 0.93` 里那个 `−0.93` 应当**变小且稳定**。
   来源：RFC 5905 §10、RFC 3550 §6.4.1/A.8（**支持**）；Ramjee 1994 摘要（**支持**，但只到"要处理尖峰"这一层）。
2. **给时钟加"速率"状态，别只留比例项**：`死区 + 比例纠偏(≤±10%)` 只有**相位项**，**持续速率失配**下必然留常驻相位误差。
   改成"**估 `server_tick / client_tick` 比值**（长基线），比例项只当微调"。依据是**本仓实测的持续速率失配**
   （[`netcode-snapshots.md`](netcode-snapshots.md) §5.3 记录过非对称纠偏更差），**不是** RFC 5905 的授权（见末尾矛盾）。
3. **playout 深度按抖动/丢包包络设定，并允许单调回退**：深度是**参数**，不是"追出来的余量"。
   来源：[Gaffer Snapshot Interpolation](https://www.gafferongames.com/post/snapshot_interpolation/)（**支持**：3× 发送间隔；60pps→85ms）、
   [Gaffer State Synchronization](https://www.gafferongames.com/post/state_synchronization/)（**支持**：4–5 帧 @60Hz，**与渲染缓冲别混用**）。
4. **保留"大跳变直落"，并把它与插值/时钟彻底分开**（它不参与控制律）。来源：Valve 原文单独讨论"判断对象是被传送而不是真在飞"
   （中译全文，**支持**）；本仓 `SNAP_DIST` 见 [`netcode-snapshots.md`](netcode-snapshots.md) §4.3。
5. **把"比服务器早多少"当显式参数，必要时主动微调速率**（Overwatch time dilation 形态）：★ **证据最弱**（只有转述实录），
   按纪律**只当选项、不当依据**；要做先用 `--netstat` 读真对局，别照抄数值。

### 来源之间的**矛盾**（不调和）

- **Ramjee/Valve/Gaffer 说"加深缓冲换平滑"**（Gaffer 3× 间隔、Valve 丢包 100ms→200ms），**而本仓实测说加深只线性抬均值、
  治不了那 ~5.8 tick 的超出量**。⇒ 两者**不矛盾也不互相支持**：那些来源默认**参考（发送时刻）可信、被追的是网络**；
  我们的参考**被本地重置**。**参考病治好之前，加深缓冲没有意义**（playout 4/6/8 的 5.8/5.8/5.7 即证据）。
- **RFC 5905 §11.3 内部就有条件对立**：network jitter 主导 → **PLL**；oscillator wander 主导 → **FLL**。
  我们**只有** jitter 那一侧（无真实振荡器漂移）⇒ 按它的条件**该用 PLL 侧**，而"比例 + 死区"**就是** PLL 侧
  ⇒ **照抄 NTP 的条件句，会得到我们今天的方案**。⇒ 想引 §11.3 支持"加频率状态"，先得承认该节的条件句指向**相反**的结论；
  §6 第 2 条的依据只能是**本仓实测的持续速率失配**。

---

## 7. 来源清单

**读了全文（正文）**
- [RFC 5905 (NTPv4)](https://www.rfc-editor.org/rfc/rfc5905.txt) §4、§8–§11.3、附录 A.5.2/A.5.5 ·
  [RFC 3550 (RTP)](https://www.rfc-editor.org/rfc/rfc3550.txt) §6.4.1、§6.4.4、附录 A.8
- [Gaffer《Snapshot Interpolation》](https://www.gafferongames.com/post/snapshot_interpolation/) ·
  [《State Synchronization》](https://www.gafferongames.com/post/state_synchronization/) ·
  [文章总索引](https://www.gafferongames.com/)（用于核实"**没有**时钟同步专文"）
- [Valve《Source Multiplayer Networking》**中译**全文](https://www.cnblogs.com/sun-shadow/p/19715823)（★ 二手译本）·
  [Overwatch GDC2017 实录**转载中译**](https://www.sohu.com/a/148848770_466876)（★ 二手转述）·
  [OPODIS 2025《Formalizing Rollback Netcodes…》](https://drops.dagstuhl.de/storage/00lipics/lipics-vol361-opodis2025/LIPIcs.OPODIS.2025/LIPIcs.OPODIS.2025.pdf)（**与本问题无关**）

**只拿到摘要/标题（正文未读）**
- [Ramjee 1994, DOI 10.1109/INFCOM.1994.337672](https://ieeexplore.ieee.org/document/337672) —— 只有摘要 + 元数据（`openAccessFlag: F`，付费墙）·
  [GDC Vault: "Overwatch' Gameplay Architecture and Netcode"](https://gdcvault.com/play/1024001/Overwatch-Gameplay-Architecture-and) —— 只有标题/简介/讲者

**取不到（逐个列原因）**
- `developer.valvesoftware.com/wiki/Source_Multiplayer_Networking` —— **Anubis 反爬**（返回 "Making sure you're not a bot!" 挑战页）
- `gdcvault.com/play/1024001/…` 的**正文** —— **付费墙**；`dl.acm.org/doi/10.1109/INFCOM.1994.337672` —— **HTTP 403 + Cloudflare 挑战**
- `web.archive.org/web/2023/https://developer.valvesoftware.com/…` —— **存档站域名在本机解析到非公网 IP，工具直接拒绝抓取**
- `computer.org/csdl/proceedings-article/infcom/1994/00337672/…` —— 页面可达但**正文为空壳**（JS 渲染）·
  `gafferongames.com/post/clock_synchronization_in_games/` —— **HTTP 404**（该文不存在，见 §3.1）

## 8. 边界与未验证（照实）

Ramjee 正文未读（§6 第 1 条以 NTP/RTP 为主要依据）；Valve 与 Overwatch 都是译本/转载 ⇒ **不许**据此钉数值或实现细节；Gaffer 没有时钟同步专文 ⇒ 该问题在游戏 netcode 文献里**是空白**，本文档主要依据 NTP/RTP；**没有找到"按到达速率估计"的原句**（§1 第 2 条）⇒ 该说法目前**未被一手来源证实**；本文件是**来源调研**不是方案设计，控制律改动仍按仓库分档走（`PlayoutClock` 属联机承重面）。
