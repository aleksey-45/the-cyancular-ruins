# `tests/manual/` —— 人工仪器(不是守卫,不进任何批)

> **为什么有这个目录**(由来:`docs/eng/test-economy.md` 的 **D2**):这些文件原来住在
> `tests/probe/`,让"枚举到 140 个文件"这个数字虚高,而它们**不产生判词、没有断言、不可能红**
> —— 入口只能把它们逐条排除、并给每条写一段"为什么不是守卫"。**它们不是测试,是仪器**:
> 取一张图、读一组数、按下按键看回调顺序。放在 `tests/` 的 glob 里,只会让入口的排除表越长越像
> 一份自我辩护。
>
> ⇒ 迁到这里之后:① 它们**不进** `tests/smoke/*.gd` / `tests/probe/*.tscn` 任何 glob,
> ② 任何入口都不枚举它们,③ 需要时**人**按下面的方式手工跑。

## 这里的文件分两类

**① 必须真渲染(不能加 `--headless`,会弹窗)**:`combat_hud_visual_probe` / `hue_tint_probe` /
`kh_l3_visual_probe` / `kh_l4_visual_probe` / `kh_visual_probe` / `match_result_probe` /
`menu_shot_probe` / `minimap_circle_probe` / `render_forensics` / `squash_stretch_probe`

```bash
# ★ 不带 --headless:带上就没有视口纹理、静默不存图
"$GODOT" --path . --quit-after 300 res://tests/manual/<名>.tscn
```

**② headless 可跑、但只打印读数(没有判词 ⇒ 判据读不了它)**:
`aim_probe` / `aim_direction_probe` / `climb_probe` / `muzzle_probe` / `order_probe` /
`preview_probe` / `tile_destroy_probe`

```bash
"$GODOT" --headless --path . -s res://tests/manual/<名>.gd
# 判据是**人读输出**(例如 climb_probe 的 latched=),不是 grep 判词 —— 所以它当不了守卫
```

## 纪律

- **别把它们塞回 `tests/probe/`**:回去了就会重新出现在枚举里,而它们的"排除理由"就得重写一遍
  (这正是 D2 要消灭的那笔税)。
- **想让其中某一个变成真守卫**:就给它加**判词行 + 条数闸 + 至少一条能红的断言**,然后按
  `docs/eng/test-economy.md` 的 **K1–K5** 判断它值不值 —— 值,才搬回 `tests/probe/`。
- 历史文档(`docs/superpowers/**`、`docs/archive/**`)里的 `tests/probe/<这些名字>` **是有意不追改**的:
  那是**当时的记录**,不是现行规范(见 `docs/archive/README.md`)。
