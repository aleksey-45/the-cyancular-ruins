class_name WaterSurfaceBatch
extends Node2D


const SHADER := preload("res://scenes/effects/water_surface_batch.gdshader")

var _mesh: MeshInstance2D = null


func setup(cells: Array, tex: Texture2D, ts: int) -> void:
	if _mesh == null:
		_mesh = MeshInstance2D.new()
		_mesh.name = "SurfaceMesh"
		add_child(_mesh)
	var half := float(ts) * 0.5
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var cols := PackedColorArray()
	var idx := PackedInt32Array()
	var vi := 0
	for c in cells:
		var pos: Vector2 = c["pos"]           # 格子底边中心
		var ph := fposmod(float(c["phase"]), TAU) / TAU
		var w := float(c.get("weight", 1.0))  # 位移权重(顶点色 g)
		# 图集两行:上半(y 0..ts)= 水体砖,下半(y ts..2ts)= 水面砖。
		var v0 := 0.5 if bool(c.get("surface", false)) else 0.0
		var c_bottom := Color(ph, 0.0, 0.0, 1.0)
		var c_top := Color(ph, w, 0.0, 1.0)
		var bl := Vector2(pos.x - half, pos.y)
		var br := Vector2(pos.x + half, pos.y)
		var tr := Vector2(pos.x + half, pos.y - ts)
		var tl := Vector2(pos.x - half, pos.y - ts)
		verts.append(Vector3(bl.x, bl.y, 0))
		verts.append(Vector3(br.x, br.y, 0))
		verts.append(Vector3(tr.x, tr.y, 0))
		verts.append(Vector3(tl.x, tl.y, 0))
		uvs.append(Vector2(0, v0 + 0.5))
		uvs.append(Vector2(1, v0 + 0.5))
		uvs.append(Vector2(1, v0))
		uvs.append(Vector2(0, v0))
		cols.append(c_bottom)
		cols.append(c_bottom)
		cols.append(c_top)
		cols.append(c_top)
		idx.append(vi)
		idx.append(vi + 1)
		idx.append(vi + 2)
		idx.append(vi)
		idx.append(vi + 2)
		idx.append(vi + 3)
		vi += 4
	var mesh := ArrayMesh.new()
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_TEX_UV] = uvs
	arr[Mesh.ARRAY_COLOR] = cols
	arr[Mesh.ARRAY_INDEX] = idx
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)

	var mat := ShaderMaterial.new()
	mat.shader = SHADER
	mat.set_shader_parameter("surf", tex)
	mat.set_shader_parameter("sway_speed", GameParameters.water_sway_speed)
	mat.set_shader_parameter("sway_amp", GameParameters.water_sway_amp)
	_mesh.mesh = mesh
	_mesh.material = mat
