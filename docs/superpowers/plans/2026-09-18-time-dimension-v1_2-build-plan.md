# 下一大版本构筑方案 —— 时间维度「钟即世界」

> 状态:**待评审** · 基线分支:`proto-time-map`(`c77146d`) · 设计源:`docs/design/time-dimension-gdd.md` **v0.3(单钟定稿)**
> 本文是**施工图**:把 GDD 的 M1~M8 落到具体文件 / 函数 / 探针 / 验收标准上;设计取舍以 GDD 为准,本文只回答"怎么落、落在哪、怎么验"。
> 全部结论都带 `文件:行` 证据;**未验证的推测一律标 UNVERIFIED**。

---

## 0. 结论速览(TL;DR)

1. **下一大版本 = 时间维度**,首版**仅单机**,1v1 / 大乱斗只做"不破坏"兼容(§3)。
2. 设计已在 GDD v0.3 收敛为**单钟**:一根世界针 W 既是地图状态坐标、也是全部时间资源;
   击杀回拨、消费推进、无个人针、无灌注系数 K。
3. **代码只落地了 v0.1 的正向半边**:能解析 `# tl:`、能倒计时、能执行坍塌/炸开;
   单钟账本、10ms 粒度、子弹时间、事件溯源/LIFO 回拨全部缺失(§1.2 差距表)。
4. **本轮已交付 M1 纯逻辑层**(`TimeParams`/`TimeClock`/`TimeTimeline` + `TimeWorld` 门面 + 验收探针,§4.1),
   并把 GDD v0.3 合并回本线(设计源与代码同分支)。
5. 开工前必须处理的**三件事**:①进图原生段错误(§8.1)②三条版本线的收敛(§9.2)③事件逆操作完备性纪律(§5.3)。

---

## 1. 现状盘点

### 1.1 工程规模与骨架(事实)

| 项 | 值 |
|---|---|
| GDScript / 场景 | 132 个 `.gd` / 48 个 `.tscn` |
| autoload | 4 个:`GameParameters`、`NetBus`(逐字节冻结)、`NetBusExt`(扩展信封)、`Settings` |
| 三条玩法路径 | 单机 `level_0.gd` / 1v1 `pvp_client.gd`+`match_host.gd` / 大乱斗 `royale_game.gd`+`royale_host.gd` |
| 共享基建 | `WorldBuilder.load_grid/build_sim`、`CollisionBuilder` 分块重建、`TileDefs` 属性表、`EnemySpawner`、道具卡(槽 81~84) |
| 渲染 | 1920×1440、`rendering/mobile`、世界画进 SubViewport 后 `PostProcess`(layer 128)后处理 |

### 1.2 设计(GDD v0.3)↔ 代码 差距表

| GDD v0.3 条款 | 代码现状 | 差距 |
|---|---|---|
| §1.2 **单钟**:击杀 → W 回拨;消费 → W 推进 | `Globals/time_world.gd` 只有"倒计时 + 阈值事件",没有账本、没有回收、没有消费 | **缺账本**(本轮补齐纯逻辑) |
| §12.2 **10ms 粒度**(内部浮点秒,显示百分秒) | 旧 `tick(delta)` 直接 `w -= delta`,无粒度;HUD `"T-%02d"` 只到整秒 | **缺粒度 + 缺百分秒显示** |
| §12.3 **子弹时间/决策时停** `scale` | 不存在。Esc 暂停靠 `get_tree().paused`(暂停即不 `_process`,天然不烧钟) | **缺 scale**(本轮补);非暂停型决策 UI(M5 商人)需要它 |
| §12.4 **事件溯源**:日志 + 正逆操作 + 玩家操作入史 + LIFO 回拨 + 重新武装 | 旧模型是"单向调度器 + `_fired` 布尔",回拨不存在 | **缺事件日志/逆操作/回拨**(本轮补纯逻辑) |
| §4.2 事件原型 8 个 | 只实现 `collapse`/`open` 两个 | 缺怪潮/强化/时间风暴/补给窗/地貌/播报 |
| §4.4 击杀回收表 | 不存在 | 缺(需敌人 → 类型键映射) |
| §4.7 表 HUD(单针 + 收支动效 + 阶段演出) | `level_0._build_clock_hud()` 建 layer 140 的 `T-xx` 文本 + 5s 预警 | 缺百分秒/阶段名/收支动效/色板 |
| §4.3 `.cyrm v4`(空间层 + 时间层分离) | `MazeGenerator` 只认 `# cyrm-v3`;`map/timetest.cyrm` 靠"v3 标记 + v4 注释"混写 | **缺 v4 标记识别**(本轮补);缺编辑器导出时间层 |

