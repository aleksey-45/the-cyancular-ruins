class_name PromptBuilder
extends RefCounted

# 提示词生成器(DevTools):把一张卡变成给 Claude Code 的施工合同。
# 只懂「卡 → agent 合同」;进程管理在 agent_runner.gd。
# 模板分派按 cards/.state.json 的游戏侧现状标记:
#   干员:骨架未建 → OPERATOR_FIRST(搭骨架+本卡);已建 → OPERATOR_NEXT(仅增量)
#   武器:slot>5 且槽位未重构 → WEAPON_FIRST(一次性去硬编码+本枪);否则 WEAPON_NEXT
#         kind=melee 且近战分支未建 → 追加近战段;slot=0 → WEAPON_DESIGN(纯设计稿)

const STATE_FLAGS := ["operator_skeleton_done", "slot6_refactor_done", "melee_branch_done"]

const HEAD_MARK := "__CLAUDE_EXIT_"


## 返回 {prompt: String, template: String, set_flags: Array[String]}
## set_flags = 施工成功(CARD-DONE)后要翻转的 .state.json 标记
static func build(card: Dictionary, state: Dictionary) -> Dictionary:
	var type := str(card.get("card_type", ""))
	if type == CardSchema.TYPE_OPERATOR:
		return _build_operator(card, state)
	if type == CardSchema.TYPE_PROP:
		return _build_prop(card, state)
	return _build_weapon(card, state)


# ── 公共骨架(所有模板共用)──

static func _header(title: String, card: Dictionary, whitelist: Array) -> Array:
	var L: Array[String] = []
	L.append("# 任务:%s" % title)
	L.append("")
	L.append("仓库:The Cyancular Ruins(Godot 4.7.1),本提示词所在工作目录即仓库根。")
	L.append("")
	L.append("## 0. 工程纪律(逐条自查,违反任何一条即停下报告)")
	L.append("- 动手前先读 AGENTS.md;与本文冲突时以本文为准。")
	L.append("- 目录职责:Scenes/(场景+平级 gd) Globals/(静态类+参数+json 数据表) server/(服务端专用)")
	L.append("  Tests/(诊断探针) DevTools/(开发工具与卡数据,游戏代码禁止引用) assets/(贴图) editor/(浏览器编辑器)。")
	L.append("- 参数分层:共享=GameParameters;玩家=PlayerParams;敌人=EnemyParams(嵌套类);武器=tscn @export;")
	L.append("  数据表=Globals/*.json;会话选项=RunOptions/PvpSession/Settings。禁止新增全局散变量。")
	L.append("- autoload 仅 4 个(GameParameters/NetBus/NetBusExt/Settings):禁止新增;禁止改 Globals/net_bus.gd")
	L.append("  (须与原作者逐字节一致);联机协议扩展只进 Globals/net_bus_ext.gd。本次是单机功能,不碰联机。")
	L.append("- UI 纯代码构建(参考 Scenes/royale_lobby.gd):根 Control 必须 set_anchors_and_offsets_preset")
	L.append("  (Control.PRESET_FULL_RECT);像素字体 res://assets/fonts/less_perfect_dos_vga.ttf;.tscn 只做 6-12 行壳。")
	L.append("- 玩家组件(仿 Climb/Combat/Swim)不写自己的 _physics_process,由 player.gd 根循环按序驱动。")
	L.append("- 环面纪律:实体间方向/距离一律 MazeGenerator.toroidal_*(toroidal_dist 是 4 参签名),禁止裸坐标相减。")
	L.append("- 冒烟测试由用户自己跑;你只允许 headless 诊断探针与 --quit-after 启动检查。")
	L.append("")
	L.append("## 1. 允许写入的路径(硬约束;白名单外一律禁写)")
	for p in whitelist:
		L.append("- %s" % p)
	L.append("- 禁改 export_presets.cfg、Globals/net_bus.gd、server/ 下任何文件;禁止动 DevTools/ 内未点名文件。")
	L.append("")
	L.append("## 2. 卡数据(单一事实来源,不可改动其数值)")
	L.append("```json")
	L.append(JSON.stringify(card, "\t"))
	L.append("```")
	L.append("")
	return L


static func _commit_section(L: Array[String], head: String) -> void:
	L.append("## 6. 提交规范")
	L.append("- 开工前运行 git rev-parse HEAD,应为 `%s`;不一致(有并行会话动了历史)→ 停下报告,禁止继续。" % head)
	L.append("- Conventional Commits 中文主题;本任务一个 commit(可拆「重构」「内容」两个)。")
	L.append("- 只 add 白名单内文件;提交前 git status 检查不卷入他人改动。")
	L.append("- 禁止 reset/rebase/push。")
	L.append("")


