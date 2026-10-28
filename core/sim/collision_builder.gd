class_name CollisionBuilder
extends RefCounted

# 统一地形几何参数。数据、布局、脏区与形状生命周期由 NativeTerrain 管理。
const SUB_TS := 16
const TILE_TS := 64
const CHUNK_CELLS := 12
const LEDGE_THICKNESS := 6
const CHUNK_CACHE_STATES := 4
static var geometry_revision: int:
	get: return TileDefs.terrain.get_geometry_revision()

static func chunk_of(cell: Vector2i) -> Vector2i:
	return Vector2i(cell.x / CHUNK_CELLS, cell.y / CHUNK_CELLS)

static func affects_since(revision: int, bounds: Rect2) -> bool:
	return TileDefs.terrain.affects_since(revision, bounds)
