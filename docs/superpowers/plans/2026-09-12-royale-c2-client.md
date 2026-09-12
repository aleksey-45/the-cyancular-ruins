# 大乱斗客户端接入 C2（实施计划 · 迁移批次 5）

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把大乱斗客户端的本地玩家从 `server_rendered`（服务器渲染）换成与 1v1 同一套 C2 客户端预测 + rollback，并把旧的那套代码路径**彻底删掉**，使全项目只剩一条联机链路。

**Architecture:** `scenes/royale_game.gd` 照抄 `scenes/pvp_client.gd` 的 C2 形状（每物理帧 `note_post_step` → `reconcile` → 组包带 `seq` → `note_input`），本地玩家由引擎自步进、`PredictionRollback` 权威锚定重放；`player.gd` 的 `server_rendered` 一族与 `pvp_client` 的 `LOCAL_PREDICTION_ENABLED` 开关整体删除。运行时验收靠一个**真链路探针**：真大厅 + 真 worker + 真 `royale_game` 客户端，用「K 自杀 → 服务器 2s 复活瞬移」这次必然的服务器外部事件确定性地制造分歧，断言 `reconcile` 把它收敛掉。

**Tech Stack:** Godot 4.7.1 标准版（非 mono）、GDScript。测试是 `tests/*.tscn` 场景模式探针（无单测框架），判据一律 grep 末行标记文本。

---

## ★ 执行结果（2026-09-12 收尾时回写）

| 任务 | 状态 | 提交 |
|---|---|---|
| Task 1 立探针（先红） | ✅ 先红如实达成：`royale_game 没有 _rollback 字段` + A① 7 处残留 | `7a42430` |
| Task 2 `royale_game` 接 C2 | ✅ 预期状态精确达成（只剩 A① 红） | `1d1cb05` |
| Task 3 删 §3A/§3B | ✅ 探针 `ALL-OK`；三个 1v1 冒烟全绿；全仓 grep 只剩注释 | `1095727` |
| Task 4 改 `kh_l6_probe` | ✅ `KH L6 PROBE: ALL-OK`（含新判据自检） | `339a329` |
| Task 5 反证与收尾 | ✅ 四条反证全部实跑（见下） | 本笔 |

**四条反证的实测结果**（详表在 spec §10）：

| 反证 | 红了没有 | 红在哪 |
|---|---|---|
| 拿掉 `reconcile()` | ✅ | `rollback=0` + 未收敛 **3623.2px**；c2 仍 `OK`（鉴别力是**针对性**的） |
| 去掉输入包的 `"seq"` | ✅ | 同形（`rollback=0` + 未收敛 5208.8px） |
| 加回 `set_server_rendered` | ✅ | A①（文本级判据） |
| 消费 `round_state.alive` | ✅ | A② |

**★ 计划里被实测推翻的一处预测**：Task 5 Step 2 原本预期"去掉 `seq` → `last_applied=0 < 60`"。
**实测是 364** —— `note_post_step` 用的是客户端自己的 `_prev_sent_seq`，与包里带不带 `seq` **无关**。
缺 seq 是靠"服务器 `_ack_seq` 恒 0 → 永不回滚 → 不收敛"抓到的。断言注释已按实测改正（`tests/royale_c2_watcher.gd`）。

**★ 计划没预见到、执行中修掉的两处探针缺陷**（同一病根：大乱斗「剩余 <2 人即终局」，两端生命周期**互相耦合**）：
1. 裁判一见到某端 FAIL 就 `quit()` → 另一端被带下水（报告只留 `(未完成)`，看不出为什么）。改成**两边都出结果才收工**。
2. 观察者写完结果就退 → 服务器立即终局 → 另一端正在等的 2s 复活**永远不会发生**。改成**两边先各写结果、等到对端也写好再一起退**。

**★ 未解释的观测（登记，不当成已知）**：`rollback_count()` 三次是 2/3/3，**有一次 63**。心跳显示
低值那种是**前载**的（倒地那一刻占 2 次）；63 那次的现场日志被后续运行覆盖，**没有证据**说明它是爆发还是持续。
假设（未验证）：复活落点随机落到斜坡/被挤住 → 逐帧小分歧；或落地时 `_close_enough` 的 `vel` 分量反复不成立。
要 settle 它：跑 N 次取分布 + 把心跳间隔从 5s 降到 1s。

**其他执行期发现**：
- 客户端子进程 stdout 父进程看不到（Windows `CreateProcess` 不继承句柄）→ 已给 spawn 加 `--log-file`，
  并加 5s 心跳；**这两个是当时唯一能归因的手段**，没有它们我只看到"进程没了、结果也没写"。
- 探针退出时偶发一次原生段错误（仓库既有的"游戏世界退役"问题，在结果落盘之后），不影响判据。

---

## ★ 执行前置：本批的裁定记录（2026-09-12，用户）

| 决策点 | 裁定 |
|---|---|
| 运行时验收形态 | **新增专用真链路探针** `tests/royale_c2_probe`（不扩展 `royale_bound_probe` 的观察者，也不做"只源码守卫"） |
| §4.5 L4（相机不放大回滚抖动） | **本批不做**，登记待裁定 —— 理由见下 |
| 探针代跑 | 沿用批次 1 的一次性授权，**由本计划执行者代跑**（项目默认"测试由用户自己跑"） |

**L4 为什么不做（复核时量出来的，写在这里免得下一个人重开）**：§4.5 要给相机加"超出正常单帧位移才限速"，
正常单帧位移的最大值不是 `move_speed`(11.7px) 或 `jump_velocity`(16.7px)，而是**冲刺 1900/60 = 31.7px**
（`PlayerParams.charge_velocity`；空中下冲 `charge_down_velocity` 2000 更是 33.3px）。于是只有两条路：
`max_step > 32px` → §2.1 实测的修正量（中位 2~7px、p95 12~17px）**全都低于它**，等于死代码；
`max_step < 32px` → 冲刺期间镜头持续滞后 = 手感回归。**真机上量不到净收益**，故跳过。
（顺带登记的既有事实：`PlayerParams.cam_lookahead_x/y`、`cam_smooth_x/y`、`cam_deadzone` 是死参数，
`camera_2d.gd` 一个都没用，`CLAUDE.md` 却写着"相机带前瞻/死区"。本批**不顺手接线**，只登记。）

## 依据

- 设计：`docs/superpowers/specs/2026-09-12-royale-c2-migration-design.md` §0（删除边界）、§3A/§3B（删除清单）、
  §4.3（大乱斗接 C2）、§5 批次表（批 5）、§7（风险与已证伪的杠杆）
- 形态参照：`scenes/pvp_client.gd`（1v1 的 C2 客户端，本批的目标形状）
- 断言参照：`tests/kh_l6_probe.gd`（源码级机械扫描仪，含"判据自检"这一道防线）、
  `tests/royale_bound_probe.gd` + `tests/royale_bound_watcher.gd`（真大厅 + 真 worker + 真 `royale_game` 的 harness）

**本批的"做完"长什么样**（一句话）：大乱斗客户端每一物理帧都在做 C2 —— 本地玩家由引擎自步进，
`reconcile()` 把服务器外部事件（复活瞬移 / 受击 / 击杀复位）收敛掉；`player.gd` 里
`server_rendered` 一族**一个字符都不剩**，`pvp_client` 的开关也删了 → 全项目只剩一条联机链路。

## Global Constraints

- Godot 不在 PATH：`"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe"`
- 探针两种跑法按首行区分：`extends SceneTree` → `-s res://tests/<名>.gd`；`extends Node` → `--quit-after <帧数> res://tests/<名>.tscn`。
- **判据必须是 grep 标记文本**，不能只看退出码（`--quit-after` 在中途报错时仍 exit 0 且不打印标记）。
- 本批新增的两个文件都是**场景模式**探针（要 autoload + 真场景），一律 `extends Node`。
- **`royale_c2_probe` 跑前先确认 7777 空闲**（有僵尸 Godot 占着会直接 FAIL）。
- 改完 GDScript 只需重导出，**不要重编模板**（`RELEASE.md` §2.4）。
- 本仓已被抓过四次「验收门假绿」：**每条新断言都必须给出反证并实跑**，反证做不到就说做不到。
- 大乱斗的 C2 **不是从零开始**：它继承的是 1v1 已经跑通的核（`core/prediction_rollback.gd`），
  本批只做**接线 + 删旧路径**，不改控制器。

---

## 文件结构

| 文件 | 职责 | 动作 |
|---|---|---|
| `tests/royale_c2_probe.tscn` / `.gd` | **新建**。探针入口：大厅/裁判进程 + 两个客户端子进程（`--role=c1|c2`），收结果文件 | Create |
| `tests/royale_c2_watcher.gd` | **新建**。客户端子进程里挂 root 的观察者：驱动真大厅 → 换场后读真 `royale_game` 的 C2 状态 + 按 K 自杀 → 断言 | Create |
| `scenes/royale_game.gd` | 大乱斗客户端。接 C2（seq / rollback / 输入锁收口 / 不消费自己那份世界包） | Modify |
| `scenes/player/player.gd` | `server_rendered` 一族整体删除（§3A） | Modify |
| `scenes/pvp_client.gd` | `LOCAL_PREDICTION_ENABLED` 开关与保底分支删除（§3B） | Modify |
| `tests/kh_l6_probe.gd` | 第 2 条按新形状重写；第 5/6 条（开关存在性）删除 | Modify |
| `tests/snapshot_size_probe.gd` | 一行注释漂移（`apply_server_snapshot` 已删） | Modify |

**探针自身的扫描根**：`res://core`、`res://scenes`、`res://server`、`res://ui`、`res://render`
（排除 `tests/` —— 与 `kh_l6_probe` 同例，避免探针自己的负断言文本自伤）。

---

### Task 1: 立探针（先红）

**Files:**
- Create: `tests/royale_c2_probe.tscn`
- Create: `tests/royale_c2_probe.gd`
- Create: `tests/royale_c2_watcher.gd`

**Interfaces:**
- Consumes: 无（本任务只建探针，不改任何生产文件）
- Produces:
  - `tests/royale_c2_watcher.gd` 的字段 `who: String`、`lobby: Node`（由探针赋值）
  - 判据文本 `PROBE: ALL-OK`（裁判进程末行）/ `user://royale_c2_probe_c{1,2}.result`

> ⚠ **本任务只建探针，不改生产文件**。跑起来必须**红** —— 那正是它要证的。

- [ ] **Step 1: 建探针场景**

