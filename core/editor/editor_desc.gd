class_name EditorDesc
extends RefCounted

# 移植自已退役的浏览器编辑器 core/90_desc.js(2026-11-09 删除,历史见 git)—— descriptor 位域(辅码)。
# 位域:hue/bright/sat/alpha 各 3 位(bit0-11),texture 位 12-23(1-4095,0 = 空气),bit24-31 保留 0。

const DESC_AIR: int = 0
const TEXTURE_MAX: int = 4095
const HUE_NEUTRAL: int = 4
const BRI_NEUTRAL: int = 4
const SAT_NEUTRAL: int = 4
const ALPHA_NEUTRAL: int = 7   # alpha 的中性档是 7(原色),其余三列是 4


static func pack_desc(texture: int, hue: int, bright: int, sat: int, alpha: int) -> int:
	if texture <= 0 or texture > TEXTURE_MAX:
		return DESC_AIR
	return ((hue & 7) | ((bright & 7) << 3) | ((sat & 7) << 6) | ((alpha & 7) << 9) | (texture << 12)) & 0xFFFFFFFF


static func tex_of(d: int) -> int:
	return (d >> 12) & 0xFFF


static func hue_of(d: int) -> int:
	return d & 7


static func bright_of(d: int) -> int:
	return (d >> 3) & 7


static func sat_of(d: int) -> int:
	return (d >> 6) & 7


static func alpha_of(d: int) -> int:
	return (d >> 9) & 7


# ★ 只判整体等于 DESC_AIR:只对本编码器产出的数据可靠;读外来文件时的空气判据是 tex_of(d) == 0。
static func is_air(d: int) -> bool:
	return d == DESC_AIR


static func neutral_desc(texture: int) -> int:
	return pack_desc(texture, HUE_NEUTRAL, BRI_NEUTRAL, SAT_NEUTRAL, ALPHA_NEUTRAL)
