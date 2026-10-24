# 编辑器本地服务器(editor_server.js)

> 本文件记 `level_editor/editor_server.js` 及其分片的模块划分、写闸判据与常量。
> 返回索引：[`CLAUDE.md`](../../CLAUDE.md)。

## 1. 分片与依赖

`editor_server.js` 是唯一入口：保留 `require.main === module` 那一支（命令行 `--port/--maps/--root/--no-open`），
并把原 `module.exports` 的 36 个名字原样重新导出（`server_smoke.js` 直接取用）。`serve.bat` 跑 `node editor_server.js`。

| 文件 | 行数 | 职责 | 依赖 |
|---|---|---|---|
| `level_editor/editor_server.js` | 62 | 入口:命令行分支 + 重新导出 36 个名字 | 全部 `server/*.js` |
| `level_editor/server/defaults.js` | 18 | `DEFAULT_HOST/PORT/ROOT_DIR/MAPS_DIR/INDEX`、`MAX_MAP_BYTES` | 无 |
| `level_editor/server/http_util.js` | 72 | MIME、`sendText/sendJson`、`rejectTooLarge`、`readBody` | 无 |
| `level_editor/server/map_names.js` | 29 | 地图名正则/长度/`isValidMapName`/`mapPathFor` | 无 |
| `level_editor/server/static.js` | 48 | 静态根:`staticFileFor`(穿越闸)、`serveStatic` | `http_util` |
| `level_editor/server/maps.js` | 52 | `listMaps`(点名跳过)、`serveMapFile` | `http_util`、`map_names` |
| `level_editor/server/gates.js` | 95 | Host 白名单、写端点 CSRF 闸、`rejectWrite`、符号链接包含性 | 无 |
| `level_editor/server/atomic_write.js` | 89 | rename 重试、`writeMapAtomic`、`receiveMapFile` | `map_names`、`gates`、`http_util` |
| `level_editor/server/api.js` | 39 | `/api/*` 分派 | 上面几个 |
| `level_editor/server/server.js` | 111 | `createServer`、`startServer`、`describePortOwner`、`openBrowser`、`parseArgs` | `defaults`、`http_util`、`gates`、`api`、`static` |

- `DEFAULT_ROOT_DIR` 写成 `path.join(__dirname, '..')`（`defaults.js` 住在 `level_editor/server/`），
  `DEFAULT_MAPS_DIR` 同上跳一级。两条都由 `server_smoke.js` 相位 ① 钉住。

## 2. rename 重试：Windows 上覆盖有打开句柄的文件会给 EPERM

- Windows 上覆盖还有打开句柄的文件走 `MoveFileEx(REPLACE_EXISTING)`，被拒时报 **`EPERM`（不是 `EBUSY`）**。
  本服务器自己的 `serveMapFile` 读流就是持有者之一，杀毒扫描器 / Windows Search / 云同步同样会给这个错误码。
- 额度：**12 次 / base 20ms / 封顶 50ms** ⇒ 退避序列 `min(50, 20×2^(n-1))` = 20/40/50/50/…（共 11 档），
  最坏总等待 = 20+40+9×50 ≈ **510ms**。
- 退避是**异步**的，不可用 `Atomics.wait`：同步睡会冻住事件循环，而竞争者（正在流地图的读流）
  需要事件循环转起来才能关掉 fd。
- 守卫注入 `renameFn`（`server_smoke.js` 相位 ⑧），并旁路断言重试窗口内事件循环确实前进过。
- **固有代价**：目标永久不可写时要多等这 ~510ms 才看到同一条 500。
- 已知边界：最狠的读者节奏下仍有约 6% 残留（读者几乎全程攥着 fd 那种极端形态）。

## 3. 三道闸的判据

### 3.1 Host 白名单 —— DNS rebinding

- Host 头必须点名**回环主机 + 本服务器实际监听的端口**，判据取「host:port 全等」，**不含裸主机名**。
- 端口取 `req.socket.localPort`，**不可**写死 8777（`startServer` 支持 `port:0` 由系统分配）。

### 3.2 写端点的 CSRF 闸

写端点必须要求一个**非简单**形态，逼浏览器先发预检；预检一个 CORS 头都不答。三道一起上：

1. 内容类型必须是 `application/json`（只比**分号之前**的 media type，浏览器会带 `; charset=utf-8`）—— 逼预检的那一条；
2. `Origin`（带了就必须是本服务器自己的两个回环名字）—— 精确判据，**主闸**；
3. `Sec-Fetch-Site: cross-site` —— 只在**没有 Origin 可判**时兜底（非浏览器客户端两个头都不带 ⇒ 由第 1 条兜着）。

- ★★ **绝不要加 `Access-Control-Allow-Origin`**（等于把预检答成通过，会把安全的读端点一起拖下水）。
  `server_smoke.js` 相位 ⑦ 钉住这一点。
- ★ `Origin` 有效时**就此放行、不再看 `Sec-Fetch-Site`**：`localhost` 与 `127.0.0.1` 按 Fetch 的「同站」定义
  是两个站，从前者打开的编辑器页去写后者时浏览器会诚实地标成 `cross-site`。

### 3.3 写路径的符号链接包含性检查

- `mapPathFor` 判的是**路径字符串**（裸文件名正则 + 「拼出来的字符串必须落在 `maps/` 里面」），
  而 `fs.stat` / `fs.writeFile` / `fs.realpath` 会跟随符号链接 ⇒ 写端点按**真实路径**再判一次。
- 整个比较都在 realpath 空间里做（两边都从 realDir 出发）。
- 「目标尚不存在」是最正常的情形：只有 `ENOENT` 走放行这一支。
- 目标**存在**却 realpath 不了（典型是**悬空**符号链接）一律 fail closed。

### 3.4 静态路径的穿越闸

- 判据是「**解析后的绝对路径必须落在 rootAbs 里面**」，不是「字符串里有没有 `..`」。
- URL 解析器本身也会归一化掉 `..`，所以这里是第二道闸；真正危险的是 `/..%2f..`（编码过的分隔符）。

## 4. 静态/地图读流：ReadStream 的 `'error'` 必须有人接管

- 响应头已经发出去之后，这一支只能把本次响应中止掉。没人接管 `'error'` 就是未捕获异常 = **整个服务器进程死掉**。
- 「stat 成功但 open 失败」是真实存在的状态：Windows 上被扫描器独占锁定、ACL 拒绝、负载下的 EMFILE、
  以及文件在 `stat` 与 `createReadStream` 之间被删掉。上面那道 404 只覆盖「stat 失败」。
- `serveStatic` 与 `serveMapFile` 是**两份独立**的代码，各自都要有这道守卫（`server_smoke.js` 相位 ⑤ 两条分别验）。
- 另一半是防 fd 泄漏：客户端提前断开时把**源流**关掉。

## 5. 地图名：除 `.cyrm` 外只多接受 `.v3.bak`

- 备份名必须是 `<名>.v3.bak`（结尾**不是** `.cyrm`，游戏的 `_random_cyrm` 才抽不到它）。
- 基名照旧只许 `[A-Za-z0-9_-]`：`..`、`/`、`\`、空字节、其它后缀一律拒，故写不出 `maps/` 之外、也写不出任意后缀的文件。
- 守卫在 `server_smoke.js` 相位 ⑤：新后缀被接受 + 旧的每一条拒绝路径都还在。

## 6. 校验

```bash
cd level_editor
node server_smoke.js          # 判据:文本 SERVER SMOKE OK + 退出码 0
node parts_check.js --ratio   # 每个 .js 的注释额度(>100 非空行的文件 ≤15%)
```