新建 `tests/royale_c2_probe.tscn`：

```
[gd_scene load_steps=2 format=3]

[ext_resource type="Script" path="res://tests/royale_c2_probe.gd" id="1"]

[node name="RoyaleC2Probe" type="Node"]
script = ExtResource("1")
```

- [ ] **Step 2: 建探针主体 `tests/royale_c2_probe.gd`**

```gdscript
extends Node

# 大乱斗 C2(客户端预测 + 权威锚定重放)的**运行时验收探针**。场景模式(autoload 必须已实例化)。
#
# 跑法:
#   "$GODOT" --headless --path . --quit-after 7200 res://tests/royale_c2_probe.tscn
#   (无参 = 大厅/裁判进程;它自己拉起两个客户端子进程。**跑前先确认 7777 空闲**。)
# 判据:裁判进程末行 `PROBE: ALL-OK` + 两个结果文件都是 OK(不能只看退出码)。
#
# ═══ 为什么需要它(批次 5 的验收线)═══
# 设计 §5 批次 5 的验收是「大乱斗客户端的 rollback_count() 斜率与 1v1 同量级」,而**读数必须来自
# 真链路** —— 只有真大厅 + 真 worker + 真 `royale_game` 客户端才跑得到 reconcile 那一段。
# 光靠源码级扫描(「royale_game.gd 里有没有那几行」)是本仓被抓过四次的「假绿」形态:
# 接线写对了但没生效时,扫描器照样绿。
#
# ═══ 分歧怎么**确定性**地造出来(本探针的关键设计)═══
# C2 的分歧来自「服务器外部事件」——客户端不可预测的那一类。大乱斗里**必然发生**的一次是:
#   c1 按 K 自杀 → 服务器力其所难执行 force_down → 2s 后**复活并瞬移回出生点**。
# 这次瞬移客户端不可预测,于是:
#   · reconcile 正常 → 本地玩家被 restore+重放拉回出生点,与权威快照收敛(断言绿);
#   · reconcile 被删/没接 → 本地玩家永远停在倒地处、永远 downed(断言红)。
# 这就是设计里那条反证「删掉 reconcile() → 分歧不收敛,读数可见」的可执行形式。
#
# 结果文件:user://royale_c2_probe_c{1,2}.result(客户端写)、user://royale_c2_probe_go.txt(房号)。
# 客户端子进程的 stdout 父进程看不到(Windows 不继承句柄)→ 各自落一份 .log,失败时打印。

const RESULT_PREFIX := "royale_c2_probe_"
const GO_FILE := "user://royale_c2_probe_go.txt"
const ORCH_DEADLINE := 90.0

var _role := "lobby"
var _c1_peer := 0
var _code := ""
var _stage := 0
var _created_t := -1.0
var _t := 0.0
var _room_mgr: Node = null


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--role="):
			_role = a.trim_prefix("--role=")
	if _role == "lobby":
		_run_orchestrator()
	else:
		_run_client()


# ── 裁判:起大厅 + 拉起 c1/c2 子进程 + 等两人进房后开局 + 收结果 ──
func _run_orchestrator() -> void:
	var err := NetBus.start_server()
	if err != OK:
		print("PROBE: 大厅监听失败 err=%d(7777 被占?)" % err)
		get_tree().quit(1)
		return
	_room_mgr = RoomManager.new()
	add_child(_room_mgr)
	for f in ["c1", "c2"]:
		var p := "user://%s%s.result" % [RESULT_PREFIX, f]
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(p))
	if FileAccess.file_exists(GO_FILE):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(GO_FILE))
	NetBusExt.royale_create_requested.connect(_on_room_created)
	var exe := OS.get_executable_path()
	for role in ["c1", "c2"]:
		OS.create_process(exe, PackedStringArray(["--headless", "--path",
				ProjectSettings.globalize_path("res://"), "res://tests/royale_c2_probe.tscn",
				"--", "--role=" + role]))
	print("PROBE: 大厅就绪,c1/c2 已拉起")


func _on_room_created(caller: int, _opts: Dictionary) -> void:
	# 真大厅建完房:记下房主 peer 与房号,稍后(帧内不做事,避免在 poll 栈里改房态)
	_c1_peer = caller
	for code in _rm().royale_rooms:
		var rr = _rm().royale_rooms[code]
		if rr.host_peer == caller:
			_code = code
			break
	_created_t = _t


func _process(delta: float) -> void:
	if _role != "lobby":
		return
	_t += delta
	if _t > ORCH_DEADLINE:
		print("PROBE: 超时(%.0fs)FAIL c1=%s c2=%s\n%s" % [ORCH_DEADLINE, _read_result("c1"),
				_read_result("c2"), _client_logs()])
		get_tree().quit(1)
		return
	match _stage:
		0:
			if _created_t < 0.0 or _t - _created_t < 0.3:
				return
			var f := FileAccess.open(GO_FILE, FileAccess.WRITE)
			f.store_string(_code)
			f.close()
			print("PROBE: 房 %s 已建(c1 peer=%d),等 c2 进房" % [_code, _c1_peer])
			_stage = 1
		1:
			if _room_players() < 2:
				return   # 等 c2 加入(ROYALE_MIN_PLAYERS=2)
			_rm().royale_start(_c1_peer)   # 等价于房主点「开始游戏」→ 拉起 worker
			print("PROBE: 房内 2 人,已发起开局(拉起 worker 子进程)")
			_stage = 2
		2:
			var r1: String = _read_result("c1")
			var r2: String = _read_result("c2")
			if r1.begins_with("FAIL") or r2.begins_with("FAIL"):
				print("PROBE: FAIL\n  c1: %s\n  c2: %s\n%s" % [r1, r2, _client_logs()])
				get_tree().quit(1)
				return
			if r1.begins_with("OK") and r2.begins_with("OK"):
				print("PROBE: ALL-OK\n  c1: %s\n  c2: %s" % [r1, r2])
				get_tree().quit(0)
				return


func _rm() -> Node:
	return _room_mgr


func _room_players() -> int:
	var rr = _rm().royale_rooms.get(_code)
	return rr.players.size() if rr != null else 0


func _read_result(who: String) -> String:
	var p := "user://%s%s.result" % [RESULT_PREFIX, who]
	if not FileAccess.file_exists(p):
		return "(未完成)"
	var f := FileAccess.open(p, FileAccess.READ)
	return f.get_as_text().strip_edges() if f != null else "(读取失败)"


# 客户端子进程的 stdout 父进程看不到(Windows 不继承句柄)→ 读它们落盘的日志并打出来
func _client_logs() -> String:
	var out := ""
	for who in ["c1", "c2"]:
		var p := "user://%s%s.log" % [RESULT_PREFIX, who]
		if not FileAccess.file_exists(p):
			out += "  [%s 无日志]\n" % who
			continue
		var f := FileAccess.open(p, FileAccess.READ)
		out += "  [%s 日志]\n%s\n" % [who, f.get_as_text().strip_edges() if f != null else "(读取失败)"]
	return out


# ── 客户端子进程:挂观察者 + 挂**真大厅场景**,再把它驱动起来 ──
# 观察者挂 root(不是探针场景里):真大厅 → 真 royale_game 的那次换场不会把它带走。
func _run_client() -> void:
	var lp := "user://%s%s.log" % [RESULT_PREFIX, _role]
	if FileAccess.file_exists(lp):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(lp))
	var watcher: Node = load("res://tests/royale_c2_watcher.gd").new()
	watcher.who = _role
	watcher.lobby = load("res://scenes/royale_lobby.tscn").instantiate()
	# 本节点还在自己的 _ready 里(父级 root 正忙于装载子节点)→ 两处 add_child 都得推迟到帧末
	get_tree().root.add_child.call_deferred(watcher)
	add_child.call_deferred(watcher.lobby)
	print("PROBE[%s]: 真大厅场景已挂载,等待连接 127.0.0.1" % _role)
```

- [ ] **Step 3: 建观察者 `tests/royale_c2_watcher.gd`**

