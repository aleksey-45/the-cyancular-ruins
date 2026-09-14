extends Node

# MatchHost 记账卫生探针(场景模式):钉"服务器侧那些只增不减的表"。
# 跑法:
#   "$GODOT" --headless --path . res://tests/match_host_hygiene_probe.tscn
# 期望:每条 [hyg] … 通过,末行 "MATCH_HOST HYGIENE PROBE: ALL-OK"。
#
# 存在理由:`_seen_bullets`(子弹 instance_id → 只广播一次)原先只在
# `_reset_world_and_clear_dynamics()`(换局复位)里清 —— 而**大乱斗没有换局**,那个函数永不调用
# → 整局只增不减(每颗子弹一条 int→bool)。量不大,但那是"记住了一个再也不会读的 id";
# 现在的实现每帧按在场子弹剪枝(见 `_adjudicate_bullets` 的 `_seen_bullets = live`)。
#
# 做法:真建一个 MatchHost(真地图 + 真碰撞),但 **role_peers 传空** —— 不建玩家、不排 peer,
# 所有 `rpc_id` 都无对象(广播静默早退,不会在无多人连接时尝试发包)。子弹自己摆。
#
# ⚠ 判据 grep 文本 "MATCH_HOST HYGIENE PROBE: ALL-OK"(不只看退出码)。

const MAP := "res://maps/factory1v1.cyrm"
const BASE_BULLETS := 3
const CHURN := 60        # 反复生成/销毁的轮数:旧实现会把条目数累积到 BASE + CHURN

var _failures: Array[String] = []
var _host: Node = null
var _bullets: Array = []


func _check(ok: bool, msg: String) -> void:
	if ok:
		print("[hyg]   ✓ %s" % msg)
	else:
		_failures.append(msg)
		print("[hyg]   ✗ %s" % msg)


func _ready() -> void:
	_host = MatchHost.new(MAP, {})   # 空 role_peers:不建玩家、不排 peer
	add_child(_host)
	_host.set_physics_process(false)   # 关掉服务器每帧编排,只手动调被测函数
	for i in range(BASE_BULLETS):
		_bullets.append(_make_bullet(Vector2(120.0 + i * 40.0, 120.0)))

	_test_counts_live_bullets()
	_test_prunes_after_free()
	_test_bounded_under_churn()

	if _failures.is_empty():
		print("MATCH_HOST HYGIENE PROBE: ALL-OK")
		get_tree().quit(0)
	else:
		print("MATCH_HOST HYGIENE PROBE: FAIL %s" % str(_failures))
		get_tree().quit(1)


# ① 在场几颗就记几条,重复裁决不重复记账
func _test_counts_live_bullets() -> void:
	_host._adjudicate_bullets()
	_check(_host._seen_bullets.size() == BASE_BULLETS,
			"首次裁决:条目数 = 在场子弹数(%d)" % _host._seen_bullets.size())
	_host._adjudicate_bullets()
	_host._adjudicate_bullets()
	_check(_host._seen_bullets.size() == BASE_BULLETS,
			"重复裁决不重复记账(仍 %d 条)" % _host._seen_bullets.size())
	var ids := []
	for b in _bullets:
		ids.append(b.get_instance_id())
	var all_seen := true
	for id in ids:
		if not _host._seen_bullets.has(id):
			all_seen = false
	_check(all_seen, "记的正是那几颗在场子弹的 id")


# ② 子弹销毁后条目要被剪掉(不是等换局才清)
func _test_prunes_after_free() -> void:
	var gone = _bullets.pop_back()
	var gone_id: int = gone.get_instance_id()
	gone.free()   # 立即释放:当帧就离开 bullet 组
	_host._adjudicate_bullets()
	_check(not _host._seen_bullets.has(gone_id),
			"已销毁子弹的条目被剪掉(旧实现要等到换局复位才清)")
	_check(_host._seen_bullets.size() == _bullets.size(),
			"条目数跟着在场数走(%d == %d)" % [_host._seen_bullets.size(), _bullets.size()])


# ③ ★ 真正的回归判据:反复生成/销毁不会累积(旧实现会线性涨到 BASE + CHURN)
func _test_bounded_under_churn() -> void:
	for i in range(CHURN):
		var t = _make_bullet(Vector2(400.0 + (i % 20) * 30.0, 300.0))
		_host._adjudicate_bullets()   # 这一帧它还在场 → 记一条
		t.free()
	_host._adjudicate_bullets()       # 剪掉全部已销毁的
	_check(_host._seen_bullets.size() == _bullets.size(),
			"%d 轮生成/销毁后条目数仍 = 在场数(%d;旧实现会累积到 %d)" % [
					CHURN, _host._seen_bullets.size(), _bullets.size() + CHURN])


# 真子弹场景(真 BulletBase),关掉它自己的物理:只手动喂给裁决函数。
# shooter 留空 → _adjudicate_bullets 走"广播视觉后 continue"那条,不参与命中判定。
func _make_bullet(pos: Vector2):
	var b = (load("res://scenes/weapons/bullet.tscn") as PackedScene).instantiate()
	_host.add_child(b)
	b.set_physics_process(false)
	b.global_position = pos
	return b
