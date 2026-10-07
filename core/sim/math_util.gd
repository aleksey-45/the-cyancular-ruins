class_name MathUtil
extends RefCounted

# 通用数学工具类。纯静态函数，无实例状态，不依赖任何 Autoload，
# 支持在任何场景、工具脚本或独立命令行测试（-s）中安全调用。


# 指数平滑逼近函数：朝目标值平滑插值过渡。
# rate 越大响应越迅速；具有起步迅速、接近目标平缓渐变的特性，松开按键时带有自然滑行，
# 转向时平滑穿过零点，比线性 move_toward 具有更自然的运动手感。
# 作为全局通用计算方法，供角色移动、敌人 AI 与游泳组件统一调用。
static func approach(current: float, target: float, rate: float, delta: float) -> float:
	return lerp(current, target, 1.0 - exp(-rate * delta))
