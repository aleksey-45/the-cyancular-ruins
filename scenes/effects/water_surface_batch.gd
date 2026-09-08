class_name WaterSurfaceBatch
extends Node2D

# 水面单格伸缩合批(静态网格 + GPU 波):所有水面格在一个 Mesh2D 里,setup 期提交一次几何,
# 波动画走 canvas vertex shader(TIME 驱动,格底锚定、顶边按相位伸缩)。不再每帧用 GDScript
# 遍历整张 3×3 世界的水面格 sin+draw → CPU 每帧 ≈ 0,视觉与逐格 draw_texture_rect 一致。
# cells 元素:{"pos": Vector2(格底中心), "phase": float}。

const SHADER_CODE := """
shader_type canvas_item;
uniform sampler2D surf;
uniform float sway_speed = 1.6;
uniform float sway_amp = 2.0;
uniform float tile_ts = 64.0;
void vertex() {
	// 相位烘在顶点色 r(0..1→0..TAU);格底相对高度 f 烘在 g(0=底边 1=顶边)。
	// 位移 = f·sin·amp 纯平移:底边锚定不动,顶边 ±sway_amp(与原逐格缩放视觉一致)。
	float f = COLOR.g;
	float lift = sin(TIME * sway_speed + COLOR.r * 6.2831853) * (sway_amp * f);
	VERTEX.y += lift;
}
void fragment() {
	// 顶点色仅作数据通道(r=相位,g=高度),不参与着色(照常采样水面贴图)
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
		# 相位归一化到 [0,1) 进 r;g=0 给底边两顶点(锚定)、g=1 给顶边两顶点
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


func _process(_delta: float) -> void:
	# TIME 参与 vertex 的 shader 本应自动逐帧刷新;queue_redraw 兜底保证动画一定更新。
	# 开销恒定(单个 canvas item,静态网格,无 GDScript 几何循环)。
	if _mesh != null:
		_mesh.queue_redraw()
