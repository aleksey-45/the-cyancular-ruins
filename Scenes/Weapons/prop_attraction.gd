extends "res://Scenes/Weapons/prop_launcher.gd"

# 引力核心(卡 pr_attraction,旧名吸力炮):参数全部在同名 tscn
# (blast_force<0 吸/blast_radius/fuse_time/mag_size)。卡 rev18 约定:冲击按距离线性衰减
# (blast_linear_falloff)+ 引信白环(fuse_ring_visual,首撞起环向心收缩,收束完起爆)。
