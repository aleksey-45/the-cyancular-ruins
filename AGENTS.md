# AGENTS.md

> **唯一入口。** 分域正文在 [`docs/eng/`](docs/eng),**按域路由 = [`docs/eng/README.md`](docs/eng/README.md)**。
> 本文件只放**动手前必须知道的**。跑法细节、守卫经济、域机制一律不在这里(见 §4),理由:本文件会进每个会话的上下文。
> 任何一处与源码冲突,**以源码为准**。
> ★ `CLAUDE.md` 是本文件的**生成副本**(`python tools/sync_agents_md.py`),**勿手改**。

## 0. 是什么

Godot **4.7.1 标准版(非 mono)** 的 2D 横版射击 demo「The Cyancular Ruins」:视口 1920×1440、`rendering/mobile`、**环面世界**(左右 / 上下无缝回绕)、单机 + PvP(1v1 / 对抗 / 大乱斗)+ 时间玩法(回溯 / 加速)。地图 = `maps/*.cyrm`(**v4 二进制**,每次会话随机取一份,无运行时生成)。

- 单机内容 / 数值 / 计划:[`docs/CyR单人模式主策划案.md`](docs/CyR单人模式主策划案.md)。
- **版本号唯一来源 = `project.godot` 的 `application/config/version`**,只能数字+点(写 `v0.5.0` / 字母会让导出失败);发布前缀 = 同文件 `application/config/release_prefix`。**别在任何文档里另抄一份版本号。**

## 1. 跑什么

```bash
bash tests/run_all.sh            # 默认批:headless、不占端口、不弹窗。判据 = 全批判词行
bash tests/run_real.sh           # 真链路批:占 7777 + 拉子进程 ⇒ 必须先让用户认领
python tools/check_naming.py     # 目录 / 类名 / 文档链接 / EOL + CLAUDE.md 镜像一致
```

引擎不在 PATH:**`$GODOT`(console 版,跑测试/服务端)与 `$GODOT_EDITOR`(导出)不能混用**,默认值各只留一处([`tests/env.sh`](tests/env.sh) / `start_server.bat` / [`tools/build_release.py`](tools/build_release.py)),换机器设环境变量、别改脚本里的绝对路径。

★ **进入验证阶段先列「这轮要跑哪些测试」给用户认领**:占 7777 / 拉子进程 / 弹窗的由用户点头,其余 agent 跑。清单、逐支判词、已知红基线、跑批纪律:[`tests/README.md`](tests/README.md)。

## 2. 怎么改(六步,缺一步不算完)

1. **定档**(按**爆炸半径**,不看行数):**1 皮**(文案/颜色/版式) · **2 单系统**(一个子系统的逻辑,不动协议与存档) · **3 承重面**(协议 / 输入包 / 回滚与快照 / 存档与地图格式 / 导出与裁剪 / 命中与碰撞 / 联机权威)。同时触及两档取高档。
2. **定位**:`grep` 现网引用。**别信文档里的文件清单 / 枚举**(必然过期)。
3. **改**:单一真相源;新逻辑落进该落的那一层(域路由见 [`docs/eng/README.md`](docs/eng/README.md))。
4. **守卫**:每条新断言先答「**去掉什么它才会红**」。答不出、或只能读源码文本判形态 ⇒ **不写**。什么该写、写哪一档、条数闸:`docs/eng/test-economy.md`(桶划分 + 删/留判据 + 不写清单,**唯一真相源,本文不重复**)。
5. **验证**:判据**一律 grep 文本**(该支自打的 `OK` / `ALL-OK`),**退出码不是判据**。档 2 ≥1 条承重断言变异;**档 3 每条承重断言逐条变异 + 真链路跑批 + 逐任务评审**。
6. **提交**:逐个文件点名 `git add`(新 `.gd` 连 `.gd.uid`;`.tscn` 不用),**绝不 `git add -A`**;提交前逐文件 `git diff` **认领每个 hunk**(多会话共用工作树)。信息格式 `type(scope): 中文一句话`。

## 3. 会静默错的硬规则(违反不报错,只是很久以后才发现)

- **7777** 是大厅端口:任何占它的步骤先查 `lobby_alive`,为真**跳过并问用户**(大厅 `_ready` 会 kill 掉用户正在跑的对局)。**非 headless(弹窗)步骤跑前告知**。真链路跑批**前后** `tasklist | grep -i godot` 必须为空。
- **`-s` 冒烟必须写空载守卫**(`load()` 后判空 + `quit(1)`),否则抛错后走不到 `quit()`,**进程永久挂起**;新冒烟一律套外层 `timeout`。场景探针 `--quit-after` 给足(3600)。
- **`ALL-OK` 只证明"没有断言失败",不证明"每条断言都跑过"**(脚本错误只结束出错函数、调用方继续)⇒ 新场景探针必须自带 `_checks >= EXPECTED_CHECKS` 条数闸。
- **命令行开关必须写在 `--` 之后**(`server_main.gd` 读 `OS.get_cmdline_user_args()`);写在前面会被 Godot 丢掉并**静默跑错分支**。
- **要进导出包的脚本禁用 `RegEx`**(裁剪模板 `module_regex_enabled: false` ⇒ 整个脚本解析失败,而编辑器里全绿)。
- **`.uid`**:跟踪 `*.gd.uid` / `*.gdshader.uid`;**`*.tscn.uid` 零跟踪**。
- **`.ps1` / `.bat` 必须 CRLF**;`.ps1` 编码 = 纯 ASCII 或带 UTF-8 BOM(`check_naming.py` 规则 E 逐文件守)。
- **噪声与信号分不清时:同配置跑两次。**

## 4. 去哪查

★ **文档真相源只有一处:`docs/eng/*.md`**。新结论写那里。**本仓不设归档目录**:历史一律看 `git log` 与提交信息,一次性审计 / 旧计划不入库。

| 想查什么 | 去哪 |
|---|---|
| 域细节(地图格式 / 敌人 / 武器 / 玩家 / 渲染 / UI / 联机 / 网码 / 时间 / 编辑器) | [`docs/eng/README.md`](docs/eng/README.md) 按域路由 |
| **动手前必看**:既有红 / 待还的债 / 已裁定不做 | [`docs/eng/registered-debt.md`](docs/eng/registered-debt.md) |
| 测试分层 / 跑法 / 守卫经济 | [`tests/README.md`](tests/README.md) · [`docs/eng/tests.md`](docs/eng/tests.md) · [`docs/eng/test-economy.md`](docs/eng/test-economy.md) |
| 发布 / 裁剪模板 / 产品冒烟 | [`RELEASE.md`](RELEASE.md) |
| 目录分层 / 操作 / PvP 规则要点 | [`README.md`](README.md) |
| PvP 网络设计 | [`docs/pvp-networking.md`](docs/pvp-networking.md) |
| 追溯"当时为什么这么定"(旧计划 / 旧审计) | `git log` / `git log -p -- <path>` —— **本仓不设归档目录**,历史不入库 |
| 在飞的计划 / 设计 spec | [`docs/superpowers/`](docs/superpowers) |