```gdscript
extends Node

# 大乱斗 C2 探针的**观察者**(客户端子进程用;见 royale_c2_probe.gd 文件头)。
# 挂在 get_tree().root 上:换场(真 royale_lobby → 真 royale_game)不会把它带走 →
# 它能在**换场之后**读真 royale_game 实例的 C2 状态。
#
# 三段流程:
#   0/1  驱动真大厅(建房 / 加入房间),等换场到真 royale_game;
#   2    等对局进 PLAYING → c1 按一次 K(自杀脱困,走游戏自己的 _unhandled_input);
#   3/4  等「自己倒地」→ 等「自己复活」(服务器 2s 后复活并瞬移回出生点 —— 这次瞬移
#        客户端不可预测,正是要 reconcile 去收敛的那次服务器外部事件);
#   5    静置 SETTLE 秒后断言。
#
# 断言分两组:
# ── B 组 · 运行时(读**生产对象**的真状态):
#   · _rollback 存在,且 last_applied() ≥ MIN_LAST_APPLIED  —— 接线在推进(seq 与 note_post_step 都通了)
#   · c1:rollback_count() ≥ 1                              —— 复活那次外部事件确实触发了回滚
#   · 本地玩家与**权威快照**收敛:位置 ≤ POS_TOL 且倒地态一致  —— reconcile 真的在收敛(删掉即红)
#   · c1:观察到「倒地 → 复活」这条链走完
# ── A 组 · 源码级(生产目录零残留 + 一条禁区):
#   · 不存在 server_rendered / apply_server_snapshot / LOCAL_PREDICTION_ENABLED(设计 §0「彻底删干净」)
#   · royale_game 不得消费 round_state 的 `alive` —— 理由见 _check_no_alive_consume
#
# ★ 关于「K 自杀是不是广播的」——A 组第 2 条就是为了回答它:
#   · **请求**不广播:`NetBusExt.rpc_id(1, "suicide_request")` 定向发给 worker,无回执;
#   · **"谁死了/谁活着"确实广播**:倒地边沿 → `_broadcast_round_state()`,载荷带 `alive`({role: bool})
#     与 `deaths` —— 客户端读得到,今天唯一消费者是排行榜(scenes/royale_hud.gd)。
#   · 但 C2 下**不许**把它接去写本地玩家(第二条权威入口 + 并不更快),见断言的理由。
#   本探针的鉴别力正依赖这一点:若消费了 alive,删掉 reconcile 后本地玩家仍会被 alive 拉成"活着"，
#   那条"分歧不收敛"的反证就失去信号。

const RESULT_PREFIX := "royale_c2_probe_"
const GO_FILE := "user://royale_c2_probe_go.txt"
const DEADLINE := 75.0
const SETTLE := 1.5              # 复活后静置(等 reconcile 收敛;快照 60Hz,1.5s 绰绰有余)
const MIN_LAST_APPLIED := 60     # 接线在推进的下限(换场到断言约 6s ≈ 360 tick,留 6 倍余量)
const POS_TOL := 100.0           # 收敛判据(px):快照滞后一 tick ≈ 11.7px,100 留足余量

# ── A 组:源码级(与运行时读数无关,但两支一起跑省一次进程)──
# 判据一律取**去注释视图**(注释不是代码:一句"这里以前调过 set_server_rendered"的注释既不能
# 让"在位"类断言变绿,也不能让"零残留"类断言变红)。
const RG := "res://scenes/" + "royale" + "_game.gd"
const PROD_DIRS := ["res://core", "res://scenes", "res://server", "res://ui", "res://render"]
const MIN_PROD_FILES := 40   # 扫到的源文件数下限:防"扫描坏了 → 零命中 = 假绿"
# 碎片拼接(与 kh_l6_probe 同一条纪律):别让针的字面量在自扫时自伤。
const N_SSR := "set_server" + "_rendered"
const N_LOCAL_PRED := "LOCAL_PREDICTION" + "_ENABLED"
const N_APPLY_SNAP := "apply_server" + "_snapshot("

var who := "c1"
var lobby: Node = null           # 真 royale_lobby.tscn 实例(本进程里被驱动的那份)

var _t := 0.0
var _stage := 0
var _stage_t := 0.0
var _game: Node = null           # 换场后的真 royale_game 实例
var _own_snap: Dictionary = {}   # 最新世界包里**自己**那一份(服务器权威渲染字段)
var _round_state := -1
var _saw_downed := false
var _respawned := false
var _logged_once: Dictionary = {}


func _ready() -> void:
	_log("观察者就绪(role=%s);真大厅实例=%s" % [who, str(lobby != null)])
	# 世界包里**自己**那一份 = 服务器权威(canonical pos / downed / hp)。C2 下客户端不再消费它,
	# 但作为**判据的地面真值**它正好:拿它和本地玩家的实际状态比,就知道收敛没收敛。
	NetBus.local_snapshot_world.connect(func(snap: Dictionary) -> void:
		var players_snap: Dictionary = snap.get("players", {})
		var me: Dictionary = players_snap.get(str(PvpSession.role), {})
		if not me.is_empty():
			_own_snap = me)
	NetBus.local_round_state.connect(func(data: Dictionary) -> void:
		_round_state = int(data.get("state", -1)))


# 子进程的 stdout 不会被父进程继承(Windows CreateProcess 不继承句柄)→ 落盘一份,
# 父进程在失败/超时时把它打出来,否则客户端子进程里发生了什么完全看不见。
func _log(msg: String) -> void:
	print("PROBE[%s]: %s" % [who, msg])
	var p := "user://%s%s.log" % [RESULT_PREFIX, who]
	# READ_WRITE 不会创建文件(文件不存在时 open 直接返回 null)→ 首次落盘用 WRITE 建出来
	var mode := FileAccess.READ_WRITE if FileAccess.file_exists(p) else FileAccess.WRITE
	var f := FileAccess.open(p, mode)
	if f != null:
		f.seek_end()
		f.store_line("%5.1fs %s" % [_t, msg])
		f.close()


func _log_once(msg: String) -> void:
	if _logged_once.has(msg):
		return
	_logged_once[msg] = true
	_log(msg)


func _process(delta: float) -> void:
	_t += delta
	if _t > DEADLINE:
		_finish(false, "超时(阶段 %d;当前场景=%s)" % [_stage,
				str(get_tree().current_scene.name) if get_tree().current_scene != null else "(空)"])
		return
	_stage_t += delta
	match _stage:
		0:
			_stage_lobby()
		1:
			_stage_wait_game()
		2:
			_stage_playing()
		3:
			_stage_wait_downed()
		4:
			_stage_wait_respawn()
		5:
			if _stage_t >= SETTLE:
				_assert()


# ── 阶段 0:等真大厅连上大厅服 → c1 建房 / c2 等 GO 文件后加入 ──
func _stage_lobby() -> void:
	if lobby == null or not is_instance_valid(lobby):
		_log_once("等真大厅实例挂上(add_child 被推迟到帧末)")
		return
	if not bool(lobby.get("_connected")):
		_log_once("等大厅连接(_connected=false)")
		return   # 真大厅面板自己会连 127.0.0.1(_ready 里的 _request_list)
	if who == "c1":
		_log("大厅已连,建房")
		lobby.call("_on_create_pressed")   # 等价于点「创建房间」(公开房,人数上限默认 4)
		_stage = 1
		_stage_t = 0.0
		return
	if not FileAccess.file_exists(GO_FILE):
		return
	var f := FileAccess.open(GO_FILE, FileAccess.READ)
	var code: String = f.get_as_text().strip_edges() if f != null else ""
	if f != null:
		f.close()
	if code.is_empty():
		return
	_log("用房间号 %s 加入" % code)
	lobby.call("_join_room", code, "")   # 等价于点房间列表里的房间(公开房,邀请码空)
	_stage = 1
	_stage_t = 0.0


# ── 阶段 1:等换场(真大厅 → 真 royale_game)──
func _stage_wait_game() -> void:
	var cs := get_tree().current_scene
	if cs == null or not _is_royale_game(cs):
		_log_once("等换场(当前场景=%s)" % ("(空)" if cs == null else str(cs.name)))
		return
	_game = cs
	_log("已换场到 royale_game(帧 %d)" % Engine.get_process_frames())
	_stage = 2
	_stage_t = 0.0


# ── 阶段 2:等 PLAYING(COUNTDOWN 3s;自杀只允许在对局进行中)──
func _stage_playing() -> void:
	if _game == null or not is_instance_valid(_game):
		_finish(false, "royale_game 实例失效")
		return
	if _game.get("_rollback") == null:
		# 接线没上 → 不必等 PLAYING:这一条本身就是本批要找的红。顺带把 A 组也跑掉 ——
		# "先红"那一步一次就能看到**全部**缺什么,而不是挤牙膏。
		var early: Array = ["royale_game 没有 _rollback 字段(C2 没接线)"]
		_check_residue(early)
		_check_no_alive_consume(early)
		_finish(false, " | ".join(early))
		return
	if _round_state != 1:
		_log_once("等 PLAYING(当前 round_state=%d)" % _round_state)
		return
	if who != "c1":
		_log("c2:对局已进入 PLAYING,只做接线与收敛断言(不自杀)")
		_stage = 5
		_stage_t = 0.0
		return
	# ★ 走**游戏自己的** K 键路径(不直接发 RPC):顺带把「_unhandled_input 的 K 分支还在」也验了。
	var ev := InputEventKey.new()
	ev.pressed = true
	ev.physical_keycode = KEY_K
	_game.call("_unhandled_input", ev)
	_log("c1:已按 K 请求自杀脱困(等服务器 2s 复活 + 瞬移回出生点)")
	_stage = 3
	_stage_t = 0.0


# ── 阶段 3:等自己倒地(证明自杀真的送达了服务器)──
func _stage_wait_downed() -> void:
	if bool(_own_snap.get("downed", false)):
		_saw_downed = true
		_log("c1:权威快照已显示自己倒地")
		_stage = 4
		_stage_t = 0.0
		return
	if _stage_t > 5.0:
		_finish(false, "按 K 后 5s 内权威快照仍是 downed=false(自杀没送达?)")
		return
	_log_once("c1:等权威快照显示 downed=true")


# ── 阶段 4:等自己复活(服务器 2s 复活并瞬移回出生点 = 客户端不可预测的那次外部事件)──
func _stage_wait_respawn() -> void:
	if bool(_own_snap.get("downed", true)):
		_log_once("c1:等复活(服务器 RESPAWN_DELAY=2s + 瞬移回出生点)")
		return
	_respawned = true
	_log("c1:权威快照已显示复活 → 静置 %.1fs 等 reconcile 收敛" % SETTLE)
	_stage = 5
	_stage_t = 0.0


func _is_royale_game(n: Node) -> bool:
	var s = n.get_script()
	return s != null and str(s.resource_path).ends_with("royale_game.gd")


# ── 阶段 5:断言(A 组源码级 + B 组运行时)──
func _assert() -> void:
	var problems: Array = []
	_check_residue(problems)
	_check_no_alive_consume(problems)
	var rb = _game.get("_rollback")
	if rb == null:
		problems.append("royale_game 没有 _rollback(C2 没接线)")
	else:
		var la: int = int(rb.last_applied())
		if la < MIN_LAST_APPLIED:
			problems.append("last_applied=%d < %d(seq 或 note_post_step 没接上 → 预测整态没进 ring)"
					% [la, MIN_LAST_APPLIED])
		if who == "c1":
			var rc: int = int(rb.rollback_count())
			if rc < 1:
				problems.append("rollback_count=0(复活瞬移这次服务器外部事件没触发回滚 → reconcile 没在跑)")
	var local: Node2D = _game.get("_local")
	if local == null or not is_instance_valid(local):
		problems.append("拿不到本地玩家(场景没建好?)")
	elif _own_snap.is_empty():
		problems.append("没收到含自己那份的世界包(判据的地面真值缺失)")
	else:
		var d: float = MazeGenerator.toroidal_delta_px(local.global_position,
				_own_snap.get("pos", local.global_position),
				GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT).length()
		if d > POS_TOL:
			problems.append("本地玩家与权威快照**未收敛**:相差 %.1f px > %.0f(reconcile 没把分歧拉回)"
					% [d, POS_TOL])
		var snap_downed := bool(_own_snap.get("downed", false))
		if snap_downed != local.is_downed():
			problems.append("倒地态与权威不一致:快照 downed=%s,本地 %s(reconcile 没把复活拉回来)"
					% [str(snap_downed), str(local.is_downed())])
		if who == "c1" and not _respawned:
			problems.append("没观察到「倒地 → 复活」这条链走完(_saw_downed=%s)" % str(_saw_downed))
	var rb_txt := "无" if rb == null else "last_applied=%d rollback=%d" % [
			int(rb.last_applied()), int(rb.rollback_count())]
	var detail := "role=%d %s round_state=%d 收敛读数=%s %s" % [PvpSession.role, rb_txt, _round_state,
			"n/a" if local == null else "本地=%s 权威=%s" % [str(local.global_position),
			str(_own_snap.get("pos", Vector2.ZERO))], "" if problems.is_empty() else " | " + "; ".join(problems)]
	_finish(problems.is_empty(), detail)


# ══ A 组 · 源码级 ═══════════════════════════════════════════════════

# ── A①:生产目录零残留 ──
# 设计 §0 的删除裁定是「**彻底删干净**:终态只有一套联机模型」。这三样是旧路径的全部构件:
#   server_rendered / set_server_rendered / apply_server_snapshot —— 服务器渲染一族(§3A)
#   LOCAL_PREDICTION_ENABLED —— 1v1 那条"翻个常量就回落"的双路开关(§3B)
# 残留**不一定报错**:"字段还在但没人用"完全是静默的,而它正是"还有第二套模型"的存在形式。
# 故做成无条件判据。★ 反证已实跑:在 royale_game 里加回一行 set_server_rendered → 红。
func _check_residue(problems: Array) -> void:
	var files := _scan_prod()
	if files.size() < MIN_PROD_FILES:
		problems.append("源码扫描只扫到 %d 个文件(<%d)→ 零命中不可信(扫描坏了?)" % [
				files.size(), MIN_PROD_FILES])
		return
	var hits := 0
	for needle in [N_SSR, N_LOCAL_PRED, N_APPLY_SNAP]:
		for path in files:
			if str(files[path]).contains(needle):
				hits += 1
				problems.append("生产目录残留旧路径构件 `%s`:%s(设计 §0 要求彻底删干净)" % [needle, path])
	_log("A①:扫了 %d 个生产源文件,零残留 %s" % [files.size(), "✓" if hits == 0 else "✗(%d 处)" % hits])


# ── A②:不得消费 round_state 的 `alive`(一条**禁区**,理由见下)──
# 服务器在倒地边沿会广播 round_state,载荷里带 `alive`({role: bool})—— 也就是说"你死了/
# 你活了"这件事**是广播的**,客户端读得到(今天唯一消费者是排行榜 scenes/royale_hud.gd)。
# ★ C2 下**不许**把它接去写本地玩家,两条理由:
#   ① 那是**第二条权威入口**:C2 的纪律是权威状态只经 on_authoritative → restore_state + 重放
#      进来。绕过它的"顺手补上"正是被删掉的那条旧路径的写法,会重新引入橡皮筋;
#   ② 它**并不更快** —— 同样是服务器往返广播,只是换了条通道(反过来说:它连"更快"这个
#      唯一可能的理由都没有)。
# 本探针的**鉴别力也依赖这条**:若消费了 alive,删掉 reconcile 后本地玩家仍会被 alive 拉成
# "活着" → 那条"分歧不收敛"的反证就失去信号。
# 判据取**全文零出现**这个键。若日后真要在 royale_game 里用 alive 做别的事(观战/结算),
# 把判据改成"不得写进 _local"的形态并同步改本注释 —— 别直接删掉这条门。
func _check_no_alive_consume(problems: Array) -> void:
	var code := _code_view(_read(RG))
	if code.contains("\"alive\""):
		problems.append("royale_game.gd 里出现了 round_state 的 \"alive\" 键(C2 下不许接它写本地玩家,理由见 tests/royale_c2_watcher.gd 的 _check_no_alive_consume)")
	else:
		_log("A②:royale_game 未消费 round_state 的 alive ✓")


# ── 源码扫描的小工具(与 kh_l6_probe 同源,砍到够用为止)──
func _read(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	return f.get_as_text() if f != null else ""


# 去注释视图:丢掉纯注释行,**保留缩进**(结构类判据靠缩进定块)
func _code_view(src: String) -> String:
	var out: Array[String] = []
	for raw in src.split("\n"):
		var s := _strip_line_comment(raw)
		if s.strip_edges().is_empty():
			continue
		out.append(s.rstrip(" \t"))
	return "\n".join(out)


# 删掉一行里字符串字面量之外的 `#` 起、到行尾的注释
func _strip_line_comment(line: String) -> String:
	var quote := ""
	var j := 0
	while j < line.length():
		var ch := line[j]
		if quote != "":
			if ch == "\\":
				j += 1
			elif ch == quote:
				quote = ""
		elif ch == "\"" or ch == "'":
			quote = ch
		elif ch == "#":
			return line.substr(0, j)
		j += 1
	return line


