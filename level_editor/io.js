// io.js —— 编解码 async 门面(规格 §4.3 闸 3)。
// ★ 写成 async **不是**为了降级:编辑器只走 HTTP,Worker 原生可用。理由只有一条 ——
//   Worker 通信本来就是异步的,写成 async 让 ui.js 里的导入/导出/自动存更直。
// ★★ Worker 起不来 = **当场抛错**,没有主线程兜底:静默退回主线程会把"一帧都不阻塞"
//    这条保证悄悄取消,而症状是"大图保存时页面卡一下" —— 没人会把它当成 bug 报。
// ★ 这里**没有** errText():错误文本在 worker 里就由 worker.js 的 reply(errText(e)) 格式化好,
//   经 {ok:false, error} 原样带回。评审发现 1 —— 本文件曾抄过一份同名的死副本(零调用点):
//   同一条归一化规则存在两份时,改了一份的另一份不会有任何信号。
'use strict';

globalThis.Io = (function () {
  'use strict';

  var seq = 0;

  // ★★ 每请求超时(账本那条"接线 ui.js 时再定"的延期条件**已经到期**:保存路径、草稿防抖、
  //    崩溃快照**全都骑在这个门面上**)。
  // ★ 为什么必须有:`worker.onerror` 只覆盖"worker 自己**报了错**"那一条死法。worker 被
  //   杀掉/挂住而**没有**发 onerror 时,`await Io.encodeMap(…)` **永远不 settle** ——
  //    症状是「Ctrl+S 之后再无反应、控制台干净」(闸 4 也看不见:它拦的是**抛**,
  //    而一个悬挂的 promise 连异常都没有)。超时把"悬挂"变成"一次响亮的失败"。
  // ★ 30 秒的量级:真算力是毫秒级(编码一张 125×75 的地图),30 秒只可能是"对面没了";
  //   它同时远长于浏览器的任何正常抖动,故不会在负载重的机器上假红。
  // ★★ 超时**不走自己的收场**,而是复用唯一的那个收口 `failAll` —— 于是"标死 + 拒光在飞 +
  //    回收 worker"这三件事与另外两条死法(terminate / onerror)**逐字同一份**;而且
  //    "标死"这一半是必须的:只拒掉这一条的话,下一次调用会**静默**再起一个 worker,
  //    于是"每 30 秒一次失败"无限循环下去,而没有任何信号说这条链已经坏了。
  var DEFAULT_TIMEOUT_MS = 30000;

  // ★ 默认定时器包一层,是为了让测试**注入自己的时钟**(否则测"30 秒后超时"要真等 30 秒)。
  //   契约:给了 `timer` 就必须同时给 `setTimeout` 与 `clearTimeout`(两个都要 —— 只给前者
  //   会让应答到达时无法撤销,于是**每一次成功的请求**都会在 30 秒后把整条链打成死)。
  function defaultTimer() {
    return {
      setTimeout: function (fn, ms) { return setTimeout(fn, ms); },
      clearTimeout: function (h) { clearTimeout(h); },
    };
  }

  function defaultFactory() {
    if (typeof Worker === 'undefined') {
      throw new Error('Io: 本环境没有 Worker —— 编辑器只通过 HTTP 打开(规格 §4.9),' +
                      'file:// 下没有 Worker。请用 serve.bat 起服务器再打开页面。');
    }
    return new Worker('worker.js');
  }

  // 一个 codec = 一个 worker + 一张"等应答"的表。
  function createCodec(opts) {
    opts = opts || {};
    var factory = opts.workerFactory || defaultFactory;
    var timer = opts.timer || defaultTimer();
    // ★ `timeoutMs <= 0` = 关掉超时(留给"我要自己控超时"的嵌入方);缺省是 DEFAULT_TIMEOUT_MS。
    var timeoutMs = (opts.timeoutMs === undefined || opts.timeoutMs === null)
      ? DEFAULT_TIMEOUT_MS : opts.timeoutMs;
    var worker = null;
    var pending = new Map();
    var dead = null;

    // ★ 撤销一条在飞请求的定时器。**答复到达**与**发出失败**两条路都必须调它:
    //   漏了"答复到达"那一条 ⇒ 每次成功的请求都会在 30 秒后触发一次超时收口(整条链被打死);
    //   漏了"发出失败"那一条 ⇒ 一次 DataCloneError 之后 30 秒,一条**本来没事**的链被误杀。
    function clearEntry(entry) {
      if (entry && entry.timer !== null) {
        timer.clearTimeout(entry.timer);
        entry.timer = null;
      }
    }

    // ★ 唯一的"整条链死掉"收口:标死 + 拒光在飞请求 + 清表 + **回收那个 worker**。
    //   dead 一立,ensure() 就抛 —— 于是之后**任何**调用都当场失败,而不是悄悄再起一个 worker。
    //   ★ 回收放进这个收口,是为了让**两条死法**(terminate() 与 worker.onerror)收场一致:
    //     修复轮 1 把回收只写在 terminate() 里,onerror 那条于是把 worker 引用**留着** ——
    //     线程还活着、还被这个 codec 引着,直到页面关掉为止(而"codec 已死"的语义正是
    //     "它背后没有任何东西还在跑")。两条死法必须同样收场。
    //   ★★ 收口内部有**两处顺序是承重的**(修复轮 3 的 C/D):
    //     · D —— "dead 只认第一个错因"这条不变量由这里的 `if (dead === null)` 保证。
    //       修复轮 2 只把这句守卫写在 terminate() 那一处,而注释里却写成收口的性质:
    //       别处再走一次收口就会把先前的死因覆盖掉。守卫挪进来,注释才成立。
    //     · C —— **先标死、先拒光、先清表,回收放最后**:worker.terminate() 万一抛,
    //       在飞的 promise 也已经拿到失败了。反过来的话这一抛会把它们全留下,
    //       而调用方只看到一个异常("谁都没被拒"这件事没有任何信号)。
    function reapWorker() {
      // ★ 先置空引用,再 terminate:terminate() 若抛,也不留下一个"看着还活着"的 worker。
      var w = worker;
      worker = null;
      if (w && typeof w.terminate === 'function') w.terminate();
    }
    function failAll(err) {
      if (dead === null) dead = err;
      // ★ 在飞的每一条都要**连定时器一起撤**:留着的话它们会在 30 秒后对一条**已经死透、
      //   连 worker 引用都置空**的链再走一遍收口(无害,但那是"事后还在响的闹钟",
      //   而任何"事后还在动的东西"都会让下一次排查多一个假嫌疑)。
      pending.forEach(function (p) { clearEntry(p); p.reject(err); });
      pending.clear();
      reapWorker();
    }

    function ensure() {
      if (dead) throw dead;
      if (worker) return worker;
      worker = factory();
      worker.onmessage = function (ev) {
        var m = (ev && ev.data) ? ev.data : {};
        var p = pending.get(m.id);
        // ★ 表里没有的应答**直接丢**:它只可能来自 terminate 前发出去的那一批。
        //   不丢的话就是"上一次的迟到结果写进这一次的 promise"。
        if (!p) return;
        pending.delete(m.id);
        clearEntry(p);                   // ★ 答复到了 ⇒ 那个闹钟必须撤掉(见 clearEntry)
        if (m.ok) p.resolve(m);
        else p.reject(new Error(m.error || 'worker 报告失败但没给原因'));
      };
      // ★ **无条件**覆盖,不能写成 `if (typeof worker.onerror !== 'function')`:
      //   工厂若返回一个自带 onerror 的 worker,那种写法就**不订阅**本 codec 的失败处理 ——
      //   于是 worker 崩溃后所有在飞请求永久悬挂,而代码看上去"已经处理了 onerror"。
      worker.onerror = function (ev) {
        var msg = (ev && ev.message) ? ev.message : 'worker 内部错误';
        failAll(new Error('Io: 编解码 worker 出错 —— ' + msg));
      };
      return worker;
    }

    function call(op, payload) {
      return new Promise(function (resolve, reject) {
        var w = ensure();
        var id = ++seq;
        var entry = { resolve: resolve, reject: reject, timer: null };
        // ★★ 装闹钟。回调里**不自己拒这一条**:走 `failAll` 那一个收口 ——
        //    于是"这一条被拒 + 其余在飞的被拒 + codec 标死 + worker 被回收"四件事
        //    与 terminate/onerror 两条死法**逐字同一份代码**。只拒自己那一条(不标死)的话,
        //    下一次调用会**静默**再起一个 worker,变成"每 30 秒一次失败"的无限循环。
        if (timeoutMs > 0) {
          entry.timer = timer.setTimeout(function () {
            entry.timer = null;            // 这个闹钟已经响过,别再撤销一次
            failAll(new Error('Io: 编解码请求超时(' + timeoutMs + ' 毫秒没有应答)—— ' +
                              'worker 多半已经死了(它没有发 onerror)。这条链已标死,' +
                              '之后的每一次调用都会**当场**失败,而不是静默再起一个 worker。'));
          }, timeoutMs);
        }
        pending.set(id, entry);
        var msg = { id: id, op: op };
        for (var k in payload) msg[k] = payload[k];
        try {
          w.postMessage(msg);
        } catch (e) {
          // ★ postMessage 会抛(浏览器里不可结构化克隆的 map 就是 DataCloneError)。
          //   不把表里那条删掉的话:resolver 被永久攥着、pendingCount() 再也回不到 0,
          //   而调用方只看到一次失败 —— "表里悄悄漏了一条"这种账目错没人会去查。
          //   这里只清自己那条:**单条消息发不出去不等于整条链坏了**,codec 不标死。
          //   ★ 那个闹钟也要撤 —— 不撤的话,30 秒后一次**本来与它无关**的超时会把整条链打死。
          clearEntry(entry);
          pending.delete(id);
          throw e;                       // 在 Promise 执行器里抛 = 这个 promise 被拒
        }
      });
    }

    return {
      encodeMap: function (map, o) {
        return call('encode', { map: map, compress: !(o && o.compress === false) })
          .then(function (m) { return m.bytes; });
      },
      decodeMap: function (bytes) {
        return call('decode', { bytes: bytes }).then(function (m) { return m.map; });
      },
      ping: function () { return call('ping', {}); },
      pendingCount: function () { return pending.size; },
      isDead: function () { return dead !== null; },
      terminate: function () {
        // ★ terminate 之后**不可能**再有应答回来(worker 已死,worker.js 的应答也走不回来),
        //   所以在飞请求必须当场拒掉:留着就是永不 settle 的 promise,调用方以为"停掉它
        //   就不再有后台活动"却一直挂在 await 上。连带标死 —— 否则下一次调用会**静默**
        //   新建一个 worker,而调用方以为自己已经把它关掉了。
        //   ★★ 修复轮 3 起这里**不再**自己先回收一刀、也不自带 `if (dead === null)` 守卫:
        //     调用方的守卫管不了"回收本身抛错"那条路 —— 那一抛会让本方法带着"dead 还没立、
        //     worker 引用还没置空"的状态退出,留下一个看着还活着的 codec(C);
        //     "保留先前死因"这条不变量也挪进了 failAll(D),两处守卫同一句话会各自漂。
        //     两条死法(terminate / onerror)现在**逐字**只走同一个收口。
        failAll(new Error('Io: codec 已被 terminate() —— 在飞的请求不会再有应答'));
      },
    };
  }

  var shared = null;
  function sharedCodec() { if (!shared) shared = createCodec(); return shared; }

  return {
    createCodec: createCodec,
    TIMEOUT_MS: DEFAULT_TIMEOUT_MS,
    workerAvailable: function () { return typeof Worker !== 'undefined'; },
    encodeMap: function (map, o) { return sharedCodec().encodeMap(map, o); },
    decodeMap: function (bytes) { return sharedCodec().decodeMap(bytes); },
    ping: function () { return sharedCodec().ping(); },
  };
})();
