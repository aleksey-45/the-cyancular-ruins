# The Cyancular Ruins

> **基于 Godot 4.7.1 构建的复古像素风格 2D 横版平台跳跃射击游戏**  
> 融合**无缝环面拓扑世界（Toroidal World）**、**16px 精细子格可破坏地形**、**个人时间怀表系统（时空回溯与时间加速）**以及**基于用户态网络隧道的低延迟多人对战**。

---

## 游戏简介 (Overview)

**The Cyancular Ruins**（青之废墟）是一款兼具硬核快节奏平台跳跃手感与高自由度战术对抗的 2D 横版射击游戏。

游戏构建在一个几何拓扑连续闭合的“环面（Torus）无缝世界”中：地图在水平与垂直维度上均自然回绕，子弹、角色与视口能够平滑跨越地图接缝。除爽快的枪械射击与位移手感外，游戏在底层基于 `cyrm v4` 格式实现了 16px 精细子格地形物理破坏，并在单人关卡与 Beta 对战中深度融合了基于时间粒子的“时空回溯”与“时间加速”机制。联机网络系统基于轻量级用户态对等网络隧道（EasyTier no-tun），实现无需管理员提权、仅凭 5 位房间号即可跨公网一键直连对战。

---

## 核心特性 (Key Features)

### 1. 环面无缝几何世界 (Toroidal Wrap-around World)
- 地图水平与垂直边界完全连通，实体离开一侧边界将从对侧无缝回绕出现。
- 渲染层铺设 3×3（9 环面副本）瓦片投影网格与碰撞体，结合最短位移向量几何运算（`toroidal_delta_px`），消除跨接缝时的镜头瞬移、拉扯与视觉割裂。
- Bresenham 视线扫描与 A* 寻路无缝支持环面最短拓扑距离。