static func _art_section(L: Array[String], card: Dictionary) -> void:
	var type := str(card.get("card_type", ""))
	var id := str(card.get("id", ""))
	L.append("## 4. 头像/剪影像素画(程序化生成,零外部素材)")
	L.append("- 新建(已存在则扩展)DevTools/gen_portrait.gd:extends SceneTree 的 -s 脚本,")
	L.append("  按 `--card=%s/%s` 用户参数(OS.get_cmdline_user_args)分派;每张新卡加一个分支函数,不重写旧分支。" % [type, id])
	L.append("- 用 Image/set_pixel/fill_rect 纯程序化绘制,按卡 appearance 描述取形;低饱和像素风,")
	L.append("  对齐 assets/textures/weapons.png 与 player.png 的观感;禁止 FastNoiseLite(构建 profile 已禁)、")
	L.append("  禁止引用任何外部图片/在线素材。")
	if type == CardSchema.TYPE_OPERATOR:
		L.append("- 产出 1:头像 assets/operators/%s.png(尺寸 %s,透明或深色底,带 1px 描边),并复制一份到" % [id, str(card.get("portrait", {}).get("size", [96, 96]))])
		L.append("  DevTools/cards/operators/%s.png(编辑器头像页读这份)。" % id)
		if str(card.get("texture_mode", "tint")) == "sheet":
			L.append("- 产出 2:皮肤图集 assets/operators/%s_sheet.png —— 48×48 帧图集 4 列×3 行,布局与" % id)
			L.append("  assets/textures/player.png 完全一致:idle(2帧)/move(4帧)/fly(1帧)/charge(1帧)/squat(4帧),")
			L.append("  player.gd 的 POSE_ANIM 姿态映射按此驱动;逐帧程序化画(区分姿态剪影,允许简化)。")
	else:
		L.append("- 产出:武器贴图 assets/weapons/%s.png(建议 ≤96×48 透明底,水平持握朝向),并复制一份到" % id)
		L.append("  DevTools/cards/weapons/%s.png(编辑器剪影页读这份)。" % id)
	L.append("- 运行验证(必须贴输出):\"C:/Godot/Godot_v4.7.1-stable_win64_console.exe\" --headless --path . -s res://DevTools/gen_portrait.gd -- --card=%s/%s" % [type, id])
	L.append("  脚本末尾 print(\"GEN OK\");运行后确认两个 PNG 确实生成。")
	L.append("")


static func _verify_section(L: Array[String], card: Dictionary) -> void:
	L.append("## 5. 验证(全部 headless,逐条执行并把输出摘要写进回报)")
	L.append("1. 启动检查:\"C:/Godot/Godot_v4.7.1-stable_win64_console.exe\" --headless --path . --quit-after 120 → 无 SCRIPT ERROR。")
	var type := str(card.get("card_type", ""))
	if type == CardSchema.TYPE_WEAPON:
		L.append("2. 剪影可用:临时 -s 脚本断言 WeaponComponent.silhouette(%d) 返回非空纹理,验完删除该临时脚本。" % int(card.get("slot", 0)))
	if type == CardSchema.TYPE_OPERATOR:
		L.append("2. 玩家契约:-s res://Tests/player_contract_smoke.gd → 通过(若该探针因你的改动失败,先修再交)。")
		L.append("3. 选人 UI 改了主菜单 → res://Tests/ui_audit.tscn -- --scene=res://Scenes/main_menu.tscn → 无越界。")
	L.append("")
	L.append("## 7. 完成回报(最终输出,逐项列出)")
	L.append("- 文件清单(新增/修改,含路径)/ 每条验证的输出摘要 / 未尽事项与风险。")
	L.append("- 最后一行必须是:CARD-DONE %s/%s rev%d" % [type, str(card.get("id", "")), int(card.get("rev", 1))])
	L.append("")


# ── 干员 ──

