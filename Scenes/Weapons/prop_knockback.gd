extends "res://Scenes/Weapons/prop_launcher.gd"

# 排斥弹头(卡 pr_knockback,旧名击退炮):参数全部在同名 tscn
# (blast_force/blast_radius/fuse_time/mag_size)。
# 卡 rev2 约定:斥力全域等强拉满——blast_falloff_mode=Falloff.FLAT + |force|=9000
# (单次冲量,位移≈|force|/knock_decay(10)≈900px=甩上天),与引力核心 rev20 同一标定,
# 推/吸互为镜像;白圈视效 fuse_ring_visual + 方向按 blast_force 符号(推=由爆心一圈圈
# 向外扩、到作用范围边缘消散,最后一圈到达最外沿时起爆);撞实体也走满引信
# (hit_fuse_time=0.5=撞墙时长),保证整段白圈序列播完才爆。