### 1.3 直接可复用的六项基建(带证据)

1. **可破坏瓦片分块重建** — `CollisionBuilder.rebuild_chunk` / `chunk_of`(`Globals/collision_builder.gd:19,152`),
   单块 O(块面积);`level_0._dirty_chunks` 分帧重建(每帧 ≤2 块,`Scenes/level_0.gd:327-338`)。
   → 坍塌/崩开 = 改网格 + 铺 9 副本瓦片 + 标脏块,已有实现(`level_0._apply_region`,`:368-391`)。
2. **瓦片属性表** — `Globals/tile_defs.json` + `TileDefs`(`hp/type/elastic/...`);
   破坏回调是**单槽 Callable** `TileDefs.on_destroyed`(`Globals/tile_defs.gd:87`,调用点 `:122-123`)。
   ⚠️ 已被 `level_0`(`:99`,revive 时 `:176`)与 `MatchHost`(`server/match_host.gd:72`)占用 →
   **玩家拆墙入史必须"链式包装"而不是覆盖**,否则瓦片渲染/碰撞清理静默失效。
3. **刷怪** — `EnemySpawner.spawn_all`(`Scenes/Enemies/enemy_spawner.gd:51`)、
   `sample_spawn_cells`(`:28`)、注册表 `editor/enemies.json`、刷怪信号 `enemy_spawned`(`:5` → `hud.gd:49-51`)。
   → 已有"现在刷一波"的现成写法:`MenuDemoAi._spawn_wave`(`Scenes/menu_demo_ai.gd:161-182`);
   ⚠️ 它绕开 `spawn_all`,**不发 `enemy_spawned`**(HUD 击杀计数不认这批)。
4. **道具卡管线** — 注册表 `weapon_component.WEAPONS`/`DISPLAY_NAMES`/`PROP_SLOTS`
   (`Scenes/Player/weapon_component.gd:8-21,24-25,30`)、投掷基座 `Scenes/Weapons/prop_launcher.gd`、
   爆炸/AoE `Globals/explosion.gd`;**封存时间块 = 新道具卡**(GDD §4.6)。
5. **后处理** — `Scenes/post_process.gd`:`set_downed`(`:57`)、`flash_hit`(`:63`),
   shader `Shaders/post_process.gdshader` 有 `desat`/`hit_red` 两个 uniform。
   ⚠️ **没有公开的通用 uniform setter**(`_mat` 私有 `:9`),色板/暗角需要新增公开方法。
6. **音效** — `Globals/sfx.gd` 程序合成 13 种音(`shoot/hit/explosion/kill/ui/...`,`:60-72`);
   无"滴答/钟鸣"类音效 → §4.2 的"预告滴答加速"需要新增 1~2 个音种。

---

## 2. 方向:为什么是时间维度

三条设计支柱是**机制**而不是换皮,所以它能同时拉动"关卡形态、资源经济、战斗动机"三件事:

| 支柱 | 机制落点 | 对现有系统的价值 |
|---|---|---|
| 钟即世界 | W 阈值驱动地图改写(坍塌/崩开/怪潮/色板) | 让"同一张图"随钟变形,内容量 = 图 × 事件表,而不是图 × 3 套 |
| 时间即代价 | 交易/铸造封存 = W 向毁灭推进 | 给道具系统(已存在,槽 81~84 + 卡编辑器)接上**统一货币**,经济循环立刻成立 |
| 夺回即推进 | 击杀 = W 回拨 | 给"打鸟"这件事一个超越击杀数的意义,战斗直接改写世界状态 |

外加一条**叙事腰**:失败 = 钟走到尽头(全图终末化),胜利 = 把钟拨过灾前(真结局)。

---

## 3. 范围与非目标

**首版范围内**

- 单机(`Level0` + `RunOptions`),时间层只挂在 `level_0` 的单机分支上。
- 数据层:`.cyrm v4`(v3 空间层 + `# tl-w0:` / `# tl:` 时间层);无时间层的旧图 = 无时间玩法(不自动生成,M7 再上程序化生成)。
- 表 HUD:单针 + 百分秒 + 阶段 + 事件预告 + 收支动效。
- 事件原型先做 `collapse`/`open`/`spawn_wave`/`reskin`,其余原型登记待做。

**非目标(明确不做)**

- ❌ 联机时间同步(共享针、服务器权威回拨)——二期,接口按 §5.4 预留。
- ❌ 双针/联动系数 K——v0.2 已废除,只作为"资源深度不足"时的后备方案存档,不写代码。
- ❌ 随机图时间层自动生成——M7。
- ❌ 触碰 `NetBus`(逐字节冻结)、`GameParameters`/`PlayerParams` 既有字段语义、PvP 输入包结构。

---

## 4. 里程碑施工图

> 每期=一个可独立验收的薄片;验收探针一律用 headless 跑,**不依赖完整 GUI**。

### 4.1 M1 时间账本 + 单针表盘 + 子弹时间 —— **纯逻辑层已完成(本轮)**

**已交付(可开工即用)**

| 新增/改动 | 内容 |
|---|---|
| `Globals/time_params.gd`(新) | 参数总表:轴长/开局针/粒度/阶段加成与阈值/**击杀回收表**/流速场/时停档/封存面额/死亡惩罚;单位换算与派生纯函数(`kill_seconds`/`phase_of`/`decay_multiplier_of`/`format_clock`) |
| `Globals/time_clock.gd`(新) | **单钟账本**:`elapse`(10ms 量化 × scale × flow × 阶段衰减)、`recover`(回拨)、`spend`(消费)、`recover_kill`、`destruction`/`phase`、结算统计、4 个信号(`w_changed`/`phase_changed`/`final_reached`/`pre_ruin_reached`) |
| `Globals/time_timeline.gd`(新) | **事件溯源日志**:`# tl-w0:`/`# tl:` 解析(小数秒)、正逆操作对(collapse↔open 自动配对)、`crossings`(只正向跨越、t 降序)、`rewind_ops`(**回拨逆操作,按世界钟上升方向排 = t 升序**)、`next_pending_t`、`record_player_op`、`incomplete_inverses`(逆操作完备性自检) |
| `Globals/time_world.gd`(改) | 门面:保持 v0.1 API(`parse_for`/`has_events`/`next_trigger`/`tick`/`w0`/`w`/`events`)**零破坏**,内部改为 Clock+Timeline;新增 `rewind_to`/`record_player_op`/`set_scale`/`set_flow`/`phase`/`destruction` |
| `Globals/maze_generator.gd`(改) | 新增 `V4_MARKER`,v3/v4 都按"每格 4 字符"解析 → v4 图的**空间层零改动**可用 |
| `Tests/time_ledger_probe.gd`(新) | M1 验收:参数/粒度/时停/账本/信号/解析/跨越/回拨/入史/门面+v4 端到端 |

**验收(已实测通过)**

