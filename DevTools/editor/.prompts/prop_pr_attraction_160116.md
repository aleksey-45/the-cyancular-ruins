# 素材卡施工提示词(素材编辑器自动生成)

你是本仓库(领《AGENTS.md》为工程纪律)的施工 agent。本卡由素材编辑器产出,
按下面第 1~6 节施工。开工先 `git rev-parse HEAD` 对不齐即停;共享历史线纪律见 AGENTS.md。

## 0. 美术资产政策(最高优先级,画师产出制)
- 所有美术资产的正式版本由人工画师产出;**带 [人工] 标记的美术槽文件绝对禁止改动/覆盖/重生成**。
- 带 [AI占位] 或 [缺失] 的槽位:可用 DevTools/gen_portrait.gd 程序化生成占位,
  且必须**尽可能接近原作风格**(32px 像素网格、暗底亮边+深色描边、3/4 俯视角、
  青蓝主色调、限定调色板;禁止外部素材/照片/FastNoiseLite)。占位仅用于临时测试。
- 生成占位后为文件写 <同名>.meta(内容 source=ai),绝不能碰人工文件的 meta。

## 1. 当前美术槽状态(编辑器实测)
- [缺失] 卡面图(card)→ props/pr_attraction.png | 编辑器展示
- [缺失] 对局内贴图(设计稿)(world)→ props/pr_attraction__world.png | 投掷物/落地震体像素图;当前道具实体为程序化绘制,此图供施工参考

## 2. 卡数据(单一事实来源)
```json
{
	"appearance": "青蓝色圆柱罐体,罐体螺旋吸入纹样,顶部引信带小涡旋标(像素风)",
	"attack_interval": 0.8,
	"bullet_gravity": 0.45,
	"bullet_range": 1100.0,
	"bullet_size": 1.4,
	"bullet_speed": 950.0,
	"card_type": "prop",
	"created_at": "2026-09-12T14:19:29",
	"damage": 0.0,
	"description": "无伤吸引弹:与击退炮同构,效果换成把范围内所有实体(含子弹/自己)吸向爆心,不造成伤害。每次复活只能携带 2 枚。影响范围极大（至少十个身位），吸力极强（按照距离爆炸中心线性衰减）",
	"full_auto": false,
	"heavy_aim": false,
	"id": "pr_attraction",
	"impact": 0.0,
	"jump_penalty": 1.0,
	"kind": "attraction",
	"kind_params": {
		"blast_force": -50.0,
		"blast_radius": 900.0,
		"fuse_time": 0.5,
		"smoke_duration": 0.0
	},
	"mag_size": 2.0,
	"move_penalty": 1.0,
	"name": "引力核心",
	"notes": "第一次撞墙之后触发零点五秒的延迟引信，这期间外围不断有像素白环由爆炸影响范围的最外端向内收缩（这期间由虚变实）。\n最后一个白环收束至最中心时，爆炸·。",
	"pellet_count": 1.0,
	"reload_time": 0.0,
	"rev": 18.0,
	"schema_version": 1.0,
	"slot": 9.0,
	"spread_deg": 0.0,
	"tier": "light",
	"updated_at": "2026-09-13T16:01:16"
}
```

## 3. 特殊要求(编辑器备注,逐字执行,与卡数据冲突时以本节为准)
第一次撞墙之后触发零点五秒的延迟引信，这期间外围不断有像素白环由爆炸影响范围的最外端向内收缩（这期间由虚变实）。
最后一个白环收束至最中心时，爆炸·。

## 4. 施工范围(路径白名单,禁越界)
- 卡文件:DevTools/cards/props/pr_attraction.json(数值与第 2 节一致)
- 道具施工:道具系统(注册表/投掷物/效果)按 kind 与 kind_params 实现;槽位 9.0。
- 人工素材保护:DevTools/cards/props/pr_attraction__world.png 若标记 [人工] 禁改。

## 5. headless 验证(全部通过才算完)
- `Godot_console --headless --path . --quit-after 60` 零 SCRIPT ERROR;
- 引用本卡的最小自测(构造实例/加载注册表)无运行时错误;
- 改了公共组件(WeaponBase/OperatorComponent 等)必须跑 Tests/enemy_logic_smoke.gd 与 player_contract_smoke.gd 不回归。

## 6. 提交与回报
- 完成后 git add/commit(规范 message,不 push);
- 末行输出:`CARD-DONE prop/pr_attraction rev18.0`(卡 rev 号见 JSON)。
