extends "res://Scenes/Weapons/prop_launcher.gd"

# 引力核心(卡 pr_attraction,旧名吸力炮):参数全部在同名 tscn
# (blast_force<0 吸/blast_radius/fuse_time/mag_size)。卡 rev18 约定:冲击按距离线性衰减
# (现 Explosion.Falloff.LINEAR 档)+ 引信白环(fuse_ring_visual,首撞起环向心收缩,收束完起爆)。
# 卡 rev19 约定:吸力拉满——冲击是单次冲量,位移≈|force|/knock_decay(10),
# 取 |force|=10×半径 ⇒ 爆心满强度吸程=半径、半程目标恰好吸到爆心;再叠 |force| 只会
# 让贴爆心的目标穿过爆心甩到另一侧,不再更"吸"。改吸力先想清这条标定。
# 卡 rev20 约定:吸力改全域等强(blast_falloff_mode=Falloff.FLAT)——只要在半径内,
# 不分距离一律吃满 |force|(9000/10=900px 位移,贴边目标同样被吸穿爆心甩向另一侧=甩飞手感);
# 作用对象=玩家(含射手自己)/敌人/子弹(bullet 组含敌方投弹),无伤、无 LOS 遮挡判定。
