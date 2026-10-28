extends RefCounted

# 时间域解耦的常量单一来源:客户端 playout 渲染延迟 + 服务器命中回放的深度上限。
# ★ 不写 class_name:消费者用 preload 取常量,不受全局类缓存状态影响(与 playout_clock.gd 同款理由)。
# ★ PLAYOUT_TICKS 必须与 player_replica 的渲染延迟同值 —— 服务器按它回放"射手当时看到的那一帧",
#   两边各写一个数就会让回放时刻整体偏移(改了这里的值,player_replica 与 match_combat 同时生效)。

const PLAYOUT_TICKS := 3     # 60Hz tick 域:下行 30Hz(每包 2 tick)⇒ 3 tick ≈ 50ms 渲染延迟
const MAX_REWIND_TICKS := 8  # 命中回放最多回退 8 tick(≈133ms):防旧 st / 时钟漂移把回放拉穿历史