static func _build_operator(card: Dictionary, state: Dictionary) -> Dictionary:
	var first := not bool(state.get("operator_skeleton_done", false))
	var id := str(card.get("id", ""))
	var L: Array[String] = []
	var flags: Array[String] = []
	var whitelist: Array = []
	var title := ""
	if first:
		title = "搭建干员系统骨架,并落地第一张干员卡(%s / %s)——单机生效" % [str(card.get("name", "")), id]
		whitelist = [
			"Globals/operators.json(新建)",
			"Globals/operator_registry.gd(新建)",
			"Scenes/Player/operator_component.gd(新建)",
			"Scenes/Player/Player.tscn(仅挂新组件节点)",
			"Scenes/Player/Skills/(新建目录:skill_base.gd 与各技能 gd)",
			"Scenes/Player/player.gd(根循环驱动技能组件 + _ready 应用干员参数)",
			"Scenes/level_0.gd(单机路径读 RunOptions 选干员)",
			"Globals/run_options.gd(加 static var operator_id)",
			"Scenes/main_menu.gd(选干员面板,新旧两套 UI 都要加)",
			"Scenes/hud.gd(左上角显示当前干员名)",
			"project.godot(仅 [input] 注册 skill_1/skill_2/skill_3 动作,默认键 Z/X/C)",
			"assets/operators/(新建目录)",
			"DevTools/gen_portrait.gd(新建)",
			"DevTools/cards/operators/%s.png(头像副本)" % id,
			"Tests/(可新建临时探针,验完删除)",
		]
	else:
		title = "落地一张新干员卡(%s / %s)——骨架已存在,只做增量" % [str(card.get("name", "")), id]
		whitelist = [
			"Globals/operators.json(追加本卡条目)",
			"Scenes/Player/Skills/%s_*.gd(本卡各技能一个脚本,继承 SkillBase)" % id,
			"assets/operators/",
			"DevTools/gen_portrait.gd(仅追加本卡分支)",
			"DevTools/cards/operators/%s.png(头像副本)" % id,
			"Tests/(可新建临时探针,验完删除)",
		]
	L.append_array(_header(title, card, whitelist))
	if first:
		flags = ["operator_skeleton_done"]
		L.append("## 3. 施工清单(骨架部分——一次建好,供后续所有干员复用)")
		L.append("1. 注册表 Globals/operators.json(格式仿 editor/enemies.json 的数据表风格)+ 加载器")
		L.append("   Globals/operator_registry.gd:static load_all() 读 json → {id → 卡数据};容错照抄")
		L.append("   Scenes/Enemies/enemy_spawner.gd 的 load_types()(缺文件/坏 JSON → push_error 返回空)。")
		L.append("2. Scenes/Player/operator_component.gd 挂到 Player.tscn(与 Climb/Combat/Swim 并列):")
		L.append("   apply_operator(card: Dictionary) 在根 _ready 参数初始化前后调用,直接覆盖实例字段:")
		L.append("   combat.max_hp/hp(Scenes/Player/combat_component.gd:16-17 本就是实例 var)、")
		L.append("   body.move_speed 等按 stats 倍率乘;护甲=受伤减免。零架构改动,不改 PlayerParams 常量。")
		L.append("   外貌:texture_mode=tint → 复用 Scenes/Player/player_p2_hue.gdshader 挂 AnimatedSprite2D;")
		L.append("   sheet → 按卡图集代码重建 SpriteFrames 替换(参考 Player.tscn 内嵌帧布局)。")
		L.append("3. 技能骨架:Scenes/Player/Skills/skill_base.gd(class_name SkillBase extends Node):")
		L.append("   每技能一个子节点,持 {key, cooldown};无自身 _physics_process,由 player.gd 根循环")
		L.append("   调 update(delta, input_source);释放判定走 input_source.is_action_just_pressed(key)")
		L.append("   (Globals/input_source.gd 的泛型动作查询,InputSource 零改动)。各技能行为按卡内描述实现。")
		L.append("4. 选人链路:Globals/run_options.gd 加 static var operator_id(空=默认);Scenes/level_0.gd")
		L.append("   单机路径(menu_demo/pvp_mode 早退之后)在玩家 _ready 前应用;Scenes/main_menu.gd")
		L.append("   单人面板(_build_sp_panel 模式)加「选择干员」:头像+名字+技能列表点选;新旧两套 UI")
		L.append("   (main_menu.gd 两个构建函数与两个按钮数组)都要加。")
		L.append("5. HUD 左上角显示当前干员名(最小侵入,Scenes/hud.gd)。")
		L.append("6. 本卡施工:operators.json 写入第 2 节卡数据;各技能按描述实现;外貌/头像见第 4 节。")
		L.append("")
	else:
		L.append("## 3. 施工清单(增量——骨架已存在,禁止重复搭建/改动骨架文件)")
		L.append("1. Globals/operators.json 追加本卡条目(先 load_all 确认 id 不存在)。")
		L.append("2. 本卡各技能:Scenes/Player/Skills/%s_<n>.gd 继承 SkillBase,按卡内描述实现;" % id)
		L.append("   若发现骨架文件缺失(SkillBase/operator_component/注册表),停下报告,禁止自行搭建。")
		L.append("3. 外貌/头像:见第 4 节。")
		L.append("")
	_art_section(L, card)
	_commit_section(L, _git_head())
	_verify_section(L, card)
	return {"prompt": "\n".join(L), "template": "OPERATOR_FIRST" if first else "OPERATOR_NEXT", "set_flags": flags}


