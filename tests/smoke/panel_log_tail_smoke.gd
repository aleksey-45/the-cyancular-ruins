extends SceneTree
# 服务端面板日志 tail 守卫(01 审查 S-13①:tail 是面板里唯一有纯逻辑可测价值的一段,
# 从 `server_panel.gd` 抽成 `PanelLogTail` 后由本文件驱动)。
# 覆盖(逐条对应抽取前 `_append_log_delta` 的口径):
#   ① 首次读返回全部完整行;② **半行不消费**(没有换行结尾的尾巴留到下一轮,offset 不前进);
#   ③ 补全半行后只返回新增的那一行;④ 文件被轮转/重建(offset > 长度)⇒ 归零重读并回报 rotated;
#   ⑤ 超上限从头部截断且**切在行边界**(首行不能是半截);⑥ reset 清状态、重读得到全文。
# 最强保证:纯 RefCounted + 真临时文件,不碰 SceneTree/autoload;不用 UI 也能测。
# 测不到什么:UI 侧跟随/暂停与滚动位置(I1/I2,留在 `server_panel._refresh_log`,要人眼)。
# 变异验证:删「没有换行就 return」⇒ ② 红;删 rotated 归零 ⇒ ④ 红;删行边界切分 ⇒ ⑤ 红。
# 跑法:"$GODOT" --headless --path . -s res://tests/smoke/panel_log_tail_smoke.gd;通过 = PANEL LOG TAIL OK(n 条断言)。

const EXPECTED_CHECKS := 6
const TMP := "user://panel_log_tail_smoke.log"

var _fails: Array[String] = []
var _checks := 0


func _chk(ok: bool, msg: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(msg)


func _write(s: String) -> void:
	var f := FileAccess.open(TMP, FileAccess.WRITE)
	if f == null:
		_chk(false, "无法写临时日志文件(-s 空载守卫:不 quit 会挂死)")
		_finish()
		return
	f.store_string(s)
	f.close()


func _append(s: String) -> void:
	_write(FileAccess.get_file_as_string(TMP) + s)


func _initialize() -> void:
	_write("")
	var abs := ProjectSettings.globalize_path(TMP)
	var t := PanelLogTail.new()

	# ① 首次读:全部完整行
	_write("a\nb\n")
	var r1 := t.read_delta(abs)
	_chk(str(r1["new_text"]) == "a\nb\n" and not bool(r1["rebuild"]) and not bool(r1["rotated"]),
			"首次读返回全部完整行(实得 %s)" % str(r1["new_text"]))

	# ② 半行不消费:offset 不前进、什么都不吐
	_append("c")
	var r2 := t.read_delta(abs)
	_chk(str(r2["new_text"]) == "" and t.offset == 4 and t.text == "a\nb\n",
			"半行不消费(offset 仍 4、text 不变;实得 off=%d)" % t.offset)

	# ③ 补上换行后只返回新增那一行
	_append("\n")
	var r3 := t.read_delta(abs)
	_chk(str(r3["new_text"]) == "c\n" and t.text == "a\nb\nc\n", "补全半行后只吐新增行(实得 %s)" % str(r3["new_text"]))

	# ④ 轮转/重建:文件比 offset 短 ⇒ 归零重读 + rotated
	_write("x\n")
	var r4 := t.read_delta(abs)
	_chk(bool(r4["rotated"]) and str(r4["new_text"]) == "x\n" and t.offset == 2 and t.text == "x\n",
			"文件重建必须归零重读(rotated / 实得 %s / off=%d)" % [str(r4["new_text"]), t.offset])

	# ⑤ 超上限截断:切在行边界,首行不能是半截
	t.reset()
	t.max_chars = 7
	_write("aaa\nbbb\nccc\n")
	var r5 := t.read_delta(abs)
	_chk(bool(r5["rebuild"]) and t.text == "ccc\n" and t.text.length() <= t.max_chars
			and not t.text.begins_with("bb") and t.text.ends_with("\n"),
			"超上限从头部截断且切在行边界(实得 %s)" % str(t.text))

	# ⑥ reset 清状态;默认上限下重读得到全文
	t.reset()
	t.max_chars = PanelLogTail.DEFAULT_MAX_CHARS
	var r6 := t.read_delta(abs)
	_chk(t.offset == 12 and str(r6["new_text"]) == "aaa\nbbb\nccc\n" and t.text == "aaa\nbbb\nccc\n",
			"reset 后重读得到全文(实得 off=%d)" % t.offset)

	DirAccess.remove_absolute(abs)
	_finish()


func _finish() -> void:
	if _checks != EXPECTED_CHECKS:
		_fails.append("★ 实跑 %d 条断言,与 EXPECTED_CHECKS=%d 对不上(有断言被静默跳过?)" % [_checks, EXPECTED_CHECKS])
	if _fails.is_empty():
		print("PANEL LOG TAIL OK(%d 条断言):增量读 · 半行保留 · 重建归零 · 行边界截断 · reset" % _checks)
		quit(0)
	else:
		for f in _fails:
			print("  [FAIL] ", f)
		print("PANEL LOG TAIL FAILED: %d 处" % _fails.size())
		quit(1)