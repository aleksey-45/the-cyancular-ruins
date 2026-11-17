class_name WorkerPorts
extends RefCounted

# 对局 worker 的端口池:**唯一来源**,服务器分配器与客户端提示文案共用。
# ★ 这条类存在的原因就是架构规则 R2:客户端(mp_lobby)曾经为了打印端口段而 import 服务器类 WorkerLauncher。
#   把数字放进共享层,客户端就不必认识服务器实现。
# ★ 历史上提示串里写死过 7800~7910(与实际池不符),照它放行防火墙会漏掉半个池子 —— 数字只许出现在这里。
const BASE := 7800
const SPAN := 500
