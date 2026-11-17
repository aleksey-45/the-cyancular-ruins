extends SceneTree

# 整图校验与尺寸钳制冒烟(`-s`,headless):EditorValidate.clamp_map_size / EditorValidate.validate_map。
# 去掉什么它才会红:
#   ① 钳制不再是「夹到 1..上限」而是报错/放行 ⇒ ① 组红;
#   ② errors 与 warnings 的边界被搞混(该拒的只 warning、该只提示的变 error)⇒ ② 组红;
#   ③ 「纹理不在 tile_defs」这条 error 丢了 ⇒ 越界号/legacy id 会被静默写进文件;
#   ④ 复活点判据(半区/边距/环面距离/3×3 桶)任一条丢了 ⇒ ④ 组对应断言红。
# 判据是未跑满条数与失败清单两条。

const EXPECTED_CHECKS := 20

var _fails: Array[String] = []
var _checks := 0


func _chk(ok: bool, msg: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(msg)


func _initialize() -> void:
	if load("res://core/editor/editor_validate.gd") == null \
			or load("res://core/editor/editor_map.gd") == null:
		print("EDITOR VALIDATE SMOKE: FAIL | 空载守卫 load 为 null(-s 不 quit 会挂死)")
		quit(1)
		return

	_check_clamp()
	_check_errors()
	_check_warnings()
	_check_respawns()

	if _checks < EXPECTED_CHECKS:
		print("EDITOR VALIDATE SMOKE: FAIL | 只跑了 %d 条 < %d(脚本中途中止)" % [_checks, EXPECTED_CHECKS])
		quit(1)
		return
	if not _fails.is_empty():
		print("EDITOR VALIDATE SMOKE: FAIL(%d/%d)" % [_fails.size(), EXPECTED_CHECKS])
		for f in _fails:
			print("  - " + f)
		quit(1)
		return
	print("EDITOR VALIDATE SMOKE: OK(%d 条断言)" % _checks)
	quit(0)


func _check_clamp() -> void:
	var a := EditorValidate.clamp_map_size("99999", "99999")
	_chk(a["w"] == 400 and a["h"] == 300, "① 99999 钳到 400×300(实得 %d×%d)" % [a["w"], a["h"]])
	var b := EditorValidate.clamp_map_size("0", "-5")
	_chk(b["w"] == 1 and b["h"] == 1, "① 0/-5 钳到 1(实得 %d×%d)" % [b["w"], b["h"]])
	var c := EditorValidate.clamp_map_size("abc", "")
	_chk(c["w"] == 125 and c["h"] == 75, "① 非数字回落默认 125×75(实得 %d×%d)" % [c["w"], c["h"]])
	var d := EditorValidate.clamp_map_size("12abc", " 7 ")
	_chk(d["w"] == 12 and d["h"] == 7, "① parseInt 前缀语义 12abc→12、\" 7 \"→7(实得 %d×%d)" % [d["w"], d["h"]])
	var e := EditorValidate.clamp_map_size("300", "200")
	_chk(e["w"] == 300 and e["h"] == 200, "① 上限内原样(实得 %d×%d)" % [e["w"], e["h"]])


func _check_errors() -> void:
	var six := EditorMap.create_map("t", 2, 2)
	(six["layers"] as Array).pop_back()
	var rep := EditorValidate.validate_map(six)
	_chk(_has(rep["errors"], "图层数不是 7"), "② 图层数 != 7 是 error:%s" % str(rep["errors"]))

	var odd := EditorMap.create_map("t", 2, 2)
	odd["sub_cols"] = 5
	rep = EditorValidate.validate_map(odd)
	_chk(_has(rep["errors"], "的倍数"), "② sub 尺寸不是 4 的倍数 是 error:%s" % str(rep["errors"]))

	var badlen := EditorMap.create_map("t", 2, 2)
	(badlen["layers"][0] as Dictionary)["desc"] = PackedInt32Array([0, 0])
	rep = EditorValidate.validate_map(badlen)
	_chk(_has(rep["errors"], "层长度不是"), "② 层数组长度不符 是 error:%s" % str(rep["errors"]))

	var legacy := EditorMap.create_map("t", 4, 3)
	var desc: PackedInt32Array = (legacy["layers"][1] as Dictionary)["desc"]
	desc[0] = EditorDesc.neutral_desc(2)
	(legacy["layers"][1] as Dictionary)["desc"] = desc
	rep = EditorValidate.validate_map(legacy)
	_chk(_has(rep["errors"], "不在 tile_defs") and _has(rep["errors"], "场景层有纹理 2"),
			"② legacy 纹理 2 是 error 且点名层与纹理号:%s" % str(rep["errors"]))

	var oob_tex := EditorMap.create_map("t", 4, 3)
	var d2: PackedInt32Array = (oob_tex["layers"][0] as Dictionary)["desc"]
	d2[0] = EditorDesc.neutral_desc(999)
	(oob_tex["layers"][0] as Dictionary)["desc"] = d2
	rep = EditorValidate.validate_map(oob_tex)
	_chk(_has(rep["errors"], "前景层有纹理 999"), "② 越界纹理号 999 是 error:%s" % str(rep["errors"]))


func _check_warnings() -> void:
	var empty := EditorMap.create_map("t", 3, 3)
	var rep := EditorValidate.validate_map(empty)
	_chk((rep["errors"] as Array).is_empty()
			and _has(rep["warnings"], "一个出生点都没有") and _has(rep["warnings"], "所有图层全是空的"),
			"③ 空图只有 warning(出生点/全空):%s" % str(rep["warnings"]))

	var oob := EditorMap.create_map("t", 3, 3)
	oob["players"] = [{"x": 5, "y": 5}]
	rep = EditorValidate.validate_map(oob)
	_chk(_has(rep["warnings"], "越界") and (rep["errors"] as Array).is_empty(),
			"③ 出生点越界是 warning:%s" % str(rep["warnings"]))

	var solid := EditorMap.create_map("t", 3, 3)
	var sd: PackedInt32Array = (solid["layers"][1] as Dictionary)["desc"]
	for dy in 4:
		for dx in 4:
			sd[(1 * 4 + dy) * 12 + (1 * 4 + dx)] = EditorDesc.neutral_desc(1)
	(solid["layers"][1] as Dictionary)["desc"] = sd
	solid["players"] = [{"x": 1, "y": 1}]
	rep = EditorValidate.validate_map(solid)
	_chk(_has(rep["warnings"], "落在实心格里"), "③ 出生点在实心格 是 warning:%s" % str(rep["warnings"]))

	var pvp_no_rs := EditorMap.create_map("t", 20, 20)
	pvp_no_rs["players"] = [{"x": 2, "y": 2}, {"x": 18, "y": 2}]
	rep = EditorValidate.validate_map(pvp_no_rs)
	_chk(_has(rep["warnings"], "没有任何「# respawn」复活点"),
			"③ PvP 图(有 player2)没有 respawn 是 warning:%s" % str(rep["warnings"]))

	var single := EditorMap.create_map("t", 20, 20)
	single["players"] = [{"x": 2, "y": 2}]
	single["respawns"] = []
	rep = EditorValidate.validate_map(single)
	_chk(not _has(rep["warnings"], "没有任何「# respawn」"),
			"③ 单机图没有 respawn 不提示:%s" % str(rep["warnings"]))


func _check_respawns() -> void:
	var m := EditorMap.create_map("t", 20, 20)
	m["players"] = [{"x": 2, "y": 2}, {"x": 18, "y": 2}]
	m["respawns"] = [
		{"side": 1, "x": 3, "y": 3},
		{"side": 2, "x": 19, "y": 19}, {"side": 2, "x": 15, "y": 19},
		{"side": 2, "x": 11, "y": 19}, {"side": 2, "x": 11, "y": 15},
		{"side": 2, "x": 15, "y": 15},
	]
	var rep := EditorValidate.validate_map(m)
	_chk(_has(rep["warnings"], "侧 1 只有 1 个复活点"), "④ 每侧点数不足是 warning:%s" % str(rep["warnings"]))
	_chk(_has(rep["warnings"], "侧 1 有 1 个点离接缝/半区中线不足 10 格"), "④ 离接缝太近是 warning")
	_chk(_has(rep["warnings"], "侧 2 有两个点挨得太近(环面距离 4 格 < 5)"), "④ 同侧两两太近是 warning(19 与 15 环面差 4)")
	_chk(_has(rep["warnings"], "侧 2 的 3×3 桶有 6 个空桶"), "④ 3×3 空桶是 warning")
	_chk((rep["errors"] as Array).is_empty(), "④ 复活点问题一律 warning 不是 error:%s" % str(rep["errors"]))


func _has(list: Variant, sub: String) -> bool:
	if not (list is Array):
		return false
	for item in list:
		if String(item).contains(sub):
			return true
	return false
