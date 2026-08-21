# FlyBird 死区下潜设计

日期: 2026-08-21
状态: 待实现
相关代码: `Scenes/Enemies/enemy_fly_base.gd`、`Scenes/Enemies/enemy_fly_bird.gd`、`Globals/enemyParams.gd`

## 背景与问题

玩家实测观察: FlyBird 会被卡在**天花板下方**，顶着天花板水平飞或原地悬停，**不会下潜去找玩家**。

根因: 死区(寻路空路径)时，鸟从头到尾收不到任何"向下"指令:

- 逃逸分支锁死 y: `enemy_fly_base.gd` 的 `_follow_path` 逃逸分支
  `_fly_straight_to(Vector2(_escape_target.x, global_position.y))` —— 目标 y 强制等于当前 y，只会水平扑腾。
- 逃逸列只在当前行找: `_find_escape_column()` 扫 `bc.y` 固定行。天花板很宽时当前行按飞行高度判
  全撞墙(`_bird_can_pass` 全 false) → 返回 `global_position` → 鸟原地悬停;偶扫到远端缺口则长途水平飞。
- 直线兜底目标反而更高: FLY 兜底 `_shoot_pos()` 在玩家上方 `hover_offset_y`=240px，只会往上拉。
- 寻路与物理脱节: A* 按 `hover_altitude` 上方的假想格判可走(`_bird_can_pass`)，鸟被压到天花板下时
  实际 y 与假想格脱节 —— "格子说全堵、鸟却还活着顶在那"。

## 方案

死区逃逸从"只扫当前行、只水平飞"改为 **逐行下探**: 当前行找不到可走列时往下逐行找**最近**的可走行，
逃逸目标带 y，鸟对角线下潜过去;到达后下次重寻路从新位置算。

核心直觉: 迷宫类地图里**越贴近地面越开阔**，鸟本来就是从地面起飞、爬升后才被困住的，原路下潜必然回到开放空间。

## 改动

### 1. 新参数 `EnemyParams.FlyBird.escape_max_descent`(默认 8 行 ≈ 128px)

下探最大行数，兼当下潜封顶: 正下方是洞/越界时不会无限掉。

### 2. `_find_escape_column()` 逐行下探

```
```
# 下飞优先:逐行下探,找第一个「鸟所在格可走」的行
for drop in 1..escape_max_descent:
    row = posmod(bc.y + drop, rows)        # 行取模,环面竖直也连续
    for dist in 1..escape_search_range:    # 每行再扫列,取最近可走格
        for side in [-1, 1]:
            cell = (posmod(bc.x + side*dist, cols), row)
            if _bird_can_pass(cell):
                return Vector2(cell.x * ts + ts * 0.5, cell.y * ts + ts * 0.5)
# 下潜失败(如地板级矮檐)→ 退回当前行水平逃逸(与改动前一致)
for dist in 1..escape_search_range:
    for side in [-1, 1]:
        cell = (posmod(bc.x + side*dist, cols), bc.y)
        if _bird_can_pass(cell):
            return Vector2(cell.x * ts + ts * 0.5, global_position.y)
return global_position                     # 全空 → 退回现状(悬停),不更糟
```

- **下飞优先**: 宽天花板当前行全堵时,先往下找**最近**可走行,鸟对角下潜过去;
  地板级矮檐下探无解时,当前行水平逃逸原样保留(窄檐横向挪出,零回归);
- **目标取可走格的格中心**(`cell.y * ts + ts / 2`),**不是飞行高度**: 鸟必须真的落进这个可走格,
  A* 才能从该格起路。飞行高度中心(格中心上方 `hover_altitude`=40px ≈ 2.5 格)会让鸟落在
  格上两行,那个格按飞行高度判仍堵 → 重寻路又空路径 → 原地振荡。这是实现计划阶段修正的设计点
  (spec 初稿写的是飞行高度,经盒体几何核算后改为格中心)。

### 3. `_follow_path()` 逃逸分支

`_fly_straight_to(Vector2(_escape_target.x, global_position.y))` → `_fly_straight_to(_escape_target)`。
去掉锁 y，鸟沿对角线下潜到逃逸目标;到达后下次重寻路(FLY/RETURN 的 `repath_interval`=0.7s)从新位置算，A* 应能通。

## 护栏

1. **下潜封顶**: `escape_max_descent` 天然兜住洞/越界;地板行(实心)会被 `_bird_can_pass` 判 false 自然跳过。
2. **脱困后不被拖回原天花板**: 下潜后 A* 从低位重算、绕墙走;`_shoot_pos` 目标不会穿过实心天花板。
   需要冒烟验证"脱困→重新接近"不形成爬升↔下潜振荡。
3. **不回归**: drop=0 与现有行为一致;若下探后仍空路径(如地板级矮檐)，退回现状悬停，不更糟。

## 冒烟验证

`Tests/enemy_logic_smoke.gd` 加一个断言: 构造"宽天花板 + 上方死区、下方开阔"的合成网格，把一只鸟放在
天花板下(该行 `_bird_can_pass` 全 false)，断言:

- `_find_escape_column()` 返回目标 y > 鸟当前 y(确实下探);
- 目标格 `_bird_can_pass` 为真(落在开阔行,A* 可起路);
- `_follow_path` 逃逸分支给向下的速度(velocity.y > 0,验证真在"下飞"而非锁 y 水平飞);
- 窄檐回归: 鸟仍能逃到可走格、不原地卡死(目标格 `_bird_can_pass` 为真)。

## 风险与回退

- 对角下潜路径可能被墙挡: `move_and_slide` 沿墙滑、重寻路自纠正，可接受。
- 下潜过程低空暴露给玩家: 属公平惩罚(鸟卡死本来就没威胁)，且下探取"最近可走行"、幅度有限。
- 全部失败: 仅 `_find_escape_column` + `_follow_path` 两处小改，git 可整体回退。
