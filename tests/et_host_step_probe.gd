extends Node

# host_start 分步复现探针(D1 诊断,2026-09-29 夜):
# 用户 exe 里点「一键开网」→ 防护报"空结果"且无任何脚本错误、session.json 未写。
# 本探针把 host_start 的每一步拆开逐步执行并打印**返回值类型**,定位无声 null 的产生点。
# 场景模式跑(autoload 可用);会弹一次 UAC(管理员终端跑则免)。

func _ready() -> void:
	print("STEP0: 开始分步复现 host_start")
	# 步骤 1:网段占用预检(同步)
	var occupant: String = EasyTierLink._foreign_subnet_owner()
	print("STEP1 occupant typeof=%d val='%s'" % [typeof(occupant), occupant])
	# 步骤 2:随机名/密 + 邀请码编码(同步)
	var net := "cyr-diag-" + str(randi() % 100000)
	var secret := "diag" + str(randi())
	var code: String = EasyTierLink.encode_code({"v": 1, "n": net, "s": secret,
			"p": EasyTierLink.DEFAULT_PEERS, "h": EasyTierLink.HOST_IP})
	print("STEP2 code typeof=%d len=%d" % [typeof(code), code.length()])
	# 步骤 3:解包 + 拉起内核(同步;UAC 在这里发生)
	var sdir: String = EasyTierLink._start_node("s0", net, secret, EasyTierLink.HOST_IP,
			EasyTierLink.DEFAULT_PEERS, [], true, EasyTierLink.DEV_NAME, EasyTierLink.RPC_PORT)
	print("STEP3 sdir typeof=%d val='%s'" % [typeof(sdir), sdir])
	if sdir == "" or typeof(sdir) != TYPE_STRING:
		print("STEP3-FATAL: _start_node 未正常返回,host_start 的 null 必来自这里之前")
		get_tree().quit(1)
		return
	# 步骤 4:等网卡(协程!)—— 嫌疑最大的一步,打印返回值类型
	var ip = await EasyTierLink._wait_adapter_ip(EasyTierLink.DEV_NAME, 60.0)
	print("STEP4 ip typeof=%d val='%s'" % [typeof(ip), str(ip)])
	# 步骤 5:照 host_start 的收尾组装返回值
	if ip == null or typeof(ip) != TYPE_STRING or ip == "":
		print("STEP5: 空结果复现!null 产生于步骤 4(await 静态协程)—— 引擎级返回链问题")
		EasyTierLink._request_stop("s0")
		get_tree().quit(2)
		return
	print("STEP5: 全链正常,ip=%s —— host_start 本应成功" % ip)
	EasyTierLink._request_stop("s0")
	print("DONE")
	get_tree().quit(0)