# 生产目录下全部 .gd 的**去注释**源码 {path: code}
func _scan_prod() -> Dictionary:
	var out := {}
	var stack: Array[String] = []
	for d in PROD_DIRS:
		stack.append(d)
	while not stack.is_empty():
		var dir_path: String = stack.pop_back()
		var da := DirAccess.open(dir_path)
		if da == null:
			continue
		da.list_dir_begin()
		var n := da.get_next()
		while n != "":
			if da.current_is_dir():
				if not n.begins_with("."):
					stack.append(dir_path + "/" + n)
			elif n.ends_with(".gd"):
				out[dir_path + "/" + n] = _code_view(_read(dir_path + "/" + n))
			n = da.get_next()
		da.list_dir_end()
	return out


func _finish(ok: bool, msg: String) -> void:
	_log(("OK " if ok else "FAIL ") + msg)
	var f := FileAccess.open("user://%s%s.result" % [RESULT_PREFIX, who], FileAccess.WRITE)
	if f != null:
		f.store_string(("OK " if ok else "FAIL ") + msg)
		f.close()
	get_tree().quit(0 if ok else 1)
```

- [ ] **Step 4: 跑探针，确认它失败**

Run（**先确认 7777 空闲**）：
```
"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . --quit-after 7200 res://tests/royale_c2_probe.tscn
```
Expected: `PROBE: FAIL`，两个客户端结果文件都是
`FAIL royale_game 没有 _rollback 字段(C2 没接线) | 生产目录残留旧路径构件 set_server_rendered:res://scenes/player/player.gd | … apply_server_snapshot:… | … LOCAL_PREDICTION_ENABLED:res://scenes/pvp_client.gd`。
（A① 这时会列出好几处 —— 那些正是 Task 3 要删的。A② 应当已经是 ✓。）
（若卡在"等换场"或"超时"而不是拿到 FAIL —— 那说明探针自身的 harness 有问题，先修探针。
**探针跑不通 ≠ 生产代码有问题**，这两件事在报告里必须分开写。）

- [ ] **Step 5: 提交**

```bash
git add tests/royale_c2_probe.tscn tests/royale_c2_probe.gd tests/royale_c2_watcher.gd
git commit -m "test(royale): 大乱斗 C2 真链路探针(先红)——自杀→复活瞬移确定性造分歧,断言 reconcile 收敛"
```

---

### Task 2: `royale_game.gd` 接入 C2（§4.3）

**Files:**
- Modify: `scenes/royale_game.gd`（字段区 / `_ready` / `_physics_process` / `_on_snapshot_world` / 新增 `_on_snapshot_own` / 输入锁收口）

**Interfaces:**
- Consumes: `PredictionRollback`（`bind(p)` / `map_px` / `note_post_step(seq, capture)` / `reconcile()` / `note_input(seq, pkt)` / `on_authoritative(ack, c2)`）—— 全部已存在，本批不改控制器
- Produces: `royale_game._rollback`（探针 Task 1 读它）；`royale_game._refresh_input_lock()`

> 本任务做完**探针不会整体转绿** —— A① （生产目录零残留）还有 `player.gd` / `pvp_client.gd` 那几处，
> 要等 Task 3 删。**预期状态：只剩 A① 的红**，A② 与整个 B 组必须全绿。
> 若还有别的红（尤其 `last_applied < 60`、`rollback_count=0`、"未收敛"、"倒地态与权威不一致"），
> 那是**真问题**，别往下走。

- [ ] **Step 1: 字段区加 C2 状态**

`scenes/royale_game.gd` 的 `var _ping_acc := 0.0` 一行之后加：

```gdscript
# ── C2 客户端预测(与 pvp_client 同一套;见 docs/superpowers/specs/2026-09-12-royale-c2-migration-design.md)──
# 本地玩家由引擎自步进(读真实 Input,aim/手感=单机);本场景每物理帧在它步进前
# note_post_step + reconcile,把服务器外部事件(复活瞬移/受击/击杀复位)收敛掉。
var _rollback = null            # PredictionRollback
var _input_seq := 0             # 本地每物理帧单调的输入序号(服务器 1/tick 消费并回带 ack)
var _have_prev_seq := false
var _prev_sent_seq := 0
var _menu_open := false         # ESC 菜单是否开着(PvP 下菜单不暂停树,靠这个锁输入)
```

- [ ] **Step 2: `_ready` 里换掉 `set_server_rendered`**

把（原第 44-50 行）：

```gdscript
	# 与对手(层2)物理碰撞:服务器侧 match_host 已给每个玩家 mask |= 2。大乱斗客户端本地玩家
	# 目前是服务器渲染(不走物理),这一位今天不产生行为;留着是为了①与 1v1 同款不留分叉,
	# ②大乱斗接 C2 时(PvpSession.royale 那批)本地预测立刻就有对手身体信息,不用再补。
	local.collision_mask |= 2
	_local = local
	if _local.has_method("set_server_rendered"):
		_local.set_server_rendered(true)
```

改为：

```gdscript
	# 与对手(层2)物理碰撞:服务器侧 match_host 已给每个玩家 mask |= 2,客户端本地玩家也必须,
	# 否则本地预测直接穿过对手副本、服务器却挡住 → 每帧分歧回滚(C2 的无限回滚循环)。
	# 对手那一侧由 player_replica 的幽灵碰撞体提供(层2)。**不改 Player.tscn**:那会让
	# enemy_logic_smoke 的「player mask == 5」断言变红,且单机不需要这一位。
	local.collision_mask |= 2
	_local = local
	# C2:本地玩家跑预测(engine 自步进),控制器绑定;权威从本人包的 ack_seq/c2 喂入。
	# ★ 这里**不再 set_server_rendered** —— 服务器渲染那条路径已整体删除(§0「彻底删干净」),
	#   全项目只剩一条联机链路。
	_rollback = PredictionRollback.new()
	_rollback.bind(_local)
	# 环面尺寸:分歧判定要用它取最短向量,否则跨接缝那一帧客户端与服务器相差一整幅地图宽
	# 会被误判成分歧、白跑一次回滚(见 PredictionRollback._pos_dist)。**不设 = 静默惰性**:
	# 不报错,只是那修复不生效 —— 故 tests/rollback_fidelity_probe 有源码守卫钉这一行。
	_rollback.map_px = Vector2(GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
```

