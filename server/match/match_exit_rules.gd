class_name MatchExitRules
extends RefCounted

# 对局里「某个 peer 掉了」之后怎么办 = 纯分派(与 GraceWindow.expire_action 同款:形态有守卫、答案只此一处)。

const ACTION_GRACE := 0   # 未终局:进宽限期等他回来(旧行为,别在终局之后走这条)
const ACTION_WAIT := 1    # 已终局但还有人看结算:进程继续跑(快照照发),等他也走
const ACTION_QUIT := 2    # 已终局且一个不剩:立刻退进程(交回房与端口)


# match_over = 宿主已进 MATCH_OVER;claims_left = 这个 peer 摘掉之后**还剩几个真人参与者**。
static func after_peer_left(match_over: bool, claims_left: int) -> int:
	if not match_over:
		return ACTION_GRACE
	return ACTION_QUIT if claims_left <= 0 else ACTION_WAIT
