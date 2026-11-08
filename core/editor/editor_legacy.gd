class_name EditorLegacy
extends RefCounted

# 镜像 level_editor/core/95_legacy.js —— legacy 纹理 id 的读时迁移(新图集里 7 个全透明槽)。
# ★ 纹理 id 空间稳定 1..22 不重编号、文件格式保持 v4:迁移只发生在**读时**,内存即干净。
# ★ 迁移表 = TileDefs(读 data/tile_defs.json,单一真相源);表缺席时 TileDefs 自己返回 0 ⇒ 本模块 no-op。


# 合成规则:tex 命中 legacy_texture_map ⇒ new_tex = base、new_hue = clamp(hue + legacy_hue − 4, 0, 7)。
static func migrate_descriptor(d: int) -> int:
	var tex := EditorDesc.tex_of(d)
	if tex == 0:
		return d
	var base := TileDefs.legacy_base_of(tex)
	if base < 1 or base > EditorDesc.TEXTURE_MAX:
		return d
	var hue := clampi(EditorDesc.hue_of(d) + TileDefs.legacy_hue_of(tex) - EditorDesc.HUE_NEUTRAL, 0, 7)
	return (d & ~((0xFFF << 12) | 7)) | (base << 12) | hue


# 整图三个纹理层原地迁移(颜色层是 RGBA 不是描述符,一个字节都不碰)。交回同一个 map。
static func migrate_map(map: Dictionary) -> Dictionary:
	var layers: Array = map.get("layers", [])
	for layer_idx in mini(layers.size(), EditorConstants.LAYER_COUNT):
		var layer = layers[layer_idx]
		if layer == null:
			continue
		var ld: Dictionary = layer
		if String(ld.get("kind", "")) != "tex" or not ld.has("desc"):
			continue
		var a: PackedInt32Array = ld["desc"]
		for i in a.size():
			if a[i] == 0:
				continue
			var m := migrate_descriptor(a[i])
			if m != a[i]:
				a[i] = m
		ld["desc"] = a
	return map
