class_name WaterSurfaceBatch
extends MeshInstance2D

const UV := [Vector2(0, 1), Vector2(1, 1), Vector2(1, 0), Vector2(0, 0)]
const TRIANGLES := [0, 1, 2, 0, 2, 3]
const SHADER_CODE := """
shader_type canvas_item;
uniform sampler2D surface;
uniform float elapsed;
uniform float speed;
uniform float amplitude;

void vertex() {
	VERTEX.y += sin(elapsed * speed + COLOR.r * 6.2831853) * amplitude * COLOR.g;
}

void fragment() {
	COLOR = texture(surface, UV);
}
"""

func setup(cells: Array, texture: Texture2D, tile_size: int) -> void:
	var points := PackedVector3Array()
	var uvs := PackedVector2Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	for cell: Array in cells:
		var start := points.size()
		var phase := fposmod(cell[1], TAU) / TAU
		for corner: Vector2 in UV:
			var at: Vector2 = cell[0] + (corner - Vector2(0.5, 1.0)) * tile_size
			points.append(Vector3(at.x, at.y, 0))
			uvs.append(corner)
			colors.append(Color(phase, 1.0 - corner.y, 0.0))
		for index: int in TRIANGLES:
			indices.append(start + index)
	var geometry := []
	geometry.resize(Mesh.ARRAY_MAX)
	geometry[Mesh.ARRAY_VERTEX] = points
	geometry[Mesh.ARRAY_TEX_UV] = uvs
	geometry[Mesh.ARRAY_COLOR] = colors
	geometry[Mesh.ARRAY_INDEX] = indices
	var shape := ArrayMesh.new()
	shape.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, geometry)
	mesh = shape

	var shader := Shader.new()
	shader.code = SHADER_CODE
	var surface := ShaderMaterial.new()
	surface.shader = shader
	surface.set_shader_parameter("surface", texture)
	surface.set_shader_parameter("speed", GameParameters.water_sway_speed)
	surface.set_shader_parameter("amplitude", GameParameters.water_sway_amp)
	material = surface

func present(now: float) -> void:
	material.set_shader_parameter("elapsed", now)