```bash
"C:/Godot/Godot_v4.7.1-stable_win64_console.exe" --headless --path . -s res://Tests/time_ledger_probe.gd
# → TIME LEDGER PROBE: OK(参数/粒度/时停/账本/信号/解析/跨越/回拨/入史/门面/v0.1兼容)
```

> ⚠️ **受限沙箱/只读用户目录下必须加 `--log-file <工作区内路径>`**:Godot 默认把日志写到
> `user://logs/` 并做轮转,写入被拒时会在启动阶段直接段错误(signal 11)——
> 这与项目已知的"进图段错误"是两码事,排查时别混淆。本探针已在 `res://` 回退路径上验证过。

**M1 收尾项(下一步就做)**

1. **表盘 HUD 抽件**:把 `level_0._build_clock_hud`(`Scenes/level_0.gd:394-421`)抽成
   `Scenes/time_hud.gd`(`class_name TimeHud extends CanvasLayer`,layer 140):`T-14.30` 百分秒 +
   阶段名 + 预告字幕 + "击杀倒跳/消费前窜"动效;`level_0` 单机路径挂载,`pvp_mode` 不挂。
2. **时停接线**:决策型 UI(非场景树暂停)打开时 `TimeWorld.set_scale(SCALE_PAUSE)`,关闭还原;
   M5 商人界面是第一个消费者。
3. **开关**:`RunOptions.time_enabled`(默认 true)+ `Settings.time_enabled`(**save/load 两处都要加**,
   见 §7 陷阱)。

### 4.2 M2 事件执行器 + 回拨落地 + 编辑器导出 —— 让"世界真的会变"

| 工作项 | 落点 |
|---|---|
| 事件执行器(区域改写) | 已有 `level_0._apply_region`(`:368-391`);补 `spawn_wave`(区域刷怪)/`reskin`(瓦片皮肤)两条 |
| 区域刷怪 | `EnemySpawner` 增 `spawn_cells_now(world, type_id, cells)` + 区域版地板格扫描(抄 `enemy_spawner.gd:33-36`,`MenuDemoAi._spawn_wave` 的写法),**必须发 `enemy_spawned`** 保住 HUD 计数 |
| 玩家操作入史 | `TileDefs.on_destroyed` **链式包装**(`Globals/tile_defs.gd:87`):先调旧回调,再 `TimeWorld.record_player_op({destroy_tiles...}, {restore_tiles...})`,值取破坏前网格 |
| 回拨驱动世界 | `TimeWorld.rewind_to(target)` 返回的逆操作交给 `level_0` 执行(`open`→清瓦片、`restore_tiles`→回填);**逆操作必须闭包化**(值随操作一起入史,不许回查 `pristine_grid`,否则玩家后续改动会被抹掉) |
| 编辑器导出时间层 | `editor/structure-editor.html`(独立 HTML 工具)加"时间层"面板:阈值/动作/区域/标签 → 导出 `# cyrm-v4` + `# tl:`;`editor/smoke.js` 加解析断言 |
| 演示图 | 把 `map/timetest.cyrm` 升为 v4(标记改 `# cyrm-v4`),补一条小数秒事件与一条玩家可拆的墙,作 M2 手测图 |

**验收**:新探针 `Tests/time_map_probe.gd` 升级(或新增 `time_event_probe.gd`):
①正向坍塌/崩开可复现 ②`rewind_to` 后桥重开 + 瓦片/碰撞回滚 ③玩家拆墙入史、回拨后复原 ④重新武装后再次跨越可再触发。

### 4.3 M3 击杀回收 + 消费 + 表盘动效

- 敌人 → 类型键映射:`EnemyBase` 场景名(`FlyBird`/`JumpBird`/`BlackBird`)→ `TimeParams.KILL_VALUES_MIN`;
  挂点选**倒地边沿**(单机 `CombatComponent` 的 `hp_changed`/`_downed` 或 `EnemyBase._begin_death`),
  用 `last_damager` meta 归因(纯环境死/溺水不给回收)。
