# 素材目录规范化 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把素材统一到 `res://assets/` 单根（fonts/textures），文件名转 snake_case，修复 grenade_launcher 的脆弱 SubResource，移除旧目录。

**Architecture:** 用 `git mv` 连同 `.import` 一起移动资源（保留 uid），再批量更新 `.tscn`/`.gd` 里的 `res://` 路径引用；`grenade_launcher.tscn` 从直接引用 `.godot/imported/*.ctex` 改为标准 ext_resource；最后清理空目录。验证靠 grep 一致性检查 + 用户开 Godot 编辑器重导入。

**Tech Stack:** Godot 4.7（标准版非 mono）、git。无代码逻辑改动，无单测；"测试"= grep 引用一致性 + 用户跑冒烟/开编辑器。

## Global Constraints

- 分支 `refactor/standardize-assets`，基于 `main`。
- **不得触碰** `Globals/enemyParams.gd`、`Scenes/Level0.tscn`（另一 agent 正在改）。
- 移动时 `.png`/`.ttf` 与其 `.import` 必须一起走，保住 `.import` 里的 `uid`；**不手改 `.import` 内部字段**。
- 不改 `map/`、`icon.svg`、`Globals/maze_generator.gd` 的 `MAP_FILE`（map/ 不动）。
- 未用素材 `Lotus.png`、`_jump_bird_preview.png` 保留移入新结构，不删。
- `.godot/` 是 gitignore 缓存，不手改；重导入由用户开编辑器完成。
- 测试由用户自己跑（项目约定，不代跑）。

---

### Task 1: 移动素材文件到 assets/ 单根

**Files:**
- Create dirs: `assets/fonts/`, `assets/textures/`
- Move（git mv，源码 + `.import` 一起）:
  - `Assets/fonts/LessPerfectDOSVGA.ttf` + `.import` → `assets/fonts/less_perfect_dos_vga.ttf`(+`.import`)
  - `AssetBundle/Sprites/Player.png` + `.import` → `assets/textures/player.png`(+`.import`)
  - `AssetBundle/Sprites/Weapons.png` + `.import` → `assets/textures/weapons.png`(+`.import`)
  - `AssetBundle/Sprites/Bullets.png` + `.import` → `assets/textures/bullets.png`(+`.import`)
  - `AssetBundle/Sprites/Effects.png` + `.import` → `assets/textures/effects.png`(+`.import`)
  - `AssetBundle/Sprites/Fly_Bird.png` + `.import` → `assets/textures/fly_bird.png`(+`.import`)
  - `AssetBundle/Sprites/Jump_Bird.png` + `.import` → `assets/textures/jump_bird.png`(+`.import`)
  - `AssetBundle/Sprites/Lotus.png` + `.import` → `assets/textures/lotus.png`(+`.import`)
  - `AssetBundle/Sprites/_jump_bird_preview.png` + `.import` → `assets/textures/_jump_bird_preview.png`(+`.import`)

**Interfaces:**
- Produces: 新路径文件（`res://assets/...`）。后续 Task 2 按这些新路径更新引用。

- [ ] **Step 1: 建目录并 git mv 全部资源**

```bash
mkdir -p assets/fonts assets/textures
git mv "Assets/fonts/LessPerfectDOSVGA.ttf" "assets/fonts/less_perfect_dos_vga.ttf"
git mv "Assets/fonts/LessPerfectDOSVGA.ttf.import" "assets/fonts/less_perfect_dos_vga.ttf.import"
git mv "AssetBundle/Sprites/Player.png" "assets/textures/player.png"
git mv "AssetBundle/Sprites/Player.png.import" "assets/textures/player.png.import"
git mv "AssetBundle/Sprites/Weapons.png" "assets/textures/weapons.png"
git mv "AssetBundle/Sprites/Weapons.png.import" "assets/textures/weapons.png.import"
git mv "AssetBundle/Sprites/Bullets.png" "assets/textures/bullets.png"
git mv "AssetBundle/Sprites/Bullets.png.import" "assets/textures/bullets.png.import"
git mv "AssetBundle/Sprites/Effects.png" "assets/textures/effects.png"
git mv "AssetBundle/Sprites/Effects.png.import" "assets/textures/effects.png.import"
git mv "AssetBundle/Sprites/Fly_Bird.png" "assets/textures/fly_bird.png"
git mv "AssetBundle/Sprites/Fly_Bird.png.import" "assets/textures/fly_bird.png.import"
git mv "AssetBundle/Sprites/Jump_Bird.png" "assets/textures/jump_bird.png"
git mv "AssetBundle/Sprites/Jump_Bird.png.import" "assets/textures/jump_bird.png.import"
git mv "AssetBundle/Sprites/Lotus.png" "assets/textures/lotus.png"
git mv "AssetBundle/Sprites/Lotus.png.import" "assets/textures/lotus.png.import"
git mv "AssetBundle/Sprites/_jump_bird_preview.png" "assets/textures/_jump_bird_preview.png"
git mv "AssetBundle/Sprites/_jump_bird_preview.png.import" "assets/textures/_jump_bird_preview.png.import"
```

