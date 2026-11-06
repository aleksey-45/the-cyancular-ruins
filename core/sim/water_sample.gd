extends RefCounted


const SURFACE_NONE := 0
const SURFACE_FREE := 1
const SURFACE_CEILING := 2
const SURFACE_FULL := 3

var in_water: bool = false
var surface_y: float = 0.0
var surface_kind: int = SURFACE_NONE
var feet_y: float = 0.0
var head_y: float = 0.0
var feet_depth: float = 0.0
var depth_px: float = 0.0
var head_under: bool = false
var submersion_ratio: float = 0.0
