// core/50_compress.js —— zlib(deflate)进出,走运行时原生流。


// 走运行时原生 CompressionStream('deflate'):产出 zlib(RFC1950),与 Godot 侧 decompress(COMPRESSION_DEFLATE) 对应。
function deflateBytes(bytes) {
  // ★ 三个全局都要守(本函数与 inflateBytes 同理):new Response(...) 在缺 Response 的环境里同步抛,会逃出 promise 契约。
  if (typeof CompressionStream === 'undefined' || typeof Blob === 'undefined' ||
      typeof Response === 'undefined') {
    return Promise.reject(new Error(
      'deflateBytes: 本环境没有 CompressionStream/Blob/Response;请用 encodeMap(map, {compress:false}) 导出裸 body'));
  }
  var stream = new Blob([bytes]).stream().pipeThrough(new CompressionStream('deflate'));
  return new Response(stream).arrayBuffer().then(function (buf) { return new Uint8Array(buf); });
}
// 流式解压,累计输出超过 maxBytes 就中止并拒绝(maxBytes 缺省 = 不设限;唯一调用方 decodeMap 传的是头部声明的 body_size)。
// ★ 上界必须作用在实际输出上:body_size 本身攻击者可控(谎报 4096 + 真炸弹),判在解压之后内存已经花掉(推导见 docs/eng/editor-core.md)。
function inflateBytes(bytes, maxBytes) {
  if (typeof DecompressionStream === 'undefined' || typeof Blob === 'undefined' ||
      typeof Response === 'undefined') {
    return Promise.reject(new Error('inflateBytes: 本环境没有 DecompressionStream/Blob/Response'));
  }
  var stream = new Blob([bytes]).stream().pipeThrough(new DecompressionStream('deflate'));
  if (maxBytes === undefined) {
    return new Response(stream).arrayBuffer().then(function (buf) { return new Uint8Array(buf); });
  }
  var reader = stream.getReader();
  var chunks = [];
  var total = 0;
  function pump() {
    return reader.read().then(function (res) {
      if (res.done) {
        var out = new Uint8Array(total);
        var off = 0;
        for (var i = 0; i < chunks.length; i++) { out.set(chunks[i], off); off += chunks[i].length; }
        return out;
      }
      var chunk = res.value || new Uint8Array(0);
      total += chunk.length;
      // ★ 判在 push 之前(超限块不留下);先抛再 cancel —— cancel 不 settle 会让这条路永不 settle ⇒ 假绿(实测见 docs/eng/editor-core.md)。
      if (total > maxBytes) {
        var err = new Error('inflateBytes: 解压输出超过 ' + maxBytes + ' 字节上限(已累计 ' +
                            total + ' 字节),中止');
        reader.cancel().catch(function () {});
        throw err;
      }
      chunks.push(chunk);
      return pump();
    });
  }
  return pump();
}
