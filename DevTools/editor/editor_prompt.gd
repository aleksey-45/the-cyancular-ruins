class_name EditorPrompt
extends RefCounted

# 施工提示词生成(素材编辑器 v2):卡 JSON + 特殊要求 + 美术资产政策 + 路径白名单 +
# headless 验证 + CARD-DONE 回报。发往 AgentLink(默认本机 Claude Code CLI,可换传输层)。

const HEAD := "# 素材卡施工提示词(素材编辑器自动生成)\n"


static func build(card: Dictionary, art_report: Array) -> String:
	var type := str(card.get("card_type", ""))
	var id := str(card.get("id", ""))
	var L: Array[String] = []
	L.append(HEAD)
	L.append("你是本仓库(领《AGENTS.md》为工程纪律)的施工 agent。本卡由素材编辑器产出,")
	L.append("按下面第 1~6 节施工。开工先 `git rev-parse HEAD` 对不齐即停;共享历史线纪律见 AGENTS.md。")
	L.append("")
	L.append("## 0. 美术资产政策(最高优先级,画师产出制)")
	L.append("- 所有美术资产的正式版本由人工画师产出;**带 [人工] 标记的美术槽文件绝对禁止改动/覆盖/重生成**。")
	L.append("- 带 [AI占位] 或 [缺失] 的槽位:可用 DevTools/gen_portrait.gd 程序化生成占位,")
	L.append("  且必须**尽可能接近原作风格**(32px 像素网格、暗底亮边+深色描边、3/4 俯视角、")
	L.append("  青蓝主色调、限定调色板;禁止外部素材/照片/FastNoiseLite)。占位仅用于临时测试。")
	L.append("- 生成占位后为文件写 <同名>.meta(内容 source=ai),绝不能碰人工文件的 meta。")
	L.append("")
	L.append("## 1. 当前美术槽状态(编辑器实测)")
	for line in art_report:
		L.append("- " + str(line))
	L.append("")
	L.append("## 2. 卡数据(单一事实来源)")
	L.append("```json")
	L.append(JSON.stringify(card, "\t"))
	L.append("```")
	var notes := str(card.get("notes", "")).strip_edges()
	L.append("")
	L.append("## 3. 特殊要求(编辑器备注,逐字执行,与卡数据冲突时以本节为准)")
	L.append(notes if notes != "" else "(无)")
	L.append("")
	L.append("## 4. 施工范围(路径白名单,禁越界)")
	L.append("- 卡文件:DevTools/cards/%ss/%s.json(数值与第 2 节一致)" % [type, id])
	match type:
		"weapon":
			var slot := int(card.get("slot", 0))
			if slot == 0:
				L.append("- 纯设计稿:实现为独立武器场景 DevTools 评审稿,不改现役注册表;")
				L.append("  或按卡内说明给出施工稿。不得改 Scenes/Player/weapon_component.gd 的 WEAPONS 现役槽。")
			elif slot <= 6:
				L.append("- 现役槽 %d:改对应武器场景与数值(以卡为准);需要新机制才允许改 WeaponBase/WeaponComponent。" % slot)
			else:
				L.append("- 扩槽 %d:WeaponComponent.WEAPONS 注册表加槽位 + project.godot 注册输入动作 + 新场景。" % slot)
			L.append("- 武器场景:Scenes/Weapons/(现役 1~6 对应 pistol_test/rifle_test/m82a1/s686/grenade_launcher/laser_gun)")
			L.append("- 人工素材保护:DevTools/cards/weapons/%s__silhouette.png、__gun.png、__bullet.png 若标记 [人工] 禁改。" % id)
		"operator":
			L.append("- 注册表:Globals/operators.json(新建或追加本卡条目,先确认 id 不存在)")
			L.append("- 干员组件:Scenes/Player/operator_component.gd + Scenes/Player/Skills/<id>_skill_<n>.gd(按卡 skills 实现技能)")
			L.append("- 人工素材保护:DevTools/cards/operators/%s__body.png 若标记 [人工] 禁改。" % id)
		"prop":
			L.append("- 道具施工:道具系统(注册表/投掷物/效果)按 kind 与 kind_params 实现;槽位 %s。" % str(card.get("slot", 0)))
			L.append("- 人工素材保护:DevTools/cards/props/%s__world.png 若标记 [人工] 禁改。" % id)
	L.append("")
	L.append("## 5. headless 验证(全部通过才算完)")
	L.append("- `Godot_console --headless --path . --quit-after 60` 零 SCRIPT ERROR;")
	L.append("- 引用本卡的最小自测(构造实例/加载注册表)无运行时错误;")
	L.append("- 改了公共组件(WeaponBase/OperatorComponent 等)必须跑 Tests/enemy_logic_smoke.gd 与 player_contract_smoke.gd 不回归。")
	L.append("")
	L.append("## 6. 提交与回报")
	L.append("- 完成后 git add/commit(规范 message,不 push);")
	L.append("- 末行输出:`CARD-DONE %s/%s rev%s`(卡 rev 号见 JSON)。" % [type, id, str(card.get("rev", 1))])
	return "\n".join(L) + "\n"


## 美术槽状态报告(编辑器把 EditorArt 的实测状态喂进来)
static func art_report_lines(type: String, id: String) -> Array:
	var out: Array = []
	for s in EditorSchema.art_slots(type, id):
		var st := EditorArt.slot_status(type, id, str(s["key"]))
		var tag := "[人工]" if st == "human" else ("[AI占位]" if st == "ai" else "[缺失]")
		out.append("%s %s(%s)→ %s | %s" % [tag, s["label"], s["key"], s["file"], s["desc"]])
	return out
