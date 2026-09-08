# ESC 菜单 + PvP HUD 微调设计(2026-09-08)

## 目标

1. **PvP 双方头顶名字同色**:不再按角色区分颜色,统一为中性亮白。
2. **PvP 中央公告两行各自居中**:大标题 + 小副标两行,各自在屏幕水平居中(短行落长行正下方正中),对所有中央公告统一生效。
3. **ESC 呼出菜单(单机 + PvP)**:灰色半透明全屏遮罩 + 居中一个「退出」按钮。**单机**呼出后游戏暂停;PvP 不暂停(在线无法暂停),仅弹遮罩并锁定本地操作。「退出」两种模式都**回主菜单**(PvP 先断连对局)。

## 现状(2026-09-08 代码基线)

- 名字:`scenes/pvp_client.gd` `_on_peer_info` 给 `_id_self`/`_id_opp`(两个 `scenes/player/world_label.gd` 世界空间 Node2D,`draw_string` 居中画、黑描边、`ALPHA=0.85`)按 `ROLE_COLOR = {1: 淡青, 2: 淡橙}` 上色。
- 广播:`ui/pvp_hud.gd`(`class_name PvpHud`)中央公告层 = `Mask`(全屏黑 0.3 ColorRect)+ `Center`(CenterContainer)/`VBox`(`BigLabel` 150px + `SubLabel` 64px)。布局在 `ui/pvp_hud.tscn`。公告有:开局 `_set_broadcast(true,"对战开始","第 1 局")`、倒计时(大号数字,`_process` 续写)、本局胜败、整场胜败、断线 `show_notice("对手已离开","对局结束")`。VBox 里 Label 默认**左对齐** → 短行靠块左缘、未单独居中。
- ESC/暂停:全项目无 ESC 处理、无 `get_tree().paused`;单人局无退出入口。退出对局现有两条写死路径:MATCH_OVER(5s 延时)、对手断线(2.5s),都 `NetBus.stop()` + `change_scene(main_menu)`。
- 场景承载:单人 = `main_menu` → `change_scene` `scenes/Level0.tscn`(根 = `level_0.gd`,内含 `WorldViewport`/`HUD` CanvasLayer 129 等);PvP = `scenes/pvp_game.tscn` → 根 `pvp_client.gd` 自己实例化一份 `Level0` 当世界(`Level0.pvp_mode=true` 先行置位)+ 补 `PostProcess` + `pvp_hud`(layer 130)。
- 角色区分:P2 本体走 `player_p2_hue.gdshader` 色相旋转,与名字颜色无关。

## 设计

### 改动 1:PvP 名字统一中性亮白

`pvp_client.gd`:

- 把 `_on_peer_info` 里 `ROLE_COLOR.get(...)` 改为一个共享常量 `NAME_COLOR := Color(0.94, 0.95, 0.98, 1.0)`(world_label 内部仍叠 0.85 alpha)。
- `ROLE_COLOR` 若不再被任何处引用即删除(实现时全局查一次;P2 色相走 shader,不依赖它)。

### 改动 2:PvP 中央公告两行各自居中

`ui/pvp_hud.tscn`:

- `Center/VBox/BigLabel` 与 `Center/VBox/SubLabel` 都加 `horizontal_alignment = 2`(CENTER)。
- VBox 内两行同宽(取最宽行),文字各自在各自行内居中 → 两行都居中、小行落大标题正下方正中。
- 走 `_set_broadcast` / `show_notice` 的全部公告统一生效;`ui/pvp_hud.gd` 逻辑零改动。

### 改动 3:ESC 菜单(新 `ui/esc_menu.tscn` + `ui/esc_menu.gd`,复用一份)

**结构**:根 `CanvasLayer`(layer 150,盖过 单机 HUD 129 / PvP HUD 130 / PostProcess 128;`process_mode = PROCESS_MODE_ALWAYS(3)`,子节点随继承,暂停期仍能收键鼠):