- [ ] **Step 2: 验证文件已在目标位置、旧位置已空**

```bash
ls assets/fonts assets/textures
find AssetBundle Assets -type f   # 期望无输出(旧根只剩空目录)
```

- [ ] **Step 3: 更新所有 `.tscn` 的 ext_resource path + hud.gd 字体路径**

用 Edit 逐个替换（uid 与 id 保持不动，只改 `path=` 值）。具体替换对：

| 文件 | 旧 path | 新 path |
|---|---|---|
| `Scenes/Enemies/EnemyFlyBird.tscn` | `res://AssetBundle/Sprites/Fly_Bird.png` | `res://assets/textures/fly_bird.png` |
| `Scenes/Enemies/EnemyJumpBird.tscn` | `res://AssetBundle/Sprites/Jump_Bird.png` | `res://assets/textures/jump_bird.png` |
| `Scenes/Enemies/enemy_bullet.tscn` | `res://AssetBundle/Sprites/Bullets.png` | `res://assets/textures/bullets.png` |
| `Scenes/Player/Player.tscn` | `res://AssetBundle/Sprites/Player.png` | `res://assets/textures/player.png` |
| `Scenes/Weapons/bullet.tscn` | `res://AssetBundle/Sprites/Bullets.png` | `res://assets/textures/bullets.png` |
| `Scenes/Weapons/explosion.tscn` | `res://AssetBundle/Sprites/Effects.png` | `res://assets/textures/effects.png` |
| `Scenes/Weapons/grenade_bullet.tscn` | `res://AssetBundle/Sprites/Bullets.png` | `res://assets/textures/bullets.png` |
| `Scenes/Weapons/m82a1.tscn` | `res://AssetBundle/Sprites/Weapons.png` | `res://assets/textures/weapons.png` |
| `Scenes/Weapons/pistol_test.tscn` | `res://AssetBundle/Sprites/Weapons.png` | `res://assets/textures/weapons.png` |
| `Scenes/Weapons/rifle_test.tscn` | `res://AssetBundle/Sprites/Weapons.png` | `res://assets/textures/weapons.png` |
| `Scenes/Weapons/s686.tscn` | `res://AssetBundle/Sprites/Weapons.png` | `res://assets/textures/weapons.png` |
| `Scenes/hud.gd`（`KILL_FONT_PATH`） | `res://Assets/fonts/LessPerfectDOSVGA.ttf` | `res://assets/fonts/less_perfect_dos_vga.ttf` |

> `grenade_launcher.tscn` 本任务不碰（它没有 ext_resource 引用，是 SubResource，留到 Task 2）。

- [ ] **Step 4: 验证无残留旧引用（排除 docs/.superpowers/、二进制）**

```bash
grep -rn 'res://AssetBundle\|res://Assets' --include='*.tscn' --include='*.gd' .
grep -rn 'res://assets' --include='*.tscn' --include='*.gd' .
```

期望：第一条无输出；第二条列出 12 处新路径（11 场景 + hud.gd）。

- [ ] **Step 5: 提交（只用受影响的路径，避免卷进另一 agent 的改动）**

```bash
git add assets AssetBundle Assets
git status --porcelain   # 期望只出现 assets/、AssetBundle/、Assets/ 相关条目;不得出现 Globals/enemyParams.gd、Scenes/Level0.tscn
git commit -m "refactor: 素材统一到 assets/ 单根 + 引用路径更新(snake_case)"
```

> 若 `git status --porcelain` 里出现 `Globals/enemyParams.gd` 或 `Scenes/Level0.tscn`，**不要提交**，停下来找用户确认。

