extends SceneTree

# 一次性/可复用工具:把 maps/ 下所有 v1/v2/v3 文本地图转换成 **v4 二进制**并原地覆盖。
# 每张图写盘前先做"往返自证":serialize_v4 → parse_v4 → flatten 必须与原网格逐格一致,
# spawn 解析结果也必须一致,否则**拒写**(宁可不转,不可转坏)。
# 已是 v4(头 4 字节 CYRM)则跳过。旧文件内容都在 git 历史里,不另做备份副本。
# 用法:godot --headless --path . -s res://tests/convert_map_v4.gd

func _initialize() -> void:
	var dir := "res://maps"
	var da := DirAccess.open(dir)
	if da == null:
		print("CONVERT V4: FAIL(打不开 %s)" % dir)
		quit(1)
		return
	var maps: Array[String] = []
	da.list_dir_begin()
	var f := da.get_next()
	while f != "":
		if not da.current_is_dir() and f.to_lower().ends_with(".cyrm"):
			maps.append(dir.path_join(f))
		f = da.get_next()
	da.list_dir_end()
	maps.sort()
	var converted := 0
	var skipped := 0
	var failed := 0
	for path in maps:
		if MapFormat.is_v4(path):
			print("CONVERT V4: 跳过(已是 v4) %s" % path)
			skipped += 1
			continue
		var grid := MapFormat.load_map_file(path)
		if grid.is_empty():
			print("CONVERT V4: FAIL(解析不出网格) %s" % path)
			failed += 1
			continue
		# 注释/出生点行原样带走(只丢版本标记行)
		var meta: Array = []
		for l in MapFormat.read_lines(path):
			var s := String(l).strip_edges()
			if s.begins_with("#") and not s.begins_with("# cyrm-v3") and not s.begins_with("# cyrm-v2"):
				meta.append(s)
		var blob := MapFormatV4.serialize(grid, meta)
		# ── 往返自证(拒写坏图)──
		var v := MapFormatV4.parse(blob)
		if not bool(v.get("ok", false)):
			print("CONVERT V4: FAIL(自证解析失败:%s) %s" % [str(v.get("error")), path])
			failed += 1
			continue
		var back := MapFormatV4.flatten_scene(v["scene"], int(v["sub_cols"]), int(v["sub_rows"]))
		if back != grid:
			print("CONVERT V4: FAIL(往返网格不一致,拒写) %s" % path)
			failed += 1
			continue
		var sp_old := MapFormat.load_spawns(path)
		var sp_new := MapFormat.parse_spawn_metadata(v["meta_lines"])
		if str(sp_old) != str(sp_new):
			print("CONVERT V4: FAIL(spawn 不一致,拒写) %s" % path)
			failed += 1
			continue
		var wf := FileAccess.open(path, FileAccess.WRITE)
		if wf == null:
			print("CONVERT V4: FAIL(写不进去) %s" % path)
			failed += 1
			continue
		wf.store_buffer(blob)
		wf.close()
		print("CONVERT V4: %s → v4(%dx%d 格,meta %d 行,二进制 %d 字节)" % [
				path, (grid[0] as Array).size(), grid.size(), meta.size(), blob.size()])
		converted += 1
	print("CONVERT V4: 完成 转换 %d / 跳过 %d / 失败 %d" % [converted, skipped, failed])
	quit(1 if failed > 0 else 0)
