# 编辑器本地服务器(editor_server.js)

> **这份文档是什么**:`level_editor/editor_server.js` 及其分片里**成套的实测数据**与**为什么这么定**。
> 代码只留一行指针指到这里 —— 那些表与复现过程是"注释比代码还长"的来源,但它们本身值得留住。
> **什么时候读**:要动 rename 重试的额度/退避、要动三道写闸、或者看到 `server/` 里某个常量想问"为什么是这个数"。

## 1. 分片与依赖

`editor_server.js` 是唯一入口:保留 `require.main === module` 那一支(命令行 `--port/--maps/--root/--no-open`),
并把原 `module.exports` 的 36 个名字**原样**重新导出(名字集合与拆分前逐一相同,`server_smoke.js` 直接取用)。
`serve.bat` 不用改:它仍然跑 `node editor_server.js`。

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

★ **唯一的取值变化**是 `DEFAULT_ROOT_DIR`:分片前是 `__dirname`(= `level_editor/`),现在住 `level_editor/server/`,
故写成 `path.join(__dirname, '..')`;`DEFAULT_MAPS_DIR` 跟它同上跳一级。两条都由 `server_smoke.js` 相位 ① 钉住。

## 2. rename 重试:Windows 上覆盖有打开句柄的文件会给 EPERM

### 2.1 故障形态

Windows 上覆盖一个**还有打开句柄**的文件走的是 `MoveFileEx(REPLACE_EXISTING)`,被拒时报的是
**`EPERM`(不是 `EBUSY`)**。而**本服务器自己的读路径就是持有者之一** —— `serveMapFile` 的
`createReadStream` 在流完之前一直攥着 fd,所以"载入一张地图后马上保存"这种最普通的前端动作就能撞上。
持有者不限于本进程:杀毒扫描器、Windows Search、OneDrive/Dropbox 同步 `maps/` 都会给出同一个错误码 ——
这正是"重试"而不是"只在自家读路径上想办法"的理由(改自家读路径只能消掉本进程那一半持有者)。

### 2.2 复现方法

真 HTTP 服务器 + 真 61KB 地图 + **持续 GET 同一张图的读者** + 20 次连续 PUT,数失败条数。
`server_smoke.js` 相位 ⑧**不**用这种活竞态做守卫(必然飘:要掐到读者正好在场的瞬间),
它把 `renameFn` 注入进去,于是"前两次 EPERM 第三次成功"是纯逻辑,还能顺带断言**尝试次数**。

### 2.3 20 次 PUT 的失败数(复审实测)

| 配置 | 20 次 PUT 的失败数 |
|---|---|
| 出厂(5 次 / 退避 20–160ms) | 6 |
| 去掉重试(`MAX=1`)的对照 | 14 |
| 20 次 / 固定 50ms | 0 |

本机复跑(同一手段,失败**全部**是 EPERM):读者紧循环(周期 ≈1.5ms,比复审那台更狠)5 轮 × 20 次 ——
出厂 **34/100**、本档(12 次 / 封顶 50ms)**6/100**、12 次 × 固定 50ms 6/100、20 次 × 固定 50ms 1/100;
读者 ≈50ms 一轮时出厂 0/60、本档 0/60(普通场景本来就已修好)。

★ 出厂那一版(5 次)是**照着论证写反了**的:选型论证里"异步退避第 9 次成功"那个第 9 次,
本身就落在出厂额度 5 之外。

### 2.4 为什么是异步退避,不是同步睡

`Atomics.wait` 能同步睡,但同步睡会把事件循环冻住 —— 而竞争者(正在流地图的那个读流)
**恰恰需要事件循环转起来才能把 fd 关掉**。实测(2MiB 地图 + 慢客户端):同步退避 21 次尝试 / 1270ms,
期内读者前进 **0 字节**、全部失败;异步退避同期读者前进 1.9MiB、第 9 次成功。
⇒ 同步版对这个 bug **结构上无效**,不是参数没调好。`server_smoke.js` 相位 ⑧ 的 ①c 就是钉这一条的:
不注入 `sleepFn`、旁路开一个自续 `setImmediate` 计数器,断言重试窗口内事件循环**确实前进过**。

### 2.5 额度与退避的取值