# ── 武器 ──

static func _build_weapon(card: Dictionary, state: Dictionary) -> Dictionary:
	var id := str(card.get("id", ""))
	var slot := int(card.get("slot", 0))
	var kind := str(card.get("kind", "gun"))
	var need_refactor := slot > 5 and not bool(state.get("slot6_refactor_done", false))
	var need_melee := kind == "melee" and not bool(state.get("melee_branch_done", false))
	var design_only := slot == 0
	var L: Array[String] = []
	var flags: Array[String] = []
	var whitelist: Array = []
	var title := ""
	var template := ""
	if design_only:
		template = "WEAPON_DESIGN"
		title = "武器设计稿(%s / %s):只生成贴图与剪影,不注册进游戏" % [str(card.get("name", "")), id]
		whitelist = [
			"assets/weapons/",
			"DevTools/gen_portrait.gd(仅追加本卡分支)",
			"DevTools/cards/weapons/%s.png(剪影副本)" % id,
		]
		L.append_array(_header(title, card, whitelist))
		L.append("## 3. 施工清单")
		L.append("- 只做第 4 节贴图生成(slot=0 纯设计稿,不建 tscn、不动注册表)。")
		L.append("")
		_art_section(L, card)
		L.append("## 5. 验证:确认两个 PNG 生成即可(不进游戏)。")
		L.append("")
		_commit_section(L, _git_head())
		L.append("## 7. 完成回报(最终输出,逐项列出)")
		L.append("- 文件清单(新增/修改,含路径)/ 验证输出摘要 / 未尽事项与风险。")
		L.append("- 最后一行必须是:CARD-DONE %s/%s rev%d" % [CardSchema.TYPE_WEAPON, str(card.get("id", "")), int(card.get("rev", 1))])
		L.append("")
		return {"prompt": "\n".join(L), "template": template, "set_flags": flags}
	if need_refactor:
		template = "WEAPON_FIRST"
		title = "武器槽位去硬编码(一次性重构)+ 落地第一张新武器卡(%s / %s,槽位 %d)" % [str(card.get("name", "")), id, slot]
		whitelist = [
			"Scenes/Weapons/%s.tscn(新建)" % id,
			"Scenes/Weapons/weapon_base.gd(仅当 kind=melee 时追加近战段)",
			"Scenes/Player/weapon_component.gd(注册表 + MAX_SLOT 常量 + enabled_slots)",
			"Globals/input_source.gd(槽位扫描上限跟随 MAX_SLOT)",
			"project.godot(仅 [input] 注册数字槽位动作)",
			"Scenes/main_menu.gd、Scenes/matchmaking.gd、Scenes/royale_lobby.gd、Scenes/royale_game.gd、Scenes/pvp_client.gd(仅把硬编码 [1..5] 槽位列表改为遍历注册表)",
			"assets/weapons/",
			"DevTools/gen_portrait.gd(仅追加本卡分支)",
			"DevTools/cards/weapons/%s.png(剪影副本)" % id,
			"Tests/(可新建临时探针,验完删除)",
		]
	else:
		template = "WEAPON_NEXT"
		title = "落地一张新武器卡(%s / %s,槽位 %d)——槽位注册表已就绪,只做增量" % [str(card.get("name", "")), id, slot]
		whitelist = [
			"Scenes/Weapons/%s.tscn(新建)" % id,
			"Scenes/Weapons/weapon_base.gd(仅当 kind=melee 且近战段缺失时停下报告)",
			"Scenes/Player/weapon_component.gd(仅 WEAPONS/DISPLAY_NAMES 两行)",
			"assets/weapons/",
			"DevTools/gen_portrait.gd(仅追加本卡分支)",
			"DevTools/cards/weapons/%s.png(剪影副本)" % id,
			"Tests/(可新建临时探针,验完删除)",
		]
	L.append_array(_header(title, card, whitelist))
	if need_refactor:
		flags = ["slot6_refactor_done"]
		L.append("## 3. 施工清单(A 段=一次性重构,先做;只改枚举来源,禁动网络协议字段与禁枪语义)")
		L.append("A1. Scenes/Player/weapon_component.gd:加 const MAX_SLOT := %d;WEAPONS/DISPLAY_NAMES" % slot)
		L.append("    补本卡槽位;enabled_slots 与「至少留一把」校验改为按 MAX_SLOT 生成(替换 [1,2,3,4,5] 字面量)。")
		L.append("A2. Globals/input_source.gd:36 的 for i in range(1, 6) 改为 range(1, WeaponComponent.MAX_SLOT + 1)。")
		L.append("A3. project.godot [input] 注册动作 %d(数字键,格式抄现有 1~5)。" % slot)
		L.append("A4. 5 处选枪 UI 硬编码 [1,2,3,4,5] 改为遍历 WeaponComponent.WEAPONS 键:")
		L.append("    Scenes/main_menu.gd、Scenes/matchmaking.gd、Scenes/royale_lobby.gd、Scenes/royale_game.gd、Scenes/pvp_client.gd。")
	else:
		L.append("## 3. 施工清单(增量——禁止重复槽位重构;注册表已有 MAX_SLOT)")
		L.append("1. Scenes/Player/weapon_component.gd 的 WEAPONS/DISPLAY_NAMES 各加一行(槽位 %d," % slot)
		L.append("   先确认该槽位未被占用,被占则停下报告)。")
	if need_melee:
		flags.append("melee_branch_done")
		L.append("近战段(kind=melee,基类尚无近战判定——一次性扩展 weapon_base.gd):")
		L.append("  - WeaponBase 加 @export melee_range/melee_arc(值取卡 kind_params);开火瞬间以")
		L.append("    $Muzzle 为原点、按玩家瞄准方向做扇形/圆盘判定 enemies 组,命中走既有")
		L.append("    target.apply_hit → hurt(damage, dir, impact) 同路径(参考 weapon_base.gd:282-284);")
		L.append("    方向/击退向量用 MazeGenerator.toroidal_delta_px 最短环面向量(参考 Globals/explosion.gd)。")
		L.append("  - 挥击视觉:程序化白弧短命节点(参考 minimap/feedback 的纯代码画法);不接换弹")
		L.append("    (mag_size=0 时 reload 逻辑天然不触发,确认即可)。")
		L.append("  - 圆盘-格子判定可参考 weapon_base.gd 的 _disk_overlaps_solid。")
	L.append("tscn 段(两模板通用):")
	L.append("  - 新建 Scenes/Weapons/%s.tscn:根 Node2D 挂 weapon_base.gd,卡数值→对应 @export" % id)
	L.append("    (attack_interval→fire_cooldown;full_auto/heavy_aim→同名字段);子节点必须有同名")
	L.append("    Sprite2D(texture=assets/weapons/%s.png,region_enabled,region_rect=整图)与" % id)
	L.append("    Muzzle Marker2D(weapon_base.gd:129-130 @onready 硬依赖)。")
	if kind == "thrown":
		L.append("  - kind=thrown:bullet_scene 换 Scenes/Weapons/grenade_bullet.tscn 范式(新建专属弹体场景),")
		L.append("    引信/爆炸参数取卡 kind_params;preview_arc=true。")
	L.append("  - 剪影:region_rect 填对后 WeaponComponent.silhouette() 自动可用,无需美术步骤。")
	L.append("")
	_art_section(L, card)
	_commit_section(L, _git_head())
	_verify_section(L, card)
	return {"prompt": "\n".join(L), "template": template, "set_flags": flags}