### 2. 精细子格可破坏地形 (Destructible Terrain)
- 场景基于 `cyrm v4` 二进制地图格式，在 64px 逻辑网格下实现了 **16px 子格（Sub-cell，4×4 阵列）** 的物理碰撞与生命值管理。
- 爆炸武器（如榴弹）根据爆炸半径产生逼真的圆形破坏弹坑，可破坏墙体随火力打击动态剥落并局部重建物理碰撞体。
- 场景瓦片破坏完全记录于时间账本（[TileLedger](file:///d:/Codes/Antigravity/cyr/core/sim/tile_ledger.gd)），支持被破坏地形精准逆序时空回溯还原。

### 3. 时间玩法机制 (Time Manipulation System)
- **时空回溯 (Rewind)**：长按 Shift 发动。消耗时间粒子，角色沿 20Hz 快照历史轨迹倒退回放，规避伤害并恢复历史状态；倒流的子弹穿过敌人时照常结算二次伤害。
- **时间加速 (Haste)**：长按鼠标右键发动。进入多倍速爆发状态，移动速度、装填与武器射速大幅提升，伴随全屏环境压暗、角色冷白高亮与红蓝交替残影视觉反馈。垂直跳跃高度与重力保持恒定，手感稳定不漂移。
- **时间粒子经济 (Grain Account)**：怀表系统包含总余额指针、短期额度指针与透支状态机（Loan）。短期额度用尽后触发透支，透支加深会带来环境感知反馈与敌人相对加速，耗尽则触发红色锁定。

### 4. 多样化军械库与平台物理 (Weapons & Physics)
- 包含手枪、突击步枪、反器材重狙（M82A1）、双管霰弹枪（S686）、反弹引信榴弹发射器及镜面反射激光枪（DDA 子格多重反射）。
- 支持 8 格预算背包系统（轻/中/重型武器占用不同槽位预算）、地面武器实体交互拾取与长按丢弃。
- 细腻的平台跳跃物理：支持土狼时间（Coyote Time）、跳跃输入缓冲、空中冲刺打断、梯子/锁链多速攀爬、水体浮力与游泳、以及落地挤压拉伸（Squash & Stretch）动态形变。

### 5. 丰富的联机对战模式 (Multiplayer Modes)
- **1v1 回合对决 (Duel)**：抢五胜制，局间两队对调出生点，换局时重置场景瓦片基线与动态投射物。
- **自由大乱斗 (Royale)**：多玩家混战抢分。配备**三级动态防卡死复活点算法**（开阔/降级/极限候选池，避让存活对手 8 格距离，防止复活在封闭死角）、AI 机器人自动补位与 3 秒击杀归因机制。
- **3v3 团队对抗 (Team 3v3)**：
  - 分队碰撞层实现**友军物理穿透**（1 队与 2 队独立碰撞掩码，严格保留地形防穿墙）；
  - 子弹穿透队友，爆炸武器 AOE 伤害全员满效结算；
  - 角色基于基准主色实现队伍自适应比例着色，防止纹理发暗。
- **Beta 时间玩法**：
  - 在多人环境下启用服务端权威时间经济（[TimeEconomy](file:///d:/Codes/Antigravity/cyr/server/time_economy.gd)），支持击杀、伤害、破坏子格与自动回复获取粒子；
  - 个人专属时间加速（弹速同步提升，其他玩家头顶呈现「▶▶ 3x」标识）与个人专属时空回溯（进入无敌状态沿轨迹回退）。

### 6. 网络同步与连接韧性 (Netplay & Architecture)
- **轻量对等网络隧道 (EasyTier no-tun)**：纯用户态套接字工作，无需管理员提权（零 UAC 弹窗），免装虚拟网卡驱动，全纯 UDP 通信杜绝队头阻塞，仅凭 5 位房间号自动打洞直连。
- **单进程单端口服务端 + 60Hz 快照广播**：服务端以无头模式运行权威物理，60Hz 拆分广播全员世界包与个人权威包；客户端本地输入预测与 C2 Rollback 回滚纠偏。
- **贴身自适应容差**：两角色贴身近战时，位置容差由 2.0px 自动放宽至 8.0px，消除碰撞挤压导致的预测抖动。
- **双阶段断线恢复**：支持局内 60 秒快速闪断重连（Grace Window，内存保留实体，增量补态）与退回大厅后的跨场景 Token 凭据重进（RejoinRegistry，TTL 1小时）。

---

## 操作说明 (Controls)

游戏支持键盘与鼠标操作，可在游戏设置菜单（ESC → 设置）中自定义键位绑定：

| 动作分类 | 操作按键 | 功能说明 |
|---|---|---|
| **移动控制** | `A` / `D` | 向左 / 向右移动 |
| | `W` / `Space` | 跳跃 / 向上攀爬梯子 / 水中上浮 |
| | `S` | 下蹲 / 下落穿过单向板 / 向下潜水 |
| | `Shift` (短按) | 水平快速冲刺（空中亦可触发） |
| **射击与战斗** | `鼠标移动` | 360° 武器瞄准指向 |
| | `鼠标左键` | 开火（按住可持续射击或蓄力） |
| | `1` ~ `4` / `鼠标滚轮` | 切换背包中的武器槽位 |
| | `F` | 拾取附近的地面武器 |
| | `Q` (长按) | 丢弃当前手持武器 |
| | `K` | 团队模式中请求自毁（向敌方队伍送分） |
| **时间技能** | `Shift` (长按) | **时空回溯**（按住进入历史回放模式，单人关卡与 Beta 模式有效） |
| | `鼠标右键` (按住) | **时间加速**（按住使角色以多倍速爆发行动） |
| **系统控制** | `Esc` | 打开/关闭暂停菜单与设置界面 |
| | `R` | 单人关卡原地快速重置（倒地后重开） |

---

## 快速开始 (Quick Start)

### 环境要求
- **引擎版本**：Godot Engine **4.7.1**（标准版 Standard，非 Mono/.NET 版）。
- **运行平台**：Windows x64 / Linux x64。
- **显示配置**：基准视口分辨率 1920×1440，移动端渲染后端（`rendering/mobile`）。

### 源码运行方式
1. 克隆本项目仓库至本地目录：
   ```bash
   git clone https://github.com/aleksey-45/the-cyancular-ruins.git
   cd the-cyancular-ruins
   ```
2. 使用 Godot 4.7.1 编辑器导入根目录的 `project.godot` 文件。
3. 在编辑器中按 `F5`（运行项目）即可进入主菜单。
4. **单人游玩**：在主界面点击「单人游戏」，即可载入单人测试关卡。

---

## 联机对战指南 (Multiplayer Setup)

游戏采用了去中心化的轻量对等网络方案，无需公网固定 IP，也无需配置路由器端口映射（Port Forwarding）：

```text
┌─────────────┐                                ┌─────────────┐
│  玩家 A 客户端 │ ── 5 位房间号 (P2P 隧道中继) ── │  玩家 B 客户端 │
└──────┬──────┘                                └──────┬──────┘
       │ (本地回环)                                    │
┌──────▼──────────────────┐                            │
│ 本地专用服务端 (Worker)   │ ◄─────────────────────────┘
│ 同步世界物理、弹道与状态   │
└─────────────────────────┘
```

### 1. 快速开局步骤
1. **网络初始配置**：
   - 联机依赖公网中继节点交换初始端点。游戏目录下的 `easytier/relay.txt` 需配置有效的中继服务器地址（发布包中已随包附带）。
2. **房主建房**：
   - 房主从主菜单选择对战模式（如「1 v 1」、「大乱斗」、「3 v 3」或「Beta 时间玩法」）。
   - 点击面板中的「**创建房间**」。客户端将在后台动态分配端口拉起本地专用服务端，并在界面生成一个唯一的 **5 位数字房间号**（如 `48213`）。
   - 将该 5 位房间号发送给好友。
3. **客机加入**：
   - 客机进入对应模式界面，在输入框中输入房主提供的 **5 位房间号**。
   - 点击「**加入房间**」，网络层将自动完成 P2P 隧道穿透、端口映射并连接至房间，双方就绪后自动载入对局。

### 2. 独立服务器部署 (Dedicated Server)
若需要在云服务器或局域网主机上常驻运行大厅服务端供多人联调，可执行：
```bash
# Windows 控制台运行 (默认监听 7777 端口)
"Cyancular Ruins Server.exe" -- --port 7777

# 或通过批处理脚本启动
start_server.bat
```

详细网络协议实现与故障诊断指南请参阅 [docs/netplay.md](file:///d:/Codes/Antigravity/cyr/docs/netplay.md)。

---

## 技术架构简析 (Architecture)

### 1. 工程目录结构

```text
the-cyancular-ruins/
├── assets/          # 游戏静态资源（字体、图集、音频素材）
├── core/            # 核心系统与全局服务（Autoload / 算法 / 物理纯逻辑）
│   ├── config/      # 全局配置、参数表（时间参数、玩法规则、按键、隧道元数据）
│   ├── net/         # 网络总线（NetBus）、隧道编排、输入源抽象与回滚控制器
│   └── sim/         # 纯逻辑模拟器（环面几何、瓦片账本、寻路、时间账户）
├── data/            # 静态数据表（tile_defs.json / enemies.json）
├── docs/            # 核心系统设计规范、测试报告与网络架构文档 (netplay.md)
├── maps/            # .cyrm 文本与二进制关卡地图文件
├── render/          # 渲染管线、后处理 Shader 与相机控制
├── scenes/          # 场景与业务组件（按模块划分 snake_case 命名）
│   ├── effects/     # 时间发光 (TimeGlow)、残影 (Afterimage)、结晶与形变
│   ├── enemies/     # 敌方实体与 AI 状态机
│   ├── player/      # 玩家角色本体、物理组件与远端副本
│   └── weapons/     # 各类枪械、子弹与伤害判定
├── server/          # 服务端权威模拟、单进程房间调度、时间经济与凭据注册表
├── tests/           # 自动化测试套件、纯逻辑冒烟脚本与场景诊断探针
├── tools/           # 构建打包脚本、发布工具与依赖拉取脚本
├── ui/              # 用户界面组件（HUD、怀表、卡片拾取器、菜单、结算）
└── project.godot    # Godot 项目总配置文件
```

### 2. 设计规范亮点
- **纯逻辑无依赖下沉**：核心算法（`GridPathfinder`、`MapFormatV4`、`GrainAccount`、`TimeRules`、`RejoinRegistry`、`GraceWindow`）全部继承 `RefCounted`，零场景、零 Autoload 依赖，可直接在无头模式下执行秒级冒烟测试。
- **表现与物理状态严格解耦**：挤压拉伸（`SquashStretch`）纯动画缩放；加速高亮（`TimeGlow`）叠加 Additive 图层，彻底解决非 HDR 环境及受击闪白冲突。
- **UI 工厂单一来源**：全项目界面控件样式与调色板收敛于 [UiFactory](file:///d:/Codes/Antigravity/cyr/ui/ui_factory.gd)，字号严格为 16 的倍数，配合 GNU Unifont / DOS VGA 字体确保硬边缘点阵像素完美对齐。

---

## 构建与测试 (Build & Test)

### 1. 一键打包发布
项目提供了自动化构建与分发脚本：
```bash
python tools/build_release.py
```
构建脚本将自动化执行客户端/服务端导出、子系统设置、完整性冒烟校验，并在 `builds/` 目录下生成包含完整运行依赖（含 `easytier/` 四件套与 `relay.txt`）的便携式发布包。详细说明请参考 [RELEASE.md](file:///d:/Codes/Antigravity/cyr/RELEASE.md)。

### 2. 自动化测试套件
项目配备了多层次的无头自动化测试探针与冒烟测试：
```bash
# 验证核心物理、武器与敌人逻辑
godot --headless --path . -s res://tests/enemy_logic_smoke.gd

# 验证时间玩法逻辑与粒子账户状态机
godot --headless --path . -s res://tests/grain_account_smoke.gd
godot --headless --path . -s res://tests/time_field_smoke.gd

# 验证 cyrm v4 16px 子格破坏与还原
godot --headless --path . -s res://tests/subcell_probe.gd

# 验证 PvP 时间经济与规则体系
godot --headless --path . -s res://tests/time_economy_smoke.gd
godot --headless --path . -s res://tests/time_rules_smoke.gd

# 验证网络隧道与断线重连凭据
godot --headless --path . -s res://tests/netplay_probe.gd
godot --headless --path . -s res://tests/rejoin_registry_smoke.gd
godot --headless --path . -s res://tests/grace_window_smoke.gd

# 验证端到端网络房间与对局流程
bash tests/pvp_room_smoke.sh
bash tests/pvp_match_smoke.sh
```

---

## 许可证与鸣谢 (License & Acknowledgments)

- 游戏核心代码与原创内容遵循开源协议分发。
- 基于 [Godot Engine](https://godotengine.org/) 驱动。
- 远程网络对等隧道基于 [EasyTier](https://github.com/EasyTier/EasyTier)（LGPL-3.0 协议）开发集成。
- 字体采用 GNU Unifont 像素点阵字体以保障全平台多语言显示。