- `Mask` 全屏 `ColorRect`,`mouse_filter = STOP`(挡底层鼠标点穿),灰色半透明(初值约 `Color(0.18, 0.18, 0.2, 0.55)`,可微调)。
- `Center`(CenterContainer)内 `VBox`:一个 `ExitButton`「退出」(可选用像素字体 + 放大字号,风格同 HUD;实现从 tscn 编辑器配即可)。

**脚本 API**(`class_name EscMenu`):

- `var pauses_game := false`(宿主在实例化后设置)。
- `var exit_callback: Callable = Callable()`(宿主注入「退出」动作)。
- `signal toggled(open: bool)`(宿主据此刻画暂停/锁输入)。
- `func _process`:仅在收到 `Input.is_action_just_pressed("ui_cancel")` 且宿主允许(`can_toggle` 为真)时切换开/关并 `emit_signal("toggled", open)`;再按 ESC = 收起。
- 菜单自身的根默认 `visible = false`;打开时置可见,关闭时隐藏。`ExitButton.pressed` → `exit_callback.call()`。

**接线——单人**(`scenes/level_0.gd`,`_ready` 中仅当 `not Level0.pvp_mode` 时):

- 实例化 `esc_menu.tscn` 作子节点;`pauses_game = true`;`exit_callback` = 解暂停 + 回主菜单(`change_scene(main_menu)`),切场景前先 `get_tree().paused = false`(把暂停复位,别带进主菜单)。
- `toggled(open)` 信号 → `get_tree().paused = open`(整份单机模拟冻结/解冻)。

**接线——PvP**(`scenes/pvp_client.gd`,`_ready`):

- 实例化 `esc_menu.tscn` 作子节点;`pauses_game = false`;`exit_callback` = `NetBus.stop()` + `change_scene(main_menu)`(与现有断线/MATCH_OVER 同路径;服务器侧自动拆局,对手看到「对手已离开」)。
- `toggled(open)` 信号 → 本地锁输入:`_local.set_controls_locked(open or _round_locked)`。
  - `_round_locked`:pvp_client 已有的「COUNTDOWN 冻结」状态(现 `_on_round_state` 里 `state == 0` 即锁)。菜单关时按 `_round_locked` 还原,避免菜单收在倒计时里把玩家提前解冻。
- **`_match_ended`(对局已结束或对手已走)后不再响应 ESC**(`can_toggle = false`),避免与自动回菜单的定时器打架。

**边界/错误处理**:

- 单机暂停期间,菜单自身因 `process_mode=ALWAYS` 照常处理 ESC 与按钮;其余节点(玩家/敌人/相机/水流/tween/Timer)全部冻结,关菜单即恢复。
- 单机若从其他路径离开场景(如倒地按 R 重载),此时未暂停,无残留风险;但「退出」路径必须显式解暂停再切场景。
- PvP 菜单打开期间对手实时仍可行动/命中——在线语义,接受(菜单应短暂使用)。

**测试**:

- 建议新增源码级冒烟 `tests/esc_menu_smoke.gd`(`extends SceneTree`,`-s` 跑):实例化 `esc_menu.gd`(不依赖 UI 渲染),直接调其开/关方法,断言 `toggled` 信号、`paused` 在 `pauses_game=true` 宿主接法下翻转、退出回调被触发;顺带断言 改动 1/2 属纯 tscn/常量改动不破坏 `pvp_hud` 信号链路(可并入 `laser_weapon_smoke` 之外的既有源码级冒烟或在 smoke 内 `load()` 即可,细节由实现计划定)。
- 改动 1/2 主要靠用户肉眼验收(名字白字、两行各自居中)。

## 涉及文件

- 改:`scenes/pvp_client.gd`、`ui/pvp_hud.tscn`、`scenes/level_0.gd`
- 新:`ui/esc_menu.gd`(+.uid)、`ui/esc_menu.tscn`、可能 `tests/esc_menu_smoke.gd`(+.uid)
- 文档:本 spec