# ── 工具 ──

static func _git_head() -> String:
	var output: Array = []
	OS.execute("git", ["rev-parse", "HEAD"], output, false, true)
	var head := str(output[0] if not output.is_empty() else "").strip_edges()
	return head if head.length() == 40 else "(未知——先向用户确认当前 HEAD)"


## CLI 启动器(.bat 内容)单点拼接:agent_runner 落盘执行,dry-run 审计共用。
## bat 必须零中文:cmd 按 ANSI 代码页解析批处理,UTF-8 中文路径(如仓库名"别人的游戏demo")
## 会全部乱码 → cd/重定向逐行"找不到路径",claude 静默不执行(UI 永远"工作中"的实测根因)。
## 因此仓库根不用传入的绝对路径,而从 bat 自身位置 %~dp0(.logs 目录)向上三级推导,
## 提示词/日志文件名只用 ASCII 的 <tag>;传入的 repo/prompt/log 仅用于取 tag 文件名。
static func build_cli_bat(repo_abs: String, prompt_abs: String, log_abs: String, extra_flags: String, permission_mode: String = "acceptEdits") -> String:
	var flags := "-p --permission-mode %s --output-format text --verbose" % permission_mode
	if not extra_flags.strip_edges().is_empty():
		flags += " " + extra_flags.strip_edges()
	var tag_file := prompt_abs.get_file()            # "<tag>.md"(纯 ASCII)
	var tag_base := tag_file.trim_suffix(".md")      # "<tag>"
	var L: Array[String] = [
		"@echo off",
		"setlocal enabledelayedexpansion",
		"rem repo root derived from this bat's own dir (<repo>/DevTools/cards/.logs): keeps this file ASCII-only",
		"set \"REPO=%~dp0..\\..\\..\"",
		"for %%i in (\"%REPO%\") do set \"REPO=%%~fi\"",
		"cd /d \"%REPO%\"",
		"set \"PROMPT=%%REPO%%\\DevTools\\cards\\.prompts\\%s\"" % tag_file,
		"set \"LOGF=%%REPO%%\\DevTools\\cards\\.logs\\%s.log\"" % tag_base,
		# 心跳:立刻把日志文件建出来,证明 bat 确实在执行(否则 UI 分不清"没拉起"和"在跑")
		"> \"%LOGF%\" echo __AGENT_STARTED__",
		"claude %s < \"%%PROMPT%%\" >> \"%%LOGF%%\" 2>&1" % flags,
		# 退出标记必须落进日志文件(poll 只读文件;旧版 echo 到 stdout/管道,完成状态永远收不到)
		">> \"%%LOGF%%\" echo %s!ERRORLEVEL!__" % HEAD_MARK,
	]
	return "\r\n".join(L) + "\r\n"