- 消费:道具使用/交易接口先行留桩(`TimeWorld.clock.spend()` 已就绪)。
- 表盘动效:击杀时指针倒跳一小格、消费时前窜 + 短促红闪(GDD §4.7)。

**验收**:探针断言"击杀 1 只黑鸟 → W +60s,`recovered_total` +60,阶段信号按需触发";HUD 动效走 GUI 手测。

### 4.4 M4 毁灭度四阶段参数包

- `PostProcess` 增**公开**方法(如 `set_phase_params(tint: Color, vignette: float)`)+ shader 新 uniform
  (注意:现有 shader 里 tint 在 `desat` 之前,倒地时会被去饱和,顺序要对)。
- 阶段切换:`TimeClock.phase_changed` → 色板渐变 + 钟鸣(需新增 Sfx 音种)+ HUD 阶段名。
- 刷怪表切档:区域刷怪走阶段参数包(密度/类型权重)。

**验收**:探针断言阶段阈值/信号;手测阶段切换演出。

### 4.5 M5 时间商人 + 封存时间块(道具卡接入)

- 封存块 = 新道具卡:注册表加槽(建议 **85**)、`editor_schema.gd` 校验白名单必须同步
  (`DevTools/editor/editor_schema.gd:371`,否则卡存不进去)、`kind`/`effect` 枚举扩展。
  ⚠️ 现有校验按 `effect` 分支强制"非烟雾 = `blast_force != 0`"(`:379-388`),**无冲击的就地道具会被误判**,
  必须先重构成按 `kind` 分支。
- 就地道具(`fire()` 覆写,参照 `Scenes/Weapons/prop_timed_bomb.gd:16-22`),不走 `_spawn_projectiles`。
- **先修道具探针**:`Tests/prop_probe.gd`/`prop_e2e_probe.gd` 仍断言旧槽 8/9/10/11(与现在的 81~84 + 槽 8 砍刀不符),
  M5 动注册表前必须先把它们改对,否则"测试全红"会掩盖真回归。
- 已知贴图缺口:`Scenes/Weapons/prop_timed_bomb.tscn` 引用的 `assets/textures/prop_timed_bomb.png` 不在仓库里。
- 商人 NPC:新场景 + 交互区;交易 = `clock.spend()`(单钟下"花钱就是让灾变提前")。

### 4.6 M6 三结算 + 最终 Boss「灾厄守时者」

- 结算:死亡惩罚(`clock.spend(DEATH_PENALTY_MIN)`)、终末(W=0,全图终末化演出 → 结算画面 → 回主菜单,
  走 `Level0.safe_change_scene`)、真结局(W ≥ 灾前)。
- Boss:新敌人 = 一个 `.tscn` + `editor/enemies.json` 加一行 + `EnemyParams` 加嵌套类;
  攻击偷时间(命中扣 W)实现"血量 vs 钟"双线权衡。
- ⚠️ 走 `Level0.safe_change_scene` 回菜单,别直接 `change_scene`(见 AGENTS「场景切换纪律」)。

### 4.7 M7 时间层程序化生成(随机图)

- 由"事件原型模板库 + 种子"生成事件表:锚定**毁灭度阶段阈值**而非绝对分钟(避免 K/回收速度让编排失准)。
- 反向:无时间层的 v3 图也生成默认时间层(此前是"无事件=无玩法",M7 起全覆盖)。

### 4.8 M8 数值平衡 + 教学关

- 教学三件事(桥塌/击杀倒跳/商人)、经济压力测试(重复击杀递减 `KILL_REPEAT_DECAY` 启用)、
  15–30 分钟标准局节奏。

---

## 5. 技术设计要点

### 5.1 单位与方向(最容易写错的地方)