12 次 / base 20ms / **封顶 50ms** ⇒ 退避序列 = min(50, 20×2^(n-1)) = 20/40/50/50/…(共 11 档),
最坏总等待 = 20+40+9×50 ≈ **510ms**,仍在人的等待阈值以内。封顶**不是**为了翻倍到 20s 那种档
(最坏总等待会到分钟量级,用户会以为卡死)。选 12 而不是 5 的理由见 §2.3。
别以为"封顶会拖累命中率":实测 12 次 × 固定 50ms(6/100)与本档(6/100)打平 ——
封顶拿回的是"总等待有上界",没拿命中率去换。

**固有代价(照实说)**:目标**永久**不可写时(只读属性文件、被独占句柄长期打开),用户要多等这 ~510ms
才看到同一条 500。那是"重试 EPERM"的必然成本,不是缺陷;不加额度的代价则是"最普通的保存动作常态性 500"。

### 2.6 诚实边界(别把结论读过头)

1. 复审那组 HTTP 组**可能被相位锁定**(退避是 2 的幂、读者 GET 周期约 10.5ms,近似整数倍会让每次尝试
   落在同一相位 ⇒ 可能**高估**真实失败率);进程内那组(2MiB 图 + 逐块 `read()`、块间让出事件循环)
   不受此影响,结论一致 —— 故"预算不够宽"这个判断是稳的。
2. 本档**不是 0 失败**:最狠的读者节奏下仍有 ~6% 残留(20 次 PUT 里约 1 次),而 20 次 × 50ms 是 1/100。
   残留根因是"读者几乎全程攥着 fd"这种极端形态;真机上是"载入后马上保存"那一类**瞬时**持有,
   出厂参数在那档就已 0/60。想再压只能继续加额度(超出 dispatch 给的 10~12 上限),没做。

## 3. 三道闸的安全理由(代码里压到几行,全文在这)

### 3.1 Host 白名单 —— DNS rebinding

只绑 `127.0.0.1` **挡不住 DNS rebinding**:用户访问一个恶意页面时,那个页面可以把自己的域名解析到
`127.0.0.1`,于是它就以**同源**身份打到这个服务器上 —— 绑回环完全帮不上忙。
判据是 Host 头必须点名**回环主机 + 本服务器实际监听的端口**:正常浏览器访问 `http://127.0.0.1:8777/`
发的就是 `127.0.0.1:8777`,而 rebinding 打过来时 Host 是那个恶意域名 ⇒ 正好被挡。
端口取 `req.socket.localPort`(**不要写死 8777**:`startServer` 支持 `port:0` 由系统分配,冒烟测试正是这么跑的)。
判据取「host:port 全等」,**不含裸主机名**:浏览器/curl 访问非默认端口时一定带端口,
放行裸名只会多开一扇门(裸名只在 80 端口才有意义,那不是本服务器)。

### 3.2 写端点的 CSRF 闸 —— 为什么 Host 闸不够

恶意页面可以直接 `fetch('http://127.0.0.1:8777/api/map', { method: 'PUT', body })` —— 此时浏览器发的
`Host` **就是** `127.0.0.1:8777`,完全合法,Host 闸照过。读端点安全(不发 CORS 头 ⇒ 跨源读不到响应体),
但**写端点**上,一个「简单请求」(不触发预检的那些组合:GET/HEAD/POST + 三种 CORS 安全内容类型
`text/plain`、`multipart/form-data`、`application/x-www-form-urlencoded`)会被浏览器**直接发出去、不经预检**。

⇒ 写端点必须自己要求一个**非简单**的形态,逼浏览器先发预检;而预检我们一个 CORS 头都不答,
浏览器根本不会把那条写请求发出来。三道一起上(纵深防御):

1. 内容类型必须是 `application/json`(CORS 安全名单之外 ⇒ 必然触发预检)—— 逼预检的那一条;
   只比**分号之前**的 media type,因为浏览器 fetch 带 charset 时会发 `application/json; charset=utf-8`;
2. `Origin`(带了就必须是本服务器自己的两个回环名字)—— 精确判据,**主闸**;
3. `Sec-Fetch-Site: cross-site` —— 只在**没有 Origin 可判**时兜底(浏览器专有头,页面 JS 改不了它;
   非浏览器客户端两个头都不带 ⇒ 仍放行,由第 1 条兜着)。

★★ 反过来:**绝不要加 `Access-Control-Allow-Origin`** —— 那等于把预检答成"通过",
会把本来安全的**读**端点一起拖下水(跨源就能读到响应体了)。`server_smoke.js` 相位 ⑦ 钉住这一点。

