class_name WaterSurfaceBatch
extends Node2D


const SHADER_CODE := """
shader_type canvas_item;

// 水体合批:**所有**液体格都走这一条管线(水面砖/水体砖只是图集里不同的 UV 行)。
// 这样同色、同 alpha、同条纹、同起伏,不存在"两条管线对不齐"的接缝。
varying vec2 v_world;

uniform sampler2D surf : filter_nearest;
uniform float sway_speed = 1.6;
uniform float sway_amp = 2.0;
uniform float tile_ts = 64.0;

void vertex() {
	// 顶点色:r=相位(0..1→0..TAU),g=本顶点的位移权重(底边 0 / 顶边随深度衰减)。
	float w = COLOR.g;
	float lift = sin(TIME * sway_speed + COLOR.r * 6.2831853) * (sway_amp * w);
	VERTEX.y += lift;
	v_world = VERTEX;
}

void fragment() {
	vec4 t = texture(surf, UV);
	// 横向流动条纹:与水体材质同一套公式,锚世界坐标。
	float band = floor(v_world.y / 16.0);
	float s1 = sin(v_world.x * 0.020 + TIME * 1.10 + band * 0.7);
	float s2 = sin(v_world.x * 0.035 - TIME * 1.70 + band * 1.3);
	float st = clamp(0.5 + 0.25 * s1 + 0.25 * s2, 0.0, 1.0);
	st = floor(st * 3.0 + 0.5) / 3.0;
	t.rgb *= mix(0.88, 1.0, st);
	COLOR = t;
}
"""

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
	var sh := Shader.new()
	sh.code = SHADER_CODE
	mat.shader = sh
	mat.set_shader_parameter("surf", tex)
	mat.set_shader_parameter("sway_speed", GameParameters.water_sway_speed)
	mat.set_shader_parameter("sway_amp", GameParameters.water_sway_amp)
	mat.set_shader_parameter("tile_ts", float(ts))
	_mesh.mesh = mesh
	_mesh.material = mat
