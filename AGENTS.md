# AGENTS.md

本文件是这个仓库内 agent / 协作者的工作约定。
提交规范参考 [How to Write a Git Commit Message](https://cbea.ms/git-commit/)，并结合本仓库的 Conventional Commits 和中文上下文。

## 1. 项目基线

- Godot 4.7.x，Mobile renderer，逻辑视口 1920×1440。
- 当前迁移分支：`feat/upstream-main-migration`。
- 远端：`github-ssh`（`git@github.com:aleksey-45/the-cyancular-ruins.git`）。
- 主要检查：
  - `python tools/check_naming.py`
  - `python tools/run_checks.py --godot <Godot console path>`
- 视觉任务必须提供实际截图；不能只凭 headless 输出判断 UI/渲染是否通过。

## 2. 提交信息格式

采用：

```text
type(scope): 祈使句摘要

正文（可选，非 trivial 提交必须有）

Refs: ...
```

### 2.1 七条规则（适配本仓库）

1. **主题与正文之间空一行**；只有主题时不需要正文。
2. **主题不超过 50 个字符**（含 `type(scope):`）。超过时缩写，不要靠 GitHub 截断。
3. **主题首词按语言处理**：
   - 中文摘要用动词开头；
   - 英文摘要首词大写；
   - `type` / `scope` 保持 Conventional Commits 的小写形式。
4. **主题末尾不加句号**。
5. **主题用祈使句**：
   - 中文：添加 / 修复 / 重写 / 删除 / 调整 / 记录；
   - 避免“已修复”“修改了”“一些改动”。
   - 自检句式：`如果应用此提交，它将 <主题>` 应该通顺。
6. **正文按 72 列换行**（中文/全角按 2 列估算，约 36 个汉字一行）。
7. **正文说明 what / why，而不是逐行解释 how**：
   - 改动前的问题；
   - 为什么这样做；
   - 行为/兼容性影响；
   - 验证方式；
   - 必要的风险或遗留项。
   - 代码本身能解释的细节不要复述 diff。

### 2.2 允许的 type

`feat` `fix` `refactor` `perf` `docs` `test` `build` `ci` `chore` `style` `revert`

### 2.3 scope

用模块或领域，不用里程碑编号：

- 推荐：`render` `ui` `net` `sim` `config` `input` `editor` `tools` `docs` `agents`
- 避免：`p0` `p1` `p2` `p3`（里程碑应写进正文/Refs）
- 历史提交里的 `feat(p0)` 是反例；新提交不要沿用。

### 2.4 正文模板

非 trivial 提交按需使用：

```text
<为什么需要这个改动，之前哪里有问题>

<本次改了什么，关键行为/接口变化>

验证：<命令/测试/截图路径及结果>
影响：<兼容性、性能、视觉、迁移注意事项>
Refs: <计划/issue/文档路径>
```

简单改动可以只有主题。
涉及行为、视觉、数据格式、协议、删除文件、迁移计划的提交必须有正文。

## 3. 原子提交

- 一个提交只做一件逻辑上的事；不要把“重构 + 新功能 + 格式化 + 文档”混在一起。
- 代码和它的测试尽量同提交；独立的计划/分析文档可单独提交。
- 不要提交编辑器生成物：
  - `.godot/`
  - `.tmp/`
  - 无实质变化的 `*.import`
  - Godot 自动重写的 `project.godot`
- 发现无关脏文件时，先还原或确认，再提交。
- 用显式路径 `git add <file>`，不要习惯性 `git add -A`。
- 提交前看：
  - `git status --short`
  - `git diff --cached --stat`
  - `git diff --check`

## 4. 提交前检查

按改动范围选择：

- 文档/命名：`python tools/check_naming.py`
- 代码/模拟/网络：`python tools/run_checks.py --godot <path>`
- 场景/资源：headless 加载对应 `.tscn`，确认 exit=0、无 `SCRIPT ERROR`
- UI/渲染：1920×1440 与 1280×960 截图；检查字体、对齐、像素颗粒
- 性能相关：说明测量场景和帧时间，不用“应该没问题”代替测量

测试不通过不提交。
没运行的测试不要写成“已验证”。

## 5. 推送规则

- 先在本地完成提交，再推送：
  ```bash
  git push github-ssh feat/upstream-main-migration:feat/upstream-main-migration
  ```
- 不使用 force push 覆盖共享分支。
- 如果远端已更新：
  - 先 fetch/rebase 或按团队约定合并；
  - 不直接 `push --force`。
- 推送后确认：
  - `git status --short --branch`
  - `git ls-remote github-ssh refs/heads/feat/upstream-main-migration`
  - 本地 HEAD 与远端哈希一致。

## 6. Agent 工作约定

- 先读任务相关计划/文档，再改代码。
- 不覆盖别人未提交的改动；共享工作区里先看 `git status`。
- 修改多个模块时拆成可验证的小步；每步保持可运行。
- 不编造测试结果、截图或远端状态。
- 视觉任务必须真的看截图；不能只看脚本输出。
- 任务只要求分析时，不顺手提交实现代码。
- 提交信息按本文件执行；提交后报告：
  - 提交哈希与主题；
  - 验证命令与结果；
  - 是否有未提交/未推送内容。

## 7. 历史问题记录

截至本次更新，仓库历史审计发现：

- 最近 40 条提交**全部没有正文**，包括 P0/P1/P3 实现、渲染圆盘删除、B-1/B-2 计划重写；
- 136 条提交中 3 条主题超过 50 字，最长 71 字；
- 存在 `docs(plan)` / `docs(render)` / `feat(p0)` 等 scope 混用；
- B-2 plan/spec 提交后很快被 B-1 替换，形成一次计划反复；
- 曾差点把 Godot 自动改写的 `project.godot` 和 `*.import` 一起提交。

这些不是要改写历史，而是新提交要避免重复。

## 8. 示例

### 好

```text
fix(render): 移除天空日月圆盘

侧视场景只需要渐变天空；圆盘是旧视觉装饰，且
draw_circle 的抗锯齿与像素画冲突，保留它还会让
天空与像素颗粒不一致。

保留 Daylight 的 ambient/directional_light，删除
_disc_at/_disc_color 与 draw_circle。

验证：main_menu/match_view headless 加载 exit=0；
check_naming OK；1920×1440 截图无圆盘。
Refs: docs/construction/2026-11-24-render-b1-plan.md
```

### 不好

```text
fix(ui): 改了一些东西
```

问题：没有 why、没有 what、没有验证；读者无法判断影响。

```text
docs(render): 重写 B-2 plan 与 spec（NormalViewport + PostFX，连续 spec/rough）
```

问题：主题 71 字；没有正文说明为什么从 B-2 转向、哪些文档被替换。

## 9. 维护

提交规范或检查命令变化时，同步更新本文件。
本文件只约束工作方式，不替代具体计划/架构文档。