★ 而 `Origin` 有效时**就此放行、不再看 `Sec-Fetch-Site`** 也不是疏忽:`localhost` 与 `127.0.0.1`
按 Fetch 的"同站"定义是**两个站**,所以从 `http://localhost:8777` 打开的编辑器页去写
`http://127.0.0.1:8777` 时,浏览器会诚实地标成 `Sec-Fetch-Site: cross-site` —— 那**是我们自己**,
拿它去拒就等于"用 localhost 打开编辑器就存不进任何地图"。

### 3.3 写路径的符号链接包含性检查

`mapPathFor` 判的是**路径字符串**(裸文件名正则 + "拼出来的字符串必须落在 `maps/` 里面"),
而 `fs.stat` / `fs.writeFile` / `fs.realpath` 这一族**会跟随符号链接**。对读端点这只是低危
(要求攻击者已经能往 `maps/` 里放一个链接 —— 而那多半是"解压一个压缩包""克隆一个仓库"带进来的);
写端点走同一条路径时会升级成「把编辑器当任意文件写入器」⇒ 按**真实路径**再判一次。

整个比较都在 realpath 空间里做(两边都从 realDir 出发):Windows 上 realpath 可能把 8.3 短名
(`ALEKSE~1`)规整成长名,拿它去和 `path.resolve` 出来的**字面量**比会假红。
「目标尚不存在」是**最正常**的情形(新建一张地图),不是错误:没有那个文件 ⇒ 没有任何符号链接可以跟随
⇒ 直接放行;只有 `ENOENT` 走这一支。目标**存在**却 realpath 不了(最典型的是**悬空**符号链接)一律
fail closed —— 判不了就不写。

### 3.4 静态路径的穿越闸判据

判据刻意是「**解析后的绝对路径必须落在 rootAbs 里面**」,而不是「字符串里有没有 `..`」:
后者漏掉 URL 编码(`%2e%2e` 会被 URL 解析器归一化掉、但 `%2f` 不会)与一切别的变体,
而前者是**结构性**的 —— 无论输入长什么样,解析完都得落在根里面。
URL 解析器本身也会归一化掉 `..`(实测 `/../x` → `/x`),所以这里是**第二道**闸;
真正危险的是 `/..%2f..`(编码过的分隔符),那一个必须靠这一道挡。

## 4. 静态/地图读流:ReadStream 的 'error' 必须有人接管

响应头**已经发出去了**之后,这一支只能把本次响应中止掉,不能回头改状态码。`ReadStream` 的 `'error'`
必须在那里接管:没人接管就是一次**无人认领的 'error' 事件** = 未捕获异常 = **整个编辑器服务器进程死掉**
(客户端什么响应都收不到,用户只能重启 `serve.bat`)。

「stat 成功但 open 失败」是**真实存在的状态**,不是理论:Windows 上文件被 AV/扫描器独占锁定、
ACL 拒绝、负载下的 EMFILE、以及文件在 `stat` 与 `createReadStream` 之间被删掉(编辑器自己重写文件时正会如此)。
上面那道 404 只覆盖「stat 失败」,根本走不到这里。`serveStatic` 与 `serveMapFile` 是**两份独立**的代码,
各自都要有这道守卫 —— `server_smoke.js` 相位 ⑤ 用 PowerShell 的 `[IO.File]::Open(..., 'None')` 真造出
"stat 成功 / open 失败",两条分别验(删掉任何一条,对应的那几条会红)。
另一半是防 fd 泄漏:客户端提前断开时把**源流**关掉,否则 fd 与流对象一直留到进程结束。

## 5. 地图名唯一一次放宽:`.v3.bak`

除 `.cyrm` 外只多接受**一个**后缀 `.v3.bak`。为什么非放行不可:v3→v4 的转换是**单向**的,
保存前要落一份原文备份当退路,而备份名必须是 `<名>.v3.bak` —— 结尾**不是** `.cyrm`,
游戏的 `_random_cyrm`(`f.to_lower().ends_with(".cyrm")`)才抽不到它,备份不会混进随机地图池。
放宽得极小:基名照旧**只许** `[A-Za-z0-9_-]`(里面**连 `.` 都不许有**,`..`、`/`、`\`、空字节、
其它后缀一律照旧拒),故它仍然写不出 `maps/` 之外、也写不出任意后缀的文件。
守卫在 `server_smoke.js` 相位 ⑤:新后缀被接受 + 旧的每一条拒绝路径都还在。

## 6. 校验

```bash
cd level_editor
node server_smoke.js          # 判据:文本 SERVER SMOKE OK + 退出码 0
node parts_check.js --ratio   # 每个 .js 的注释额度(>100 非空行的文件 ≤15%)
```