- **内部一律秒(float)**,GDD 表格是分钟 → 只经 `TimeParams.min_to_sec()` 换算。
- **W = 距最终时刻的剩余量**:自然衰减/消费 → W 减小;击杀回收/解封 → W 增大。
  GDD §4.1 表里的"前进/回拨"说的是**轴位置**,不要直接当 W 的加减用。
- 毁灭度 `D = (FINAL − W) / FINAL`;`W = FINAL` 即灾前(D=0)。

### 5.2 时停的两种形态

| 形态 | 机制 | 适用 |
|---|---|---|
| 场景树暂停 | `get_tree().paused`(现有 Esc 暂停菜单) | 设置/暂停——`_process` 不跑,天然不烧钟 |
| 逻辑时停 | `TimeClock.scale = 0`(本轮已实现) | **非暂停型决策 UI**:商人/合成/地图——世界照跑,只有钟停 |

### 5.3 事件溯源的铁律

- 每个入史 kind **必须带正确逆操作**;`TimeTimeline.incomplete_inverses()` 是常驻自检,M2 起纳入探针。
- 逆操作必须**自带数据**(改前的值随日志一起存),不能回查 `_pristine_grid`,否则"回拨到 20 分钟前"会把
  玩家 15 分钟时的合法改动一起抹掉。
- **击杀不入史**(GDD §12.4):实体位置不回拨 → 回拨只撤"世界的伤",不撤"战果";
  因此回拨后敌人尸体/掉落不回滚,这是设计决定,不是 bug。
- 边界语义:`crossings(w_old, w_new)` 只认 `w_new <= t < w_old`;
  **阈值必须严格小于 `w0` 才会触发**(写在 `w0` 上的事件永不触发)——解析器已加告警。
- **回拨执行顺序容易写反(本轮已踩)**:世界钟下降时按 t 降序跨越阈值,回拨 = 钟**上升**,
  因此撤销顺序是 **t 升序**(先撤最小阈值;玩家在钟值 20 拆的墙最后复原),
  不是"按 t 降序倒放"。探针 `time_ledger_probe` 已把该顺序钉死(含玩家操作与定时事件混排)。

### 5.4 联机预留(只留缝,不实现)

- W 是**全局标量**:二期由服务器权威推进 + 阈值广播(走 `NetBusExt` 信封,新 `kind`,不动 `NetBus`),
  客户端插值显示,不进 C2 `capture_state`(避免新增分歧源)。
- 消费/解封这类"推进 W"的操作在多人下必须服务器裁决(投票/房主决定)。
- 封存块天然是可转让载体 → 玩家间交易二期直接用。

---

## 6. 参数与数据契约

### 6.1 参数去哪改

| 想改什么 | 去哪 |
|---|---|
| 时间维度全部数值(轴长/开局针/阶段加成/回收表/流速/时停/面额/惩罚) | `Globals/time_params.gd` |
| 单图的时间线 | 地图文件 `# tl-w0:` / `# tl:` 行 |
| 时停/开关等玩家偏好 | `Settings`(+ `RunOptions` 会话级) |

### 6.2 `.cyrm v4` 时间层语法(权威定义)

```
# cyrm-v4                                    ← 标记:空间层 = v3(每格 4 字符),另含时间层
# player 56 47                               ← 空间层元数据照旧
# tl-w0: 3600                                ← 世界针起始(秒;缺省 3600 = 60min)
# tl: 1800 collapse 22 20 17 11 桥梁坍塌      ← <t> <action> <x> <y> <w> <h> [标签...]
# tl: 900.25 open 46 20 1 10 密室炸开         ← t 支持小数秒(10ms 粒度)
```

- 动作原型:`collapse`(变实心)/`open`(变空气)已实现;`spawn_wave`/`reskin` 在 M2;
  其余(强化/时间风暴/补给窗/播报)**只登记不执行**,逆向记 `noop` 并由探针报缺口。
- 无 `# tl:` 行的 v3/v4 图 = 普通图(时间系统整体旁路),HUD 不出现。

