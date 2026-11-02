class_name PlayerVisual
extends RefCounted

## 玩家本体(`player.gd`)与远端副本(`player_replica.gd`)共用的**纯表现**表与常量。
##
## ★ 为什么收在一处:两张姿态表原先各写一份、值一字不差 —— 改一处忘另一处**不报错**,
##   表现是副本「动画放错姿态」或「幽灵体用错碰撞箱」,而且只有人眼能看出来。
## ★ 什么**不**收进来:残影「何时发」的判据 —— 本体看 `is_charge`(物理态),副本看自己的
##   `_pose/_downed`(快照态)。两者语义本就不同,合并只会把分支塞进来。
## ★ 键为什么是裸 int:本体刻意没有 `class_name`(历史原因,见 player.gd 文件头),枚举搬不过来;
##   枚举值顺序由 player.gd `_ready` 里的一致性检查兜住(push_error,不是静默)。

const POSE_STAND := 0
const POSE_MOVE := 1
const POSE_FLY := 2
const POSE_CHARGE := 3
const POSE_SQUAT := 4

## 姿态 → `AnimatedSprite2D` 的动画名。键 = `player.gd` 的 `Pose` 枚举值。
const ANIM: Dictionary = {
	POSE_STAND: "idle", POSE_MOVE: "move", POSE_FLY: "fly",
	POSE_CHARGE: "charge", POSE_SQUAT: "squat",
}

## 姿态 → 碰撞箱节点名(`player.tscn` 与副本手搭的 5 个 `CollisionPolygon2D`)。
const COLLISION_NODE: Dictionary = {
	POSE_STAND: "CollisionShape2D_stand", POSE_MOVE: "CollisionShape2D_move",
	POSE_FLY: "CollisionShape2D_fly", POSE_CHARGE: "CollisionShape2D_charge",
	POSE_SQUAT: "CollisionShape2D_squat",
}

## 冲刺残影:两个宿主共用同一套强度(很弱的淡蓝白)。**只在这一处调**,别在宿主里另写数。
const DASH_GHOST_INTERVAL := 0.02
const DASH_GHOST_DURATION := 0.20
const DASH_GHOST_TINT := Color(0.78, 0.92, 1.0, 0.30)
