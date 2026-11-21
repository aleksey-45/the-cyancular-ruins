class_name WaterSurfaceBatch
extends MeshInstance2D

const UV := [Vector2(0, 1), Vector2(1, 1), Vector2(1, 0), Vector2(0, 0)]
const TRIANGLES := [0, 1, 2, 0, 2, 3]

func setup(cells: Array, surface_texture: Texture2D, tile_size: int) -> void:
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
			var uv: Rect2 = cell[2]
			uvs.append(uv.position + corner * uv.size)
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
	texture = surface_texture