### 6.3 封存时间块(= 道具卡)

面额 `5/10/25` 分钟(`TimeParams.SEAL_DENOMINATIONS_MIN`);铸造时 W 前进(+面额)、解封时 W 回拨(−面额);
死亡豁免封存量;进阶变体"时间回溯区"= 区域内已触发事件反向重置(稀有卡)。

---

## 7. 兼容性与回归风险矩阵

| 改动点 | 风险 | 防控 |
|---|---|---|
| `TimeWorld` 门面 API | 破坏 `level_0._tick_world` / 旧探针 | **已保持 v0.1 API 不变**;`w0`/`w`/`events` 兼容字段同步 |
| `MazeGenerator` v4 标记 | 误判 v3 图 | 只是"多认一个标记",解析路径不变;`time_ledger_probe` 已断言 v4 网格/spawn/map_size |
| `TileDefs.on_destroyed` | 覆盖会让瓦片渲染/碰撞清理失效 | M2 起**链式包装**,禁止直接赋值 |
| `Settings` 新增键 | 只写 `save()` 不写 `load_settings()` → 不生效 | 两处同改(§4.1 收尾项 3) |
| 道具槽位注册表 | 探针过期导致"全红"掩盖真回归 | M5 前先修 `prop_probe.gd`/`prop_e2e_probe.gd` 槽号 |
| 事件回拨 | 幽灵状态(墙/碰撞/物品与日志不一致) | 逆操作完备性探针 + 逆操作自带数据 |
| 阶段色板 | `desat` 在 tint 之后 → 倒地时色板被去饱和 | M4 明确 shader 顺序 |
| 单机/PvP 双路径 | 时间系统漏进 PvP/MatchHost | `level_0` 侧 `pvp_mode`/`menu_demo` 早退分支不动;服务器不引 `TimeWorld` |
| 回菜单/重载 | 大物理世界同步释放 → 原生段错误 | 一律走 `Level0.safe_change_scene`(硬约定) |

---

## 8. 风险登记册

### 8.1 【最高优先】进图原生段错误(既有技术债,时间维度会放大它)

- 现象:菜单 → 游戏世界方向 headless 约 50% 概率 `signal 11`(AGENTS「段错误排查重大进展」已二分到"游戏侧无可关的灯")。
- 为什么和本版本强相关:**时间维度每局要反复改写瓦片 + 重建碰撞块 + 回拨复原**;
  世界构建/释放路径不稳,底层的"世界会变"就没法稳定迭代。
- 本轮新证据(可复现的最小样本):在**受限沙箱/只读用户目录**里,Godot 连纯 `-s` 探针都会在启动阶段段错误,
  原因是默认日志轮转写 `user://logs/` 被拒(`copy (core/io/dir_access.cpp:429)`);
  加 `--log-file <工作区内路径>` 即恢复正常。
  → 排查真 bug 时必须先排除这一路:凡"启动即崩/无任何脚本输出"的样本,先用 `--log-file` 复测。
- 建议:开工前用带符号调试引擎(`AGENTS` 已记录 `C:\Users\21559\godot-4.7.1-src` 的编译方案)抓一次原生调用栈;
  在拿到栈之前,新功能一律按"世界可重建"设计(幂等构建 + 分帧 + 不释放挂起)。

### 8.2 其他风险

| 风险 | 对策 |
|---|---|
| 内容成本(每图多时刻形态) | 事件驱动**局部**状态(不做整图三套);原型复用;M7 兜底生成 |
| 经济崩坏(刷怪回拨无限) | 重复击杀递减(`KILL_REPEAT_DECAY`)+ 封存铸造损耗;M8 压测 |
| 消费推进被用来"烧钟"绕过编排 | 事件阈值锚定**阶段**而非绝对分钟;价目表上限;M8 调 |
| 玩家不理解单钟 | 教学关三段式 + 表盘因果可视化(击杀倒跳/消费前窜) |
| 回拨产生幽灵状态 | 逆操作完备性铁律 + 探针常驻 |
| 与上游 main 合流冲突 | 时间系统=**加法层**(新文件 + 现有系统挂点),按作者 KH-merge 流程提交 |

