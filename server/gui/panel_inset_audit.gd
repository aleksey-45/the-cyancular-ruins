class_name PanelInsetAudit
extends RefCounted

# 设计期仪器(不是守卫):把每个文字控件到最近一层 PanelContainer 的四向内缩打出来。

const ARG := "--panel-audit"


static func requested() -> bool:
	return OS.get_cmdline_user_args().has(ARG)


# 等 3 帧让版式落定再量(容器 min_size 传播在第一帧后)。调用方用 `run.call_deferred(self)` 起。
static func run(root: Node) -> void:
	for _i in 3:
		await root.get_tree().process_frame
	_walk(root, Rect2())


static func _walk(n: Node, box: Rect2) -> void:
	# ★ 隐藏节点没有布局(rect 退化),量出来是 L0 这种假读数 ⇒ 直接跳过整棵子树。
	if n is CanvasItem and not (n as CanvasItem).visible:
		return
	if n is PanelContainer:
		box = (n as Control).get_global_rect()
	if n is Label or n is Button or n is RichTextLabel or n is VScrollBar:
		if box.size.x > 0.0:
			var g := (n as Control).get_global_rect()
			print("INSET %-14s L%6.1f R%6.1f T%6.1f B%6.1f  %s" % [n.get_class(),
					g.position.x - box.position.x, box.end.x - g.end.x,
					g.position.y - box.position.y, box.end.y - g.end.y,
					_text_of(n).substr(0, 20)])
	for ch in n.get_children():
		_walk(ch, box)


static func _text_of(c: Control) -> String:
	# ★ 分支必须分开写:Button 用 as Label 会得到 null,再取 .text 就是运行时错误(实测踩过)。
	if c is Label:
		return (c as Label).text
	if c is Button:
		return (c as Button).text
	if c is RichTextLabel:
		return (c as RichTextLabel).text.split("\n")[0]
	if c is VScrollBar:
		return "<滚动条>"
	return ""