---

### Task 2: 修复 grenade_launcher.tscn 的 SubResource

**Files:**
- Modify: `Scenes/Weapons/grenade_launcher.tscn`

**Interfaces:**
- Consumes: `assets/textures/weapons.png`（Task 1 产物，uid `uid://cfbhunkx3526n`）
- Produces: 与 m82a1 等一致的 ext_resource 写法。

- [ ] **Step 1: 读文件确认当前内容**

Run: `Read Scenes/Weapons/grenade_launcher.tscn`

当前（已知）：
```
[sub_resource type="CompressedTexture2D" id="CompressedTexture2D_ofh50"]
load_path = "res://.godot/imported/Weapons.png-c4a6c69d089b50848ba40f862b49769f.ctex"
...
[node name="Sprite2D" ...]
texture = SubResource("CompressedTexture2D_ofh50")
region_enabled = true
region_rect = Rect2(3, 35, 51, 21)
```

- [ ] **Step 2: 替换 SubResource 为 ext_resource**

Edit 1 — 把第 6-7 行：
```
[sub_resource type="CompressedTexture2D" id="CompressedTexture2D_ofh50"]
load_path = "res://.godot/imported/Weapons.png-c4a6c69d089b50848ba40f862b49769f.ctex"
```
替换为：
```
[ext_resource type="Texture2D" uid="uid://cfbhunkx3526n" path="res://assets/textures/weapons.png" id="2_wpn"]
```

Edit 2 — 把 Sprite2D 的 `texture = SubResource("CompressedTexture2D_ofh50")` 替换为 `texture = ExtResource("2_wpn")`。`region_enabled = true` 与 `region_rect = Rect2(3, 35, 51, 21)` 保留不动。

- [ ] **Step 3: 验证**

```bash
grep -rn '\.godot/imported' --include='*.tscn' .
grep -n 'weapons.png\|ExtResource("2_wpn")' Scenes/Weapons/grenade_launcher.tscn
```

期望：第一条无输出（不再直接引用 .godot 缓存）；第二条出现 ext_resource 行与 `texture = ExtResource("2_wpn")`。

- [ ] **Step 4: 提交**

```bash
git add Scenes/Weapons/grenade_launcher.tscn
git commit -m "refactor: grenade_launcher 改用标准 ext_resource 引用 weapons.png"
```

---

### Task 3: 清理旧目录 + 最终一致性验证

**Files:**
- Delete dirs: `AssetBundle/`（含空 `Audio/`）、`Assets/`

- [ ] **Step 1: 确认旧根已无文件，删除空目录**

```bash
find AssetBundle Assets -type f   # 期望无输出
rmdir AssetBundle/Audio AssetBundle/Sprites AssetBundle 2>/dev/null
rmdir Assets/fonts Assets 2>/dev/null
ls AssetBundle Assets   # 期望: No such file or directory
```

- [ ] **Step 2: 全仓一致性扫描**

```bash
grep -rn 'AssetBundle\|res://Assets\|Assets/fonts' --include='*.tscn' --include='*.gd' . --exclude-dir=.godot --exclude-dir=.git
```

期望：无输出（`docs/`、`.superpowers/` 历史文档里的旧路径不在范围内，不用改）。

> 注意：**不要**扫 `*.import`——`.import` 内部的 `source_file`/`path` 字段会保留旧路径直到用户开编辑器重导入自改，这是设计 §2 的预期行为，不是残留引用。

- [ ] **Step 3: 检查 git 状态 + 提交（如必要）**

```bash
git status --porcelain
```

期望：`assets/` 新增 + 旧文件删除 + 改的 .tscn/.gd；**不应出现** `Globals/enemyParams.gd`、`Scenes/Level0.tscn`（那是另一 agent 的改动）。空目录删除 git 不跟踪，此步通常无新改动可提交——若 status 干净则跳过提交；若有残留改动只暂存相关路径后提交。

- [ ] **Step 4: 交付用户验证**

告知用户：开一次 Godot 编辑器（或自跑冒烟测试 `Godot_v4.7.1-stable_win64_console.exe --headless --path . -s res://tests/enemy_logic_smoke.gd`）确认无 missing resource；确认无误后 `refactor/standardize-assets` 分支可合入 main。
