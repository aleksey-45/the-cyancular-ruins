# 素材目录规范化设计

日期: 2026-08-21
状态: 待实现
相关系统: 项目素材目录结构（`Assets/`、`AssetBundle/`）、被引用的 `.tscn` / `.gd`、Godot `.import` 资源系统

## 概述

当前项目素材散落在两个根目录：`Assets/`（fonts）和 `AssetBundle/`（Sprites/Audio，Unity 风格命名），且 `AssetBundle/Audio/` 为空。本次统一为单个 Godot 惯例根目录 `res://assets/`，下分 `fonts/`、`textures/`，文件名转 snake_case，并顺手修复 `grenade_launcher.tscn` 中一处直接引用 `.godot/imported` 缓存（hash 名）的脆弱 SubResource。

设计原则（已与用户确认）：
- **统一单根** `res://assets/`，去掉 `Assets/`、`AssetBundle/` 两个旧根。
- **未用素材不删**：`Lotus.png`、`_jump_bird_preview.png`（无任何代码引用）随大部队移入 `assets/textures/` 保留；`map/_preview_compare.png` 留在 `map/` 不动。
- **不建空占位**：不加 `assets/audio/`，等真有音频再加。
- **保住 uid**：移动时 `.png` 与其 `.import` 一起走，uid 存于 `.import` 内，重导入后场景 `uid://` 引用不碎。
- **另一个 agent 正在改代码**（`Globals/enemyParams.gd`、`Scenes/Level0.tscn`），本次改动不得触碰这两个文件；工作在自己的分支 `refactor/standardize-assets` 上进行。

## 1. 目标结构

```
res://assets/
├── fonts/
│   └── less_perfect_dos_vga.ttf        (原 Assets/fonts/LessPerfectDOSVGA.ttf)
└── textures/
    ├── player.png                       (原 AssetBundle/Sprites/Player.png)
    ├── weapons.png                      (原 AssetBundle/Sprites/Weapons.png)
    ├── bullets.png                      (原 AssetBundle/Sprites/Bullets.png)
    ├── effects.png                      (原 AssetBundle/Sprites/Effects.png)
    ├── fly_bird.png                     (原 AssetBundle/Sprites/Fly_Bird.png)
    ├── jump_bird.png                    (原 AssetBundle/Sprites/Jump_Bird.png)
    ├── lotus.png                        (未用，保留)
    └── _jump_bird_preview.png           (未用，保留)
```

`AssetBundle/`（含空的 `Audio/`）、`Assets/` 整个移除。`map/demo.txt`、`map/_preview_compare.png`、`icon.svg` 不动。

## 2. 迁移方式

- 用 `git mv` 把每个 `.png`/`.ttf` 与对应的 `.import` 一起移到新路径。
- **不手改 `.import` 内部字段**（`source_file`、`path`、`dest_files`）：Godot 编辑器下次打开时会按新位置重导入并自行重写这些字段，同时保留 `.import` 里的 `uid`。
- 同步更新所有 `res://` 路径引用：
  - `.tscn` 的 `[ext_resource ... path="res://..."]`（保持 `uid` 与 `id` 不变，只改 path）
  - `Scenes/hud.gd:17` 的 `KILL_FONT_PATH`
- `.godot/` 是 gitignore 的缓存，不手改；重导入由编辑器完成。

## 3. 关键修复：`Scenes/Weapons/grenade_launcher.tscn`

现文件用 SubResource 直接指 `.godot/imported/Weapons.png-c4a6c69d089b50848ba40f862b49769f.ctex`（其他武器都是 ext_resource）。文件移动后该 ctex 会被重新生成、hash 变化，此引用必坏。

改为与其他武器一致的写法：
- 加 `[ext_resource type="Texture2D" uid="uid://cfbhunkx3526n" path="res://assets/textures/weapons.png" id="2_wpn"]`
- Sprite2D 的 `texture` 改用 `ExtResource("2_wpn")`
- 保留原 `region_rect = Rect2(3, 35, 51, 21)`
- 删掉 SubResource 定义

## 4. 需更新的引用清单

| 文件 | 改动 |
|---|---|
| `Scenes/Enemies/EnemyFlyBird.tscn` | path → assets/textures/fly_bird.png |
| `Scenes/Enemies/EnemyJumpBird.tscn` | path → assets/textures/jump_bird.png |
| `Scenes/Enemies/enemy_bullet.tscn` | path → assets/textures/bullets.png |
| `Scenes/Player/Player.tscn` | path → assets/textures/player.png |
| `Scenes/Weapons/bullet.tscn` | path → assets/textures/bullets.png |
| `Scenes/Weapons/explosion.tscn` | path → assets/textures/effects.png |
| `Scenes/Weapons/grenade_bullet.tscn` | path → assets/textures/bullets.png |
| `Scenes/Weapons/grenade_launcher.tscn` | SubResource → ext_resource（见 §3） |
| `Scenes/Weapons/m82a1.tscn` | path → assets/textures/weapons.png |
| `Scenes/Weapons/pistol_test.tscn` | path → assets/textures/weapons.png |
| `Scenes/Weapons/rifle_test.tscn` | path → assets/textures/weapons.png |
| `Scenes/Weapons/s686.tscn` | path → assets/textures/weapons.png |
| `Scenes/hud.gd` | KILL_FONT_PATH → res://assets/fonts/less_perfect_dos_vga.ttf |

`Globals/maze_generator.gd` 的 `MAP_FILE = "res://maps/demo.txt"` 引用 `map/`，`map/` 不动，无需改。

## 5. 验证

- 移动 + 改引用完成后，需要用户**开一次 Godot 编辑器**让资源重导入（或按项目约定自跑冒烟测试），确认无 missing resource 报错。
- 本分支不触碰 `Globals/enemyParams.gd`、`Scenes/Level0.tscn`（另一 agent 的改动）。