## 道具卡模板(最小可用):道具系统已在 KH_V1_1_4_propSys 落地(槽位 8/9/10 + BulletBase
## blast_force/smoke_duration + Globals/smoke.gd);agent 只需按卡参数在
## Scenes/Weapons/prop_launcher.gd + 对应 tscn 上调参/建场景,并把注册表补一行。
static func _build_prop(card: Dictionary, state: Dictionary) -> Dictionary:
	var whitelist: Array[String] = [
		"DevTools/cards/props/%s.json" % str(card.get("id", "")),
		"DevTools/cards/props/%s.png" % str(card.get("id", "")),
		"DevTools/gen_portrait.gd",
		"Scenes/Weapons/prop_launcher.gd",
		"Scenes/Weapons/prop_knockback.tscn",
		"Scenes/Weapons/prop_attraction.tscn",
		"Scenes/Weapons/prop_smoke.tscn",
		"Scenes/Player/weapon_component.gd",
		"Tests/prop_probe.gd",
	]
	var L := _header("道具实装:%s" % str(card.get("name", "")), card, whitelist)
	_art_section(L, card)
	L.append("## 3. 实装要求(道具系统已存在,不要重造)")
	L.append("- 槽位映射:knockback→8 / attraction→9 / smoke→10;注册进 WeaponComponent.PROP_SLOTS 顺序表。")
	L.append("- 场景:prop_launcher.gd 子类参数化(bullet_speed/bullet_range/bullet_gravity/mag_size=每命携带数)。")
	L.append("- 效果参数从 kind_params 取:blast_radius/blast_force(负=吸引)/smoke_duration/fuse_time。")
	L.append("- 美术:先 gen_portrait 生成贴近原作风格的像素画;亦可在编辑器「导入手绘素材」人工替换。")
	L.append("- headless 验证:Godot --headless --path . -s res://Tests/prop_probe.gd 输出 PROP PROBE: OK。")
	_verify_section(L, card)
	_commit_section(L, "feat(prop): 实装道具 %s(%s)" % [str(card.get("id", "")), str(card.get("kind", ""))])
	L.append("- 最后一行必须是:CARD-DONE %s/%s rev%d" % [CardSchema.TYPE_PROP, str(card.get("id", "")), int(card.get("rev", 1))])
	return {"prompt": "\n".join(L), "template": "PROP", "set_flags": [] as Array[String]}
