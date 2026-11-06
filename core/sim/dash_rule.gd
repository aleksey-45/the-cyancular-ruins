extends RefCounted


const TIME_MULT_MIN := 0.001


static func dash_speed(base_speed: float, time_mult: float, move_mult: float) -> float:
	return base_speed * time_mult * move_mult


static func dash_wall_time(base_time: float, time_mult: float) -> float:
	return base_time / maxf(time_mult, TIME_MULT_MIN)


static func dash_allowed(current_vx: float, dash_speed_px: float) -> bool:
	return absf(current_vx) <= absf(dash_speed_px)


static func down_dash_allowed(current_vy: float, down_speed_px: float) -> bool:
	return current_vy <= down_speed_px