---

## 9. 开工前必须拍板的四件事

### 9.1 版本名与发布锚点

- 现状:最新版本分支 = `KH_V1_1_4_propSys`(道具系统);本工作线 = `proto-time-map`(实验名)。
- 建议:大版本号 **v1.2.0(时间维度)**(理由:不是 1.1.x 的补丁级,而是新增一条玩法轴;
  若要延续补丁序列则叫 `KH_V1_1_5_time`,语义上偏差)。
- 锚点分支命令(待批准后执行,**版本名分支永久保留、任何清理都不得删除**):

```bash
git branch KH_v1_2_0_time proto-time-map    # 版本锚点(建议)
git switch -c time-dimension                # 日常开发线(可选,避免直接压锚点)
```

### 9.2 三条版本线的收敛(工程事实,必须先决定策略)

| 线 | HEAD | 与本线关系 |
|---|---|---|
| `proto-time-map`(本线) | `c77146d` | 含 editor 线(砍刀/道具槽 81~84/日志工具)+ 时间垂直切片 |
| `editor_log` | `6b0f920` | **只多 4 个文档提交**(GDD v0.2/v0.3);`merge-base` = `1050aee` |
| `KH_V1_1_4_propSys` | `2a1d866` | 与 editor 线在 `8879054` 分叉(149 文件差异),道具槽位另行重排为 11/12/13 |

→ 建议:① 先把 `editor_log` 的设计文档并入本线(本轮已把 GDD v0.3 落到 `docs/design/`),
② 再以**道具卡注册表**为唯一冲突面,把 `propSys` 线的道具实现逐项并入(不要整支 merge,冲突面太大),
③ 收敛完成后再开锚点分支。**在收敛前不要并行改 `weapon_component.WEAPONS` 与 `editor_schema.gd` 槽位白名单。**

### 9.3 其余待定(不阻塞 M1/M2)

1. 时停档位:纯停(0)/ 慢放(0.05)试玩对比。
2. Boss 出现条件:毁灭度阈值 vs 累计回收达标。
3. 灾前结局是否解锁"新游戏+"。
4. 大乱斗是否上"共享世界针竞速"变体(二期)。

---

## 10. 准备清单

**已完成(本轮)**

- [x] GDD v0.3(单钟定稿)落到本分支 `docs/design/time-dimension-gdd.md`
- [x] `TimeParams` / `TimeClock` / `TimeTimeline` 三件套(单钟 + 10ms + 时停 + 事件溯源)
- [x] `TimeWorld` 门面改造(旧 API 零破坏)
- [x] `MazeGenerator` 认 `# cyrm-v4`
- [x] `Tests/time_ledger_probe.gd` 验收探针(**实测 OK**)
- [x] 本方案(施工图)+ `docs/ARCHITECTURE.md` / `AGENTS.md` 登记

**开工前需做**

- [ ] 拍板 §9.1 版本名 + 建锚点分支;拍板 §9.2 收敛策略
- [ ] 进图段错误抓一次原生调用栈(§8.1;注意先排除沙箱日志路径这一路)
- [ ] M1 收尾:表盘 HUD 抽件 + 时停接线 + `RunOptions/Settings` 开关
- [ ] 修过期道具探针(槽 8/9/10/11 → 81~84),为 M5 铺路
- [ ] 重导出 exe 再让制作人 GUI 实测(改代码后必须重导出,`embed_pck=true`)

---

*版本:v1(2026-09-18) · 基线 `proto-time-map` @ `c77146d` · 设计源 GDD v0.3 · 修改请追加变更记录*
