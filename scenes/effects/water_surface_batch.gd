class_name WaterSurfaceBatch
extends Node2D


const SHADER_CODE := """
shader_type canvas_item;

// 水面合批 shader。
// ★ 之前只有**竖直**平移(幅度 2 世界px),经相机 0.75 后 ≈1.5 屏幕px,而且没有横向分量
//   ⇒ 肉眼完全看不出"水在动"。这里补三件事:横向位移、两层错速条纹、位移 snap 到 2 世界px。

varying vec2 v_world;

uniform sampler2D surf : filter_nearest;   // ★ 必须最近邻:线性插值会把色阶磨成渐变
uniform float sway_speed = 1.6;
uniform float sway_amp = 2.0;
uniform float tile_ts = 64.0;

void vertex() {
	// 相位烘在顶点色 r(0..1→0..TAU);格底相对高度 f 烘在 g(0=底边 1=顶边)。
	float f = COLOR.g;
	float ph = COLOR.r * 6.2831853;
	VERTEX.y += sin(TIME * sway_speed + ph) * (sway_amp * f);
	// 横向:错相位、半幅度 —— 只有竖直位移时读不出流向。
	VERTEX.x += sin(TIME * sway_speed * 0.6 + ph * 1.7) * (sway_amp * 0.5 * f);
	// 像素化:位移 snap 到 2 世界px(1 美术像素 = 16 世界px 的 1/8,再细就是亚像素抖动)。
	VERTEX = floor(VERTEX / 2.0 + 0.5) * 2.0;
	v_world = VERTEX;
}

void fragment() {
\t// ★ 合批只负责**顶点位移**(水面起伏);颜色/条纹交给水体材质,避免两套颜色互相打架。
	COLOR = texture(surf, UV);
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
		var pos: Vector2 = c["pos"]
		var ph := fposmod(float(c["phase"]), TAU) / TAU
		var tint_bottom := Color(ph, 0.0, 0.0, 1.0)
		var tint_top := Color(ph, 1.0, 0.0, 1.0)
		var bl := Vector2(pos.x - half, pos.y)
		var br := Vector2(pos.x + half, pos.y)
		var tr := Vector2(pos.x + half, pos.y - ts)
		var tl := Vector2(pos.x - half, pos.y - ts)
		verts.append(Vector3(bl.x, bl.y, 0))
		verts.append(Vector3(br.x, br.y, 0))
		verts.append(Vector3(tr.x, tr.y, 0))
		verts.append(Vector3(tl.x, tl.y, 0))
		uvs.append(Vector2(0, 1))
		uvs.append(Vector2(1, 1))
		uvs.append(Vector2(1, 0))
		uvs.append(Vector2(0, 0))
		cols.append(tint_bottom)
		cols.append(tint_bottom)
		cols.append(tint_top)
		cols.append(tint_top)
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

