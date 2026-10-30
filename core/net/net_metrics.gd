class_name NetMetrics
extends RefCounted

# 联机度量的小工具(纯静态、无 autoload 依赖 ⇒ `-s` 冒烟可加载)。
#
# 下行为什么能"量"丢包:世界包 / 本人包走 unreliable 通道,服务端**每个快照 tick 发一包**,包内带
# `tick`。客户端只要看相邻两包的 tick 差,就能反推丢了几包:
#   无丢包 ⇒ 差值 = 当时的发包步长(60Hz 下 = 1);差 3 格 ⇒ 中间丢了 2 包。
# 没有这条估计时,"丢包"只能靠 snap_rx/snapshot_tx 两份日志按秒手工对账,现场没人会对。
#
# ★ 边界(照实写):① 这是**估计**不是链路真值 —— 迟到/乱序包(旧 tick)不计丢、也不更新基线;
#   ② 重连/换局/服务端重启会让 tick 跳变,调用方用 `reset_snapshot_state()` 清基线(不清会记一笔假丢包);
#   ③ 只覆盖 unreliable 的下行;上行输入的丢包表现为 seq 缺口,由 input_intake 的队列丢弃计数间接反映。

## 相邻两快照之间丢了几包。`step` = 无丢包时的 tick 步长(由调用方学出来)。
## prev_tick < 0(首个包) / tick 回退(乱序或换纪元) ⇒ 0。
static func snapshot_loss(prev_tick: int, tick: int, step: int) -> int:
	if prev_tick < 0 or tick <= prev_tick:
		return 0
	var st := maxi(step, 1)
	var gap := tick - prev_tick
	if gap <= st:
		return 0
	return int(gap / st) - 1


## 丢包率(整数百分比)。总样本为 0 ⇒ 0。
static func loss_pct(rx: int, lost: int) -> int:
	var total := rx + lost
	if total <= 0:
		return 0
	return roundi(100.0 * float(lost) / float(total))


## 服务端日志目录**选择**(纯函数):导出构建里的服务端 = exe 同目录 `log/`(打包后默认落盘);
## 其余(开发态 / 客户端 / 编辑器) = `user://logs` 的绝对路径。
## ★ 判据是"是否为导出构建 + 是否服务端",不是"目录存不存在":落盘口径必须可预测,不能看环境猜。
static func server_log_dir(is_server: bool, is_template: bool, exe_dir: String, user_dir: String) -> String:
	if is_server and is_template:
		return exe_dir.path_join("log")
	return user_dir
