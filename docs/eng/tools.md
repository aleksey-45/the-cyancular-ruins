# 开发工具与地图编辑器 (关卡编辑器 / 格式同步 / 自动化构建)

> 本文档规范 Cyber Ruins (CyR) 的外围开发工具、地图编辑器体系与辅助脚本。
> 返回索引：[`CLAUDE.md`](../../CLAUDE.md)。

---

## 一、地图编辑器架构 (`level_editor/`)

地图编辑器采用基于 Web 技术的独立前端实现，支持超大分辨率地图平移缩放、子格精度画笔、多图层编辑与辅码染色。

### 1. 运行与服务启动
- **启动脚本**：运行 `level_editor/serve.bat`。
- **后台服务**：通过 `level_editor/editor_server.js`（Node.js）启动轻量本地 HTTP 服务（绑定 `127.0.0.1:8777`）。出于浏览器安全策略与 API 请求限制，不支持直接通过 `file://` 协议打开。
- **前端模块拆分**：
  - `editor.html`：主编辑器 HTML 入口。
  - `core.js`：核心数据结构与 `.cyrm` 格式编解码规范。
  - `tint.js`：辅码像素计算与调色板处理。
  - `render.js` / `ui.js` / `io.js`：视口渲染、工具栏交互、文件读写。
  - `worker.js`：多线程大地图渲染与数据导出 Web Worker。

### 2. `.cyrm` 地图格式规范与双向兼容
- **v4 二进制格式**：
  - 包含 20 字节二进制文件头、Deflate 高效无损压缩与 CRC32 完整性校验。
  - 逻辑层维持 64px 大网格，视觉与碰撞层细化为 16px 子格（每格 $4 \times 4$ 个子格），每个子格支持独立辅码染色。
- **v3 文本格式**：每格 4 字符标记（纹理 ID + 形状掩码），顶部带有 `# cyrm-v3` 声明行。
- **引擎端兼容实现**：游戏引擎层（`core/sim/map_format.gd` 与 `core/sim/map_format_v4.gd`）已全面支持 v4 二进制与 v3 文本解析。编辑器支持将旧版地图无损转换为 v4 格式导出保存。

---

## 二、配置与数据同步工具

为了确保 Web 编辑器与 Godot 引擎游戏数据保持严格一致，通过 Node.js 脚本维护单向同步机制：

1. **敌人配置同步**：
   - 数据源：`data/enemies.json`。
   - 同步脚本：`node level_editor/sync-enemies.js`。
   - 校验模式：执行 `node level_editor/sync-enemies.js --check` 仅检查数据一致性而不覆盖文件。
2. **场景瓦片配置同步**：
   - 脚本：`node level_editor/sync-tiles.js`，将瓦片图集与物理属性映射同步至前端调色板。

---

## 三、编辑器自动化测试与质量保障

在 `level_editor/` 目录下提供针对前端与服务端逻辑的自动化测试套件：

```bash
cd level_editor
node smoke.js             # 核心格式读写冒烟测试
node tint_smoke.js        # 辅码计算与调色板单元测试
node worker_io_smoke.js   # Web Worker 编解码与 IO 测试
node render_smoke.js      # 画布渲染管线冒烟测试
node server_smoke.js      # 本地 Node.js 服务端接口测试
```

- **浏览器内端到端自检**：在编辑器页面顶部工具栏点击「自检」按钮，会在控制台执行全套前端组件断言并输出 `SELFTEST OK`。
