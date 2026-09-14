extends Node
func _ready() -> void:
	var WC := load("res://Scenes/Player/weapon_component.gd")
	var src: String = WC.source_code
	print("A 引擎看到的源码含 wp_machete=", src.contains("wp_machete"))
	print("A2 磁盘含 wp_machete=", FileAccess.get_file_as_string("res://Scenes/Player/weapon_component.gd").contains("wp_machete"))
	print("B WEAPONS[8]=", WC.WEAPONS.get("8", "<无>"))
	var m: WeaponBase = (load("res://Scenes/Weapons/machete.tscn") as PackedScene).instantiate()
	add_child(m)
	await get_tree().physics_frame
	print("C machete 实例化=", m != null, " damage=", m.damage)
	print("D 路径=", WC.resource_path)
	get_tree().quit(0)