- [ ] **Step 3: `_ready` 里订阅本人包**

把（原第 55-59 行）：

```gdscript
	# 快照/事件消费
	# 快照**拆两条**(2026-09-12):世界包=全部玩家的渲染字段(本场景要的都在里面);
	# 本人包=自己的 ack+c2(本场景暂不接 —— 大乱斗还没接 C2 预测,本地玩家是服务器渲染;
	# 接 C2 那批会用它喂 PredictionRollback,见 docs/superpowers/specs/...-design.md §4.3)。
	NetBus.local_snapshot_world.connect(_on_snapshot_world)
```

改为：

```gdscript
	# 快照/事件消费
	# 快照**拆两条**(2026-09-12):①世界包=全部玩家的渲染字段(副本/HUD 取它);
	# ②本人包=自己的 ack_seq + c2(**只有本人需要**,C2 rollback 拿它锚定/重放)。
	NetBus.local_snapshot_world.connect(_on_snapshot_world)
	NetBus.local_snapshot_own.connect(_on_snapshot_own)
```

- [ ] **Step 4: `_ready` 里补 PauseMenu 的 toggled 接线**

把（原第 85-86 行）：

```gdscript
	_pause_menu = PauseMenu.new(true)
	add_child(_pause_menu)
```

改为：

```gdscript
	_pause_menu = PauseMenu.new(true)
	# 本地输入锁必须宿主接线:PvP 不暂停树,不锁就是"菜单开着还能边跑边开枪"。
	# 被 set_server_rendered 掩盖过一整个阶段 —— 服务器渲染下本地玩家本就不走输入物理,
	# 接 C2 后不补就是真的能边跑边开枪。
	_pause_menu.toggled.connect(func(open: bool) -> void:
		_menu_open = open
		_refresh_input_lock())
	add_child(_pause_menu)
```

- [ ] **Step 5: `_physics_process` 顶部加 C2 帧块 + 输入包带 seq + note_input**

把（原第 125-132 行）：

```gdscript
func _physics_process(_delta: float) -> void:
	if _local == null:
		return
	_ping_acc += _delta
	if _ping_acc >= 0.5:
		_ping_acc = 0.0
		NetBus.send_ping()
	var src: InputSource = _local.input_source
```

改为：

```gdscript
func _physics_process(_delta: float) -> void:
	if _local == null:
		return
	_ping_acc += _delta
	if _ping_acc >= 0.5:
		_ping_acc = 0.0
		NetBus.send_ping()
	# C2:玩家由引擎自步进(读真实 Input)。这里在它本帧步进前——先把上一 seq 的预测整态入 ring,
	# 再 reconcile 到期权威(分歧 → restore+重放重对齐)。顺序:先记预测态,reconcile 才比得上 ring[C]。
	if _rollback != null:
		if _have_prev_seq:
			_rollback.note_post_step(_prev_sent_seq, _local.capture_state())
			_rollback.reconcile()
	var src: InputSource = _local.input_source
```

再把（原第 162-170 行）：

```gdscript
	var aim: Vector2 = _local.get_current_aim_dir()
	var pkt := {
		"ax": src.get_axis("left", "right"),
```

改为：

```gdscript
	var aim: Vector2 = _local.get_current_aim_dir()
	_input_seq += 1
	var pkt := {
		"seq": _input_seq,   # 单调输入序号(服务器按序消费并回带 ack,rollback 用)
		"ax": src.get_axis("left", "right"),
```

再把（原第 172-175 行）：

```gdscript
	var net_slot: int = _local.weapons.consume_net_slot()
	if net_slot > 0:
		pkt["weapon"] = net_slot
	NetBus.rpc_id(1, "send_input", pkt)
```

改为：

```gdscript
	var net_slot: int = _local.weapons.consume_net_slot()
	if net_slot > 0:
		pkt["weapon"] = net_slot
	NetBus.rpc_id(1, "send_input", pkt)
	_prev_sent_seq = _input_seq
	_have_prev_seq = true
	if _rollback != null:
		_rollback.note_input(_input_seq, pkt)   # 供回滚重放使用
```

- [ ] **Step 6: `_on_snapshot_world` 不再消费自己那一份**

把（原第 185-198 行）：

```gdscript
	for role_str in players_snap:
		var role := int(role_str)
		var data: Dictionary = players_snap[role_str]
		if role == PvpSession.role:
			if _local.has_method("apply_server_snapshot"):
				_local.apply_server_snapshot(data)
		else:
			_ensure_replica(role)
			var r: Node2D = _replicas[role]
			if r != null and r.has_method("apply_snapshot"):
				r.apply_snapshot(data, _local.global_position, snap_tick)
				if _hp_bars.has(role):
					_hp_bars[role].ratio = float(data.get("hp", PlayerParams.player_max_hp)) \
							/ float(PlayerParams.player_max_hp)
```

改为：

```gdscript
	for role_str in players_snap:
		var role := int(role_str)
		var data: Dictionary = players_snap[role_str]
		if role != PvpSession.role:
			_ensure_replica(role)
			var r: Node2D = _replicas[role]
			if r != null and r.has_method("apply_snapshot"):
				r.apply_snapshot(data, _local.global_position, snap_tick)
				if _hp_bars.has(role):
					_hp_bars[role].ratio = float(data.get("hp", PlayerParams.player_max_hp)) \
							/ float(PlayerParams.player_max_hp)
		# ★ 自己那一份**刻意不消费**:C2 下本地玩家由引擎自步进,权威整态走**本人包**
		#   (见 _on_snapshot_own)。把世界包里自己那份写进玩家 = "每帧把权威位置强写进正在预测的
		#   玩家" = 橡皮筋 —— 那正是被删掉的那条旧路径的写法。别顺手补回来。
```

- [ ] **Step 7: 新增 `_on_snapshot_own`**

在 `_on_snapshot_world` 之后、`_ensure_replica` 之前插入：

```gdscript
# 本人包:只有自己需要的 ack_seq + 权威整态 c2。C2 下喂 rollback 控制器。
# 拆包的一个附带好处:它与世界包**互不连累** —— c2 丢只少一个回滚锚点(下一个快照补上),
# 世界包丢只让副本插值冻结一帧。
func _on_snapshot_own(own: Dictionary) -> void:
	if _rollback == null:
		return
	var c2: Dictionary = own.get("c2", {})
	if not c2.is_empty():
		_rollback.on_authoritative(int(own.get("ack_seq", 0)), c2)

```

- [ ] **Step 8: 输入锁收口（`_refresh_input_lock`）**

把（原第 347-372 行）整个 `_on_round_state` 改为：

```gdscript
func _on_round_state(data: Dictionary) -> void:
	var state := int(data.get("state", 0))
	_round_locked = state == 0
	if state == 3 and not _match_ended:   # MATCH_OVER → 展示结果 6s 后回主菜单
		_match_ended = true
		# ★ ESC 菜单随即失效、退出只走定时器这一条路(与 pvp_client 同款):
		#   不销毁菜单的话,玩家能在这 6s 里按 ESC → 回到主菜单(safe_change_scene 已经切过一次),
		#   6s 到点本定时器会**再切一次场景** —— 把刚建出来的主菜单当 old 退役、并 free 掉
		#   _retired 里原本那具游戏世界。后果不致命但结构上是错的,而 pvp_client 正是为此
		#   专门加了这两行(见该文件 MATCH_OVER 分支的注释),大乱斗这条是第三条路径、当年漏了。
		if _pause_menu != null and is_instance_valid(_pause_menu):
			_pause_menu.queue_free()
			_pause_menu = null
		_menu_open = false
		# 捕获 tree/autoload 引用:玩家若已从别的路径离开,本节点会被 safe_change_scene 摘出树,
		# 到点时对不在树上的实例求值会出错(自检 L6)
		var tree := get_tree()
		var netbus := NetBus
		get_tree().create_timer(6.0).timeout.connect(func() -> void:
			netbus.stop()
			if not is_inside_tree():
				return   # 已从别的退出路径离开 → 不再叠加第二次换场
			Level0.safe_change_scene(tree, "res://scenes/main_menu.tscn"))
	_refresh_input_lock()   # 单一收口:三个维度任一成立即锁(见函数定义)


# 本地输入锁的单一收口:冻结期(_round_locked)/ 菜单打开(_menu_open)/ 结算(_match_ended)
# 任一成立就锁。**不要在各调用点各拼一次布尔** —— 那正是"修复波 1 只关住一个方向"的成因。
# ★ 与 pvp_client._refresh_input_lock 的差别:这里多一个 _match_ended —— 大乱斗在 MATCH_OVER
#   要锁住结算画面(自检 L6:原还能跑动开枪),而 pvp_client 的 MATCH_OVER 不锁(它靠别的方式收场)。
func _refresh_input_lock() -> void:
	if _local != null and _local.has_method("set_controls_locked"):
		_local.set_controls_locked(_round_locked or _menu_open or _match_ended)
```

> 注意 `_match_ended` 那个维度是**保持大乱斗既有行为**用的（旧代码在 state==3 分支里显式
> `set_controls_locked(true)`）。删掉它 = 结算画面又能跑动开枪，那是自检 L6 修过的回归。

- [ ] **Step 9: 跑探针**

Run（**先确认 7777 空闲**）：
```
"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . --quit-after 7200 res://tests/royale_c2_probe.tscn
```
Expected: `PROBE: FAIL`，但两个客户端的失败原因**只剩** A①（生产目录零残留，Task 3 的活）。
**其余全部要绿**，尤其结果串里 `last_applied` 要 ≥ 60、c1 的 `rollback ≥ 1`、且没有"未收敛"字样。

- [ ] **Step 10: 提交**

```bash
git add scenes/royale_game.gd
git commit -m "feat(royale): 大乱斗客户端接入 C2(本地预测 + 权威锚定重放)"
```

---

### Task 3: 删掉旧路径（§3A + §3B）

**Files:**
- Modify: `scenes/player/player.gd`
- Modify: `scenes/pvp_client.gd`
- Modify: `tests/snapshot_size_probe.gd`（一行注释漂移）

**Interfaces:**
- Consumes: Task 2 之后，`royale_game.gd` 已不再调用 `set_server_rendered` / `apply_server_snapshot`
- Produces: 全仓（生产目录）零 `server_rendered` / 零 `apply_server_snapshot` / 零 `LOCAL_PREDICTION_ENABLED`

