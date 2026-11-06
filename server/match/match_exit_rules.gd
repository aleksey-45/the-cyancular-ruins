class_name MatchExitRules
extends RefCounted


const ACTION_GRACE := 0
const ACTION_WAIT := 1
const ACTION_QUIT := 2


static func after_peer_left(match_over: bool, claims_left: int) -> int:
	if not match_over:
		return ACTION_GRACE
	return ACTION_QUIT if claims_left <= 0 else ACTION_WAIT
