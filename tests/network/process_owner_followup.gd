extends Node
const Tunnel := preload("res://core/net/tunnel.gd")

func _ready() -> void:
	assert(LocalServer.is_owned_running() and Tunnel.is_running())
	await get_tree().create_timer(1.0).timeout
	assert(LocalServer.is_owned_running() and Tunnel.is_running())
	print("PROCESS SCENE TRANSITION OK")
	get_tree().quit()