- [ ] **Step 1: 删 `player.gd` 的服务器渲染一族（§3A）**

删掉**整块**（原第 125-136 行，含注释头）：

```gdscript
# ── PvP 服务器渲染模式:本地玩家不跑移动物理,位置/姿态/朝向由 30Hz 快照驱动 ──
# 根因:C2(客户端预测)对梯子等"边沿+位置敏感"机制与服务器权威模拟打架 → 大量回拉。
# 根治:本地玩家完全由快照驱动(与远端副本同款最短路径插值),只保留武器/瞄准/受击反馈。
var server_rendered: bool = false
var _server_target := Vector2.ZERO   # 服务器 canonical 位置(本地玩家恒在中间副本)
var _server_have_target := false
var _server_pose: int = 0            # Pose 枚举值,见 POSE_ANIM
var _server_facing: int = 1
const SERVER_INTERP_RATE := 30.0     # 紧跟踪服务器位置(60Hz 快照下滞后约 1 帧;接缝不爬行)

func set_server_rendered(enabled: bool) -> void:
	server_rendered = enabled
```

把 `_controls_locked` 的注释（原第 138-141 行）：

```gdscript
# PvP COUNTDOWN/局间冻结:锁住本地玩家输入——武器开火查询 + (C2 预测下)移动。
# 服务器渲染路径:本地玩家不跑物理,锁开火即可,移动本就由快照跟随;
# C2 预测路径(engine 自步进读真实输入):只锁开火不够——必须把输入源一并冻结,
# 否则本地预测在服务器权威冻结的倒计时里照常移动,PLAYING 起 ack 跳变 → 大 rollback。
```

改为：

```gdscript
# PvP COUNTDOWN/局间冻结:锁住本地玩家输入——武器开火查询 + 移动。
# C2 预测路径(engine 自步进读真实输入):只锁开火不够——必须把输入源一并冻结,
# 否则本地预测在服务器权威冻结的倒计时里照常移动,PLAYING 起 ack 跳变 → 大 rollback。
```

删掉 `apply_server_snapshot` 整块（原第 148-163 行）—— **逐字**是：

```gdscript
# PvP 客户端每帧喂服务器快照:存目标/姿态/朝向 + 权威采纳血量/防水/倒地。
func apply_server_snapshot(data: Dictionary) -> void:
	_server_target = data.get("pos", _server_target)
	_server_have_target = true
	_server_pose = int(data.get("pose", _server_pose))
	_server_facing = int(data.get("facing", facing_direction))
	velocity = data.get("vel", velocity)   # 供 water_fx 等读速度做视觉
	# 武器槽位以服务器权威为准(本地切枪已在 _update_server_rendered 即时反馈,这里防脱同步)
	var wslot := int(data.get("weapon", 0))
	if wslot > 0 and wslot != weapons.current_slot_int():
		weapons.equip(str(wslot))
	var hp := int(data.get("hp", self.hp))
	var wp := int(data.get("waterproof", waterproof))
	var downed := bool(data.get("downed", combat.is_downed()))
	if hp != self.hp or wp != waterproof or downed != combat.is_downed():
		apply_authoritative_state(hp, wp, downed)
```

> 与它相邻的 `_controls_locked` / `set_controls_locked`(原 142-146 行)**保留** —— 两个客户端都还在用。

把 `_physics_process` 顶部（原第 182-185 行）：

```gdscript
func _physics_process(delta: float) -> void:
	if server_rendered:
		_update_server_rendered(delta)
		return
	if combat.is_downed():
```

改为：

```gdscript
func _physics_process(delta: float) -> void:
	if combat.is_downed():
```

删掉 `_update_server_rendered` 整块（原第 522-543 行）—— **逐字**是：

```gdscript
# PvP 服务器渲染:位置最短路径插值 + 姿态/朝向由快照驱动(不跑本地物理,服务器权威)。
func _update_server_rendered(delta: float) -> void:
	weapons.tick(delta)   # 服务器渲染模式仍需本地武器节奏(视觉开火/预瞄),同样走物理 tick
	combat.update_iframe_blink(delta)   # 受击无敌闪烁仍本地播放
	# 切枪:服务器渲染模式跳过移动路径里的切枪轮询,这里补(本地即时反馈;服务器从输入包同切)。
	var wslot := input_source.get_weapon_slot_pressed()
	if wslot > 0:
		weapons.equip(str(wslot))
	if not _server_have_target:
		return
	# 当前 canonical 位置 → 服务器 canonical 位置的最短向量,指数插值(跨接缝连续)
	var d := MazeGenerator.toroidal_delta_px(global_position, _server_target,
			GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
	global_position += d * (1.0 - exp(-SERVER_INTERP_RATE * delta))
	# 回中间副本:插值可能跨接缝进入邻副本,取模回 canonical(本地玩家恒在中间副本)
	global_position = MazeGenerator.wrap_to_range(global_position,
			GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
	# 朝向 + 姿态动画(倒地由 combat 停动画/转体,这里不覆盖)
	facing_direction = 1 if _server_facing >= 0 else -1
	animator.flip_h = facing_direction < 0
	if not combat.is_downed():
		animator.play(POSE_ANIM[clampi(_server_pose, Pose.STAND, Pose.SQUAT)])
```

> 它下面紧邻的 `cancel_jump_state()`(原 545 行起)**保留** —— 那是攀爬组件在用的,与服务器渲染无关。

- [ ] **Step 2: 删 `pvp_client.gd` 的双路开关（§3B）**

把文件头（原第 7-15 行）：

```gdscript
# ── 本地玩家渲染:完全由服务器快照驱动(放弃客户端预测) ──
# 根因:C2(客户端预测)对梯子等"边沿+位置敏感"机制与服务器权威模拟打架 → 大量回拉。
# 根治:本地玩家不再本地跑移动物理,位置/姿态/朝向由快照插值(与远端副本同款),
#      只保留鼠标瞄准/开火/受击反馈等本地视觉。服务器是唯一真相,天然无回拉。
#
# C2(客户端预测 rollback)开关:true=本地玩家跑本地预测 + PredictionRollback 权威锚定重放;
# false=回落上面这条服务器渲染路径(保底)。复盘见 docs/pvp-c2-retrospective.md(P1-P7)。
# 2026-09-06 使能:服务器 FIFO/ack 已落地、控制器 + reconcile/twin 冒烟全绿、COUNTDOWN 冻结已补。
const LOCAL_PREDICTION_ENABLED := true
var _input_seq := 0   # 本地每物理帧单调的输入序号(服务器 1/tick 消费并回带 ack)
var _last_snap_tick := 0
# C2(开关开):本地玩家跑全量本地 sim 预测 + PredictionRollback 权威锚定重放(见 core/prediction_rollback.gd)。
# 变体 B:不 set_server_rendered、引擎照常自步进(读真实 Input,aim/手感=单机);
# 本客户端每帧在玩家步进前 reconcile,并把每 tick 的预测整态/输入记录喂给控制器。
var _rollback = null
```

改为：

```gdscript
# ── C2 客户端预测 ──
# 本地玩家跑全量本地 sim 预测 + PredictionRollback 权威锚定重放(见 core/prediction_rollback.gd)。
# 引擎照常自步进(读真实 Input,aim/手感=单机);本客户端每帧在玩家步进前 reconcile,
# 并把每 tick 的预测整态/输入记录喂给控制器。复盘见 docs/pvp-c2-retrospective.md(P1-P7)。
#
# ★ 2026-09-12(批次 5):原来那个 LOCAL_PREDICTION_ENABLED 开关与它的 server_rendered 保底分支
#   **已整体删除** —— 全项目只剩这一条联机链路,没有第二套代码路径可回退。大乱斗客户端走同一套。
var _input_seq := 0   # 本地每物理帧单调的输入序号(服务器 1/tick 消费并回带 ack)
var _last_snap_tick := 0
var _rollback = null
```

把 `_ready` 里（原第 68-80 行）：

```gdscript
	# 本地玩家改由服务器快照驱动(不做客户端预测):根治梯子等机制"预测 vs 权威"打架回拉。
	# C2(阶段4)开启后:本地玩家跑全量本地 sim 预测,由 pvp_client 接 rollback。
	if not LOCAL_PREDICTION_ENABLED and _local.has_method("set_server_rendered"):
		_local.set_server_rendered(true)
	elif LOCAL_PREDICTION_ENABLED:
		# C2:本地玩家跑预测(engine 自步进),控制器绑定;权威从快照 ack_seq/c2 喂入。
		if _rollback == null:
			_rollback = PredictionRollback.new()
		_rollback.bind(_local)
		# 环面尺寸:分歧判定要用它取最短向量,否则跨接缝那一帧客户端与服务器相差一整幅地图宽
		# 会被误判成分歧、白跑一次回滚(见 PredictionRollback._pos_dist)。**不设 = 静默惰性**:
		# 不报错,只是那修复不生效 —— 故 tests/rollback_fidelity_probe 有源码守卫钉这一行。
		_rollback.map_px = Vector2(GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
```

改为：

```gdscript
	# C2:本地玩家跑预测(engine 自步进),控制器绑定;权威从本人包的 ack_seq/c2 喂入。
	_rollback = PredictionRollback.new()
	_rollback.bind(_local)
	# 环面尺寸:分歧判定要用它取最短向量,否则跨接缝那一帧客户端与服务器相差一整幅地图宽
	# 会被误判成分歧、白跑一次回滚(见 PredictionRollback._pos_dist)。**不设 = 静默惰性**:
	# 不报错,只是那修复不生效 —— 故 tests/rollback_fidelity_probe 有源码守卫钉这一行。
	_rollback.map_px = Vector2(GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
```

把 `_physics_process` 里（原第 191-194 行）：

```gdscript
	if LOCAL_PREDICTION_ENABLED and _rollback != null:
		if _have_prev_seq:
```

改为：

```gdscript
	if _rollback != null:
		if _have_prev_seq:
```

把（原第 244-245 行）：

```gdscript
	if LOCAL_PREDICTION_ENABLED and _rollback != null:
		_rollback.note_input(_input_seq, pkt)   # 供回滚重放使用
```

改为：

```gdscript
	if _rollback != null:
		_rollback.note_input(_input_seq, pkt)   # 供回滚重放使用
```

把 `_on_snapshot_world` 里（原第 256-266 行）：

