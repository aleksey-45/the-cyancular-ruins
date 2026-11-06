class_name PlayerVisual
extends RefCounted


const POSE_STAND := 0
const POSE_MOVE := 1
const POSE_FLY := 2
const POSE_CHARGE := 3
const POSE_SQUAT := 4

const ANIM: Dictionary = {
	POSE_STAND: "idle", POSE_MOVE: "move", POSE_FLY: "fly",
	POSE_CHARGE: "charge", POSE_SQUAT: "squat",
}

const COLLISION_NODE: Dictionary = {
	POSE_STAND: "CollisionShape2D_stand", POSE_MOVE: "CollisionShape2D_move",
	POSE_FLY: "CollisionShape2D_fly", POSE_CHARGE: "CollisionShape2D_charge",
	POSE_SQUAT: "CollisionShape2D_squat",
}

const DASH_GHOST_INTERVAL := 0.02
const DASH_GHOST_DURATION := 0.20
const DASH_GHOST_TINT := Color(0.78, 0.92, 1.0, 0.30)
