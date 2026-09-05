extends Node

# 实验分支扩展协议(autoload,与原版 NetBus 刻意分离):
# Godot 的 RPC 按「节点路径+方法名」解析,但实测改动原 NetBus 的方法列表(改签名/
# 插新方法)会让与原版大厅(120.53.107.140:7777)的 RPC 全部失联——建房间无应答。
# 因此:原 NetBus 保持与原版逐字节一致;实验新增 RPC 全部放本节点。
# 对原版 worker:本节点不存在 → 扩展 RPC 静默丢弃,优雅降级(选项/颜色不生效,对局照常);
# 对自建 worker(同版本构建):选项/颜色功能齐全。

signal local_match_options(opts: Dictionary)      # worker → 客户端:生效对局选项(房主下发)
signal local_peer_hues(hues: Dictionary)          # worker → 客户端:双方自选角色颜色 {role -> 色相}
signal player_options_received(caller: int, opts: Dictionary)  # worker:某客户端上报的本端选项

# 客户端 → worker:本端选项(角色颜色/规则偏好)。服务器权威项以房主(role1)为准。
@rpc("any_peer", "reliable")
func player_options(opts: Dictionary) -> void:
	player_options_received.emit(multiplayer.get_remote_sender_id(), opts)

# worker → 客户端:本局生效选项(禁武器/回合回血),进局广播一次
@rpc("authority", "reliable")
func match_options(opts: Dictionary) -> void:
	local_match_options.emit(opts)

# worker → 客户端:双方角色颜色 {role(int) -> 色相度数},开局广播一次
@rpc("authority", "reliable")
func peer_hues(hues: Dictionary) -> void:
	local_peer_hues.emit(hues)
