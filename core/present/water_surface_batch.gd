class_name WaterSurfaceBatch
extends MeshInstance2D

const WCFG: WorldConfig = preload("res://core/config/world_config.tres")

const UV := [Vector2(0, 1), Vector2(1, 1), Vector2(1, 0), Vector2(0, 0)]
const TRIANGLES := [0, 1, 2, 0, 2, 3]
const SHADER_CODE := """
shader_type canvas_item;

// 对齐 main:所有液体格共用一条带状纹理流水线,使用世界坐标锚定横向条纹。
varying vec2 v_world;

uniform sampler2D surf : filter_nearest;
uniform float elapsed;
uniform float sway_speed = 1.6;
uniform float sway_amp = 2.0;

void vertex() {
	float w = COLOR.g;
	float lift = sin(elapsed * sway_speed + COLOR.r * 6.2831853) * (sway_amp * w);
	VERTEX.y += lift;
	v_world = VERTEX;
}

void fragment() {
	vec4 t = texture(surf, UV);
	float band = floor(v_world.y / 16.0);
	float s1 = sin(v_world.x * 0.020 + elapsed * 1.10 + band * 0.7);
	float s2 = sin(v_world.x * 0.035 - elapsed * 1.70 + band * 1.3);
	float st = clamp(0.5 + 0.25 * s1 + 0.25 * s2, 0.0, 1.0);
	st = floor(st * 3.0 + 0.5) / 3.0;
	t.rgb *= mix(0.95, 1.0, st);
	COLOR = t;
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
	surface.set_shader_parameter("surf", texture)
	surface.set_shader_parameter("sway_speed", WCFG.water_sway_speed)
	surface.set_shader_parameter("sway_amp", WCFG.water_sway_amp)
	material = surface

func present(now: float) -> void:
	material.set_shader_parameter("elapsed", now)
