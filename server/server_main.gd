extends Node2D
# 服务器入口(headless 运行):监听端口 + 挂 RoomManager。

func _ready() -> void:
	var err := NetBus.start_server()
	if err != OK:
		push_error("服务器: 监听失败 %d" % err)
		get_tree().quit(1)
		return
	add_child(RoomManager.new())
	print("服务器就绪,等待玩家……")