```gdscript
	var players_snap: Dictionary = world["players"]
	var me: Dictionary = players_snap.get(str(PvpSession.role), {})
	if LOCAL_PREDICTION_ENABLED or me.is_empty():
		pass   # C2:本地玩家自步进(权威整态走**本人包**,见 _on_snapshot_own);空 = 本帧没有我的数据
	else:
		_apply_local_state(me)
	var opp_role := 3 - PvpSession.role
```

改为：

```gdscript
	var players_snap: Dictionary = world["players"]
	# ★ 自己那一份**刻意不消费**:C2 下本地玩家自步进,权威整态走**本人包**(见 _on_snapshot_own)。
	#   把世界包里自己那份写进玩家 = 每帧把权威位置强写进正在预测的玩家 = 橡皮筋。
	var opp_role := 3 - PvpSession.role
```

把 `_on_snapshot_own` 里（原第 282-286 行）：

```gdscript
func _on_snapshot_own(own: Dictionary) -> void:
	if LOCAL_PREDICTION_ENABLED and _rollback != null:
		var c2: Dictionary = own.get("c2", {})
		if not c2.is_empty():
			_rollback.on_authoritative(int(own.get("ack_seq", 0)), c2)
```

改为：

```gdscript
func _on_snapshot_own(own: Dictionary) -> void:
	if _rollback == null:
		return
	var c2: Dictionary = own.get("c2", {})
	if not c2.is_empty():
		_rollback.on_authoritative(int(own.get("ack_seq", 0)), c2)
```

删掉 `_apply_local_state` 整块（原第 289-294 行）：

```gdscript
# 本地玩家完全由服务器快照驱动:权威状态直接采纳,位置/姿态/朝向由 player 插值渲染。
func _apply_local_state(data: Dictionary) -> void:
	if _local == null:
		return
	if _local.has_method("apply_server_snapshot"):
		_local.apply_server_snapshot(data)
```

- [ ] **Step 3: 修 `snapshot_size_probe.gd` 的漂移注释**

`tests/snapshot_size_probe.gd:109` 那句：

```gdscript
# 唯一消费 vel 的是 player.apply_server_snapshot —— 那条路在 C2 迁移里删除,故世界包不必再带。
```

改为：

```gdscript
# 唯一消费 vel 的是 player.apply_server_snapshot —— 那条路已在 C2 迁移(批次 5,2026-09-12)删除,
# 故世界包不必再带 vel。
```

- [ ] **Step 4: 全仓 grep 确认删干净**

Run:
```bash
grep -rn "server_rendered\|apply_server_snapshot\|LOCAL_PREDICTION_ENABLED\|_apply_local_state" core/ scenes/ server/ ui/ render/ maps/ 2>/dev/null
```
Expected: 只剩**注释里**提到这些名字的几行（说明"这里删过什么"是合法的文档，本仓有先例：
`core/pvp_session.gd` 就有一整段讲被删掉的 `pending_*` 交接）。**一条代码行都不许剩。**
真正的门是探针的 A① —— 它走**去注释视图**，注释既不能喂绿也不能判红。所以：
逐条看过每一处命中都确实是注释，然后靠 Step 6 的探针转绿来收口。

⚠ 这条 grep **不是**判据（它会命中注释）；它只是给人看的快速核对。`tests/` 不在此列
—— `kh_l6_probe` 里还有引用，Task 4 处理。

- [ ] **Step 5: headless 启动确认无脚本错误**

Run:
```
"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . --quit-after 90
```
Expected: 无 `SCRIPT ERROR` / `Invalid access` / `Parse Error`。

- [ ] **Step 6: 跑探针 → 应整体转绿**

Run（**先确认 7777 空闲**）：
```
"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . --quit-after 7200 res://tests/royale_c2_probe.tscn
```
Expected: `PROBE: ALL-OK`，两个结果文件都是 `OK ...`。

- [ ] **Step 7: 跑 1v1 的三个 PvP 冒烟（硬门：绿变红即停）**

Run:
```bash
bash tests/pvp_reconcile_smoke.sh
bash tests/pvp_twin_smoke.sh
bash tests/pvp_match_smoke.sh
```
Expected: `SMOKE_RECONCILE OK` / `SMOKE_TWIN OK` / `SMOKE_MATCH OK`。

- [ ] **Step 8: 提交**

```bash
git add scenes/player/player.gd scenes/pvp_client.gd tests/snapshot_size_probe.gd
git commit -m "refactor(net): 删掉服务器渲染一族与本地预测开关 —— 全项目只剩一条联机链路"
```

---

### Task 4: 改 `kh_l6_probe` 的两条断言（§3H 的一半）

**Files:**
- Modify: `tests/kh_l6_probe.gd`

**Interfaces:**
- Consumes: Task 3 的删除结果
- Produces: 无（探针内部）

> **为什么在本批做**（设计把它排在批次 6）：Task 3 一落地，`kh_l6_probe` 的第 5、6 条就会**变红**
> —— 它们钉的正是被删掉的那个开关。留着红门 = 分不清"真坏了"和"已删除"。所以本批顺手改掉。
> §3D（`NetBusExt` 的 `local_beam_fired` 重复 RPC）、`kh_l5_probe` 第 1 条、`royale_soak_probe` 的
> 边界说明、`CLAUDE.md` 回写仍归**批次 6**。

- [ ] **Step 1: 重写第 2 条（`_check_snapshot_authoritative`）**

把整个函数（原第 192-235 行，含注释头）替换为：

```gdscript
# ── 2) 快照两条包的分工:世界包不得碰本端,本人包必须喂控制器(B6)──
# 本端快照只有一条合法去向:**本人包** → `on_authoritative(ack, c2)`(由控制器在下一帧
# reconcile 时**按分歧**收敛)。世界包里自己那一份**不得**被写进玩家 —— 那是"服务器渲染"
# 的写法,C2 下等于每帧把权威位置强写进正在预测的玩家 = 每帧橡皮筋。
# ★ 2026-09-12(批次 5):`server_rendered` 保底路径已删除,故旧判据里的
#   「`_apply_local_state` 必须落在 else 分支里」整体作废(那个方法与那条分支都没了)。
#   语义没变,只是判据从"被 else 挡住"变成"**根本不存在**" —— 后者更强,且不依赖缩进上溯
#   (那个辅助函数在深层嵌套上不稳,拆包时实测误报过一次)。
func _check_snapshot_authoritative() -> void:
	var before := _failures.size()
	var world := _func_body(_pc_code, "_on_snapshot_world")
	var own := _func_body(_pc_code, "_on_snapshot_own")
	_check(not world.is_empty(), "取不到 _on_snapshot_world 的函数体(改名/挪走了?)")
	_check(not own.is_empty(), "取不到 _on_snapshot_own 的函数体(改名/挪走了?)")
	if world.is_empty() or own.is_empty():
		_summary(before, "快照两条包:取不到 handler")
		return
	_check(not world.contains(N_APPLY_SNAP),
			"世界包里出现了 `%s`(把自己那份写进玩家 = C2 下每帧橡皮筋;那条保底路径已删除)" % N_APPLY_SNAP)
	_check(not world.contains(N_APPLY_LOCAL),
			"世界包里出现了 `%s`(同上的旧形态;该方法已随批次 5 删除)" % N_APPLY_LOCAL)
	_check(own.contains(N_ON_AUTH),
			"本人包 handler 里没有 `%s`(C2 拿不到权威锚点 → reconcile 永不收敛)" % N_ON_AUTH)
	_summary(before, "快照两条包:世界包不碰本端 / 本人包 → %s" % N_ON_AUTH)
```

并在常量区（`N_APPLY_LOCAL` 那行附近）补一个常量：

```gdscript
const N_APPLY_SNAP := "apply_server" + "_snapshot("
```

> ⚠ `_check_snapshot_authoritative` 原先在**原文**（带注释）上找 `_apply_local_state` 的调用行。
> 新判据改成在**去注释视图**上找（`_func_body` 收到的就是去注释的 `_pc_code`）—— 这样
> "把旧写法**注释掉**留着当说明"不会被判红，符合"注释不是代码"这条本仓纪律。

- [ ] **Step 2: 删掉第 5、6 条与它们的辅助**

删除这些整块：
- `_check_prediction_switch()`（原第 327-365 行，含注释头）
- `_check_server_rendered_guarded()`（原第 368-390 行，含注释头）
- `_self_test_guard_helper()`（原第 393-407 行，含注释头）
- `_ready()` 里的 `_check_prediction_switch()` 与 `_check_server_rendered_guarded()` 两行调用
- 常量 `N_PRED`、`N_SSR`、`N_SSR_NAME`、`RE_CONST_PRED`（删完上面几块后全仓应再无引用；
  **必须确认 `_guarded_calls` 也不再被引用** —— 它是第 6 条的专用辅助，一并删除）

- [ ] **Step 3: 更新文件头的不变量清单**

把文件头（原第 30-36 行）里那三行：

```gdscript
#   2  快照本端分支喂 on_authoritative,且 _apply_local_state 不是无条件到达
#                                —— B6:C2 全断 + 权威位置强写进正在预测的玩家 = 橡皮筋
...
#   5  LOCAL_PREDICTION_ENABLED 常量 + _ready 两条分支 —— B1/B2:保底不再是"翻一个常量"
#   6  set_server_rendered(true) 必须受预测开关守卫 —— B2:无条件即 C2 死
```

改为：

```gdscript
#   2  快照两条包的分工:世界包**不得**写本端玩家,本人包必须喂 on_authoritative
#                                —— B6:C2 全断 + 权威位置强写进正在预测的玩家 = 橡皮筋
#                                (2026-09-12 批次 5 重写:保底路径删除后,判据从"被 else 挡住"
#                                 变成"根本不存在";更强的形式)
...
#   5  ~~LOCAL_PREDICTION_ENABLED 常量 + _ready 两条分支~~ 已随批次 5 删除
#   6  ~~set_server_rendered(true) 必须受预测开关守卫~~ 已随批次 5 删除
#      (两条钉的是"保底路径的存在形式",而那条路径本身已被删除 —— 留着就是一台永远红/永远绿的门。
#       接替它们的是 tests/royale_c2_probe 的"全仓零 server_rendered"断言,那条是**无条件**的。)
```

> **第 1 条与第 3/4 条不动**：它们钉的是 `pvp_client` 的 `seq` / `note_post_step` / `reconcile` / `note_input`
> —— 那些**本来就是目标形状**，本批一个字没改（Task 3 只删了开关与保底分支）。别顺手"统一"到
> `royale_game` 上：`royale_game` 的同款接线由 `tests/royale_c2_probe` 的运行时断言覆盖（`last_applied ≥ 60`），
> 且 `kh_l6_probe` 的扫描对象常量 `PC` 只指 `pvp_client.gd`。
> `_find_line_re` **保留**（第 7 条与第 15 条还在用）；只有 `RE_CONST_PRED` 随第 5 条一起失效。

