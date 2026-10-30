extends RefCounted

# 时间域常量单一来源:客户端 playout 渲染延迟 + 服务器命中回放深度上限。
# PLAYOUT_TICKS 必须与 player_replica 的渲染延迟同值:服务器按它回放"射手当时看到的那一帧"。
# 消费者用 preload 取常量;不写 class_name(避免编辑器扫描依赖,导出后不受全局类缓存影响)。

const PLAYOUT_TICKS := 2     # 60Hz tick 域:2 tick ≈ 33ms(1 包夹逼下限 + 1 包抖动余量)
const MAX_REWIND_TICKS := 8  # 命中回放最多回退 8 tick(≈133ms)