- [ ] **Step 4: 跑 `kh_l6_probe`**

Run:
```
"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . --quit-after 600 res://tests/kh_l6_probe.tscn
```
Expected: 末行 `KH L6 PROBE: ALL-OK`。

- [ ] **Step 5: 反证（必须实跑）**

把 `scenes/pvp_client.gd` 的 `_on_snapshot_own` 里 `_rollback.on_authoritative(...)` 一行临时注释掉，
重跑 `kh_l6_probe`。Expected: `✗ 本人包 handler 里没有 ...` → `FAIL`。**改回来。**

再把 `_on_snapshot_world` 里临时加一行 `_local.apply_server_snapshot(players_snap.get(str(PvpSession.role), {}))`……
**做不到** —— `apply_server_snapshot` 已在 Task 3 删除，这行会直接报编译错，反证无法用"真加回旧写法"做。
改用等价形式：临时加一行 `var _x := players_snap` 之外的东西不可行，故本条的负向证据改为
**判据自检**：在探针里喂一段合成源给同一个判据函数。为此把该条拆出可测的纯函数：

```gdscript
# 判据自检(本仓纪律:每条新断言都要能回答「什么错误改动仍会通过」)——
# 合成源里**故意**放一句世界包写本端玩家的调用,判据必须认出来。
func _self_test_snapshot_judge() -> void:
	var before := _failures.size()
	var bad := "func _on_snapshot_world(w: Dictionary) -> void:\n\t" + N_APPLY_SNAP + "\n"
	_check(_func_body(bad, "_on_snapshot_world").contains(N_APPLY_SNAP),
			"判据自检失败:合成源里的 `%s` 判据认不出来(判据恒绿,不能用)" % N_APPLY_SNAP)
	_summary(before, "判据自检:世界包写本端的合成源能被认出来")
```

在 `_check_snapshot_authoritative()` 末尾调用 `_self_test_snapshot_judge()`，
并**实跑一次**确认它绿（若它红，说明判据确实是恒绿的，停下来修判据）。

- [ ] **Step 6: 提交**

```bash
git add tests/kh_l6_probe.gd
git commit -m "test(L6): 快照两条包的判据按删除后的形状重写;删掉两条只服务旧开关的断言"
```

---

### Task 5: 全批反证与收尾

**Files:**
- Modify: `docs/superpowers/specs/2026-09-12-royale-c2-migration-design.md`（回写本批结果）
- Modify: `docs/superpowers/plans/2026-09-12-royale-c2-client.md`（回写执行结果）

- [ ] **Step 1: 反证一 —— 删掉 `reconcile()` 必须红**

把 `scenes/royale_game.gd` 的 `_physics_process` 里 `_rollback.reconcile()` 一行临时注释掉，重跑：
```
"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . --quit-after 7200 res://tests/royale_c2_probe.tscn
```
Expected: `PROBE: FAIL`，c1 的失败串里出现 `rollback_count=0` **且** `未收敛` / `倒地态与权威不一致`。
**改回来。**

- [ ] **Step 2: 反证二 —— 输入包去掉 `seq` 必须红**

把 `scenes/royale_game.gd` 组包里的 `"seq": _input_seq,` 一行临时删掉，重跑同一命令。
Expected: `PROBE: FAIL`，c1/c2 的失败串里出现 `last_applied=0 < 60`。**改回来。**

- [ ] **Step 3: 反证三 —— 旧路径构件回到生产目录必须红（证 A① 不是恒绿）**

在 `scenes/royale_game.gd` 的 `_ready` 里临时加回一行：

```gdscript
	if _local.has_method("set_server_rendered"):
		_local.set_server_rendered(true)
```

重跑探针那条命令。Expected: `PROBE: FAIL`，串里出现
`生产目录残留旧路径构件 set_server_rendered:res://scenes/royale_game.gd`。**改回来。**
先用 `grep` 复核一次也行（Task 3 Step 4 那条命令），两条应当同红。

> **如实登记这条反证的边界**：`set_server_rendered` 已从 `player.gd` 删除，所以这行加回去**运行时是空操作**
> （`has_method` 为 false），A① 仍然红 —— 说明 A① 是**文本级**判据，它证的是"旧路径的**文字**回到了代码里"，
> 不覆盖"接错线但文本对"。后一条由 B 组的运行时断言（`last_applied` / `rollback` / 收敛）覆盖。

- [ ] **Step 4: 反证四 —— 消费 `round_state.alive` 必须红（证 A② 不是恒绿）**

在 `scenes/royale_game.gd` 的 `_on_round_state` 里临时加一行：

```gdscript
	var _probe_alive: Dictionary = data.get("alive", {})
```

重跑探针。Expected: `PROBE: FAIL`，串里出现
``royale_game.gd 里出现了 round_state 的 "alive" 键``。**改回来。**
（这一条同时是"K 自杀是广播的、但 C2 下不许消费它"这条结论的**可执行记录** —— 见探针文件头。）

- [ ] **Step 5: 全量回归**

Run:
```bash
bash tests/pvp_reconcile_smoke.sh
bash tests/pvp_twin_smoke.sh
bash tests/pvp_match_smoke.sh
```
以及（按需、跑前确认 7777 空闲）：
```
"D:/.../Godot_v4.7.1-stable_win64_console.exe" --headless --path . --quit-after 7200 res://tests/royale_c2_probe.tscn
"D:/.../Godot_v4.7.1-stable_win64_console.exe" --headless --path . --quit-after 600 res://tests/kh_l6_probe.tscn
"D:/.../Godot_v4.7.1-stable_win64_console.exe" --headless --path . --quit-after 600 res://tests/kh_l5_probe.tscn
"D:/.../Godot_v4.7.1-stable_win64_console.exe" --headless --path . -s res://tests/enemy_logic_smoke.gd
```
Expected: 全部打印各自的 OK 标记。

- [ ] **Step 6: 回写 `CLAUDE.md` 里那两处"服务器渲染"的说法**

`CLAUDE.md` 现在写的是**已被删除**的机制（"**本地玩家走 `set_server_rendered(true)`——这是**临时方案**（规格 D2）**"），
留着它等于让下一个 agent 按不存在的代码推理。本批必须先把它改对（其余文档回写仍归批次 6）：

1. §网络与 PvP 的「客户端流程」段里，`pvp_game` 那句保持；把大乱斗客户端那句的
   「**本地玩家走 `set_server_rendered(true)`——这是**临时方案**（规格 D2）…**」
   改成「**本地玩家走与 1v1 同一套 C2 客户端预测 + `PredictionRollback`（批次 5，2026-09-12）；
   旧的 `server_rendered` 一族与 `LOCAL_PREDICTION_ENABLED` 开关已整体删除，全项目只剩一条联机链路**」。
2. §网络与 PvP 的「保底路径（开关关掉即回落）」那一整段 → **删除**（那条路径不存在了）。
3. §网络与 PvP 开头那句「1v1 保留 C2 客户端预测；大乱斗**临时**走 `server_rendered`」的同类表述 → 改为「1v1 与大乱斗同走 C2」。
4. §测试 段补一句：`tests/royale_c2_probe` 是大乱斗 C2 的真链路探针（真大厅 + 真 worker + 真
   `royale_game` 客户端；用 K 自杀 → 服务器复活瞬移确定性制造分歧，断言 `reconcile` 收敛）。

- [ ] **Step 7: 回写本计划与设计文档**

- 在**本文件**文首加「执行结果」表（Task 1~5 状态 + 每条反证的实测结论）。
- 在 `docs/superpowers/specs/2026-09-12-royale-c2-migration-design.md`：
  - §5 批次表把「批 5」标 ✅ 并注明 L4 未做（附 §0 裁定记录里的理由）；
  - §8「不做」补一条：**L4 未做**，理由是 `max_step` 必须 >32px（冲刺 31.7px/帧）而实测修正量 2~17px 全在其下；
  - §6/§7 的 L4 行改为「已分析，不实装」；
  - 新增一节记录本批探针的读数（`last_applied` / `rollback_count` / 收敛偏差）。

- [ ] **Step 8: 提交**

```bash
git add CLAUDE.md docs/superpowers/specs/2026-09-12-royale-c2-migration-design.md docs/superpowers/plans/2026-09-12-royale-c2-client.md
git commit -m "docs(plans/spec/CLAUDE): 批次 5 落地记录(大乱斗接 C2 + 删旧路径),L4 登记为不做"
```

---

## 收官（交给用户的事）

- [ ] **真机联调（用户）**：开一局大乱斗,贴着打 + 自杀复活,看有没有可见抖动/回拉。
  headless 量不到观感，这是唯一能判"C2 手感 vs 原来的服务器渲染"的途径。
- [ ] **批次 6**（另开）：删 §3D（`NetBusExt` 的 `local_beam_fired` 重复 RPC）、改 `kh_l5_probe` 第 1 条
  （`_broadcast_snapshot` 的 `"ack_seq"`/`"c2"` 要跟着拆包后的形状改）、改 `royale_soak_probe` 第 21-23 行的
  「大乱斗输入包不带 seq」边界说明（已不成立）、`docs/pvp-c2-retrospective.md` 补一节「大乱斗接入」
  （`CLAUDE.md` 已在本批 Task 5 改掉，不必等批次 6 —— 那里写的是**已被删除**的机制）。

## 本批不做的（别顺手做）

- **不做 L4**（相机限速）—— 用户 2026-09-12 裁定，理由见文首。
- **不接** `PlayerParams` 的 `cam_lookahead_x/y`、`cam_smooth_x/y`、`cam_deadzone` 那组死参数
  （手感改动，需另行裁定；本批只登记）。
- **不做世界包瘦身 / 降频**（设计 §8 已定：读数留档）。
- **不改 `core/prediction_rollback.gd`** —— 本批只接线，不动控制器。`mag_ammo` / `_reloading` 不入
  `capture_state` 也不是缺口（设计 §4.3 已核实：PvP 两端 `reload_active()` 恒 false）。
- **不动 AI 补位**（D13 不变）。
- **不顺手清 KH 大乱斗其余小毛病** —— 随替换自然消失。
- **不动 `pvp_client` 的 C2 行为** —— 它已经是目标形状，本批只删它的开关与保底分支。
</content>
</invoke>
