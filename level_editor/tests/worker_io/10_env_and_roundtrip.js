'use strict';
// tests/worker_io/10_env_and_roundtrip.js —— 环境常量与常量、经真 worker.js 的协议往返、
// 裸路径(compression = 0)与错误回传。
const Core = globalThis.Core;
const Io = globalThis.Io;

module.exports = (async function () {
  // ==== 相位 ① 环境与常量 ====
  ok(Io.workerAvailable() === false, '★ node 里 workerAvailable() === false(node 没有浏览器 Worker)');
  await rejects(function () { return Io.encodeMap(Core.createMap('x', 1, 1)); },
                '★ 没有 Worker 且没注入 factory → 抛错(不静默退回主线程)',
                'Worker');
  ok(live === null, '那次失败**没有**建出任何 worker');

  // ==== 相位 ② 真协议往返(经真的 worker.js 与真的 core.js)====
  codec = Io.createCodec({ workerFactory: makeWorker });
  const m = fillMap(fillMap(fillMap(Core.createMap('w', 3, 2), Core.LAYER_SCENE, 7), Core.LAYER_FRONT, 11),
                    Core.LAYER_BG, 13);
  m.players = [{ x: 1, y: 1 }];
  m.enemies = [{ type: 'fly_bird', x: 2, y: 1 }];
  m.comments = ['经 Worker 往返'];

  const bytes = await codec.encodeMap(m);
  ok(bytes instanceof Uint8Array, 'encodeMap 经 Worker 拿回 Uint8Array');
  ok(bytes.length > Core.HEADER_SIZE, '字节数 > 20(实得 ' + bytes.length + ')');
  sameBytes(bytes.subarray(0, 4), new Uint8Array([0x43, 0x59, 0x52, 0x4D]),
            '★ 头部 magic 仍是 "CYRM"(worker 没动内容)');
  eq(bytes[4], Core.FORMAT_VERSION, '版本字节 = ' + Core.FORMAT_VERSION);
  eq(bytes[5], 1, '默认走压缩路径(compression = 1)');

  const back = await codec.decodeMap(bytes);
  sameBytes(back.layers[Core.LAYER_SCENE].desc, m.layers[Core.LAYER_SCENE].desc, '往返:场景层一致');
  sameBytes(back.layers[Core.LAYER_FRONT].desc, m.layers[Core.LAYER_FRONT].desc, '往返:前景层一致');
  sameBytes(back.layers[Core.LAYER_BG].rgba, m.layers[Core.LAYER_BG].rgba, '往返:背景层一致');
  eq(back.players, m.players, '往返:出生点一致');
  eq(back.enemies, m.enemies, '往返:敌人一致');
  eq(back.comments, m.comments, '往返:注释一致');

  // ==== 相位 ③ 裸路径(compression = 0)也要经 Worker ====
  const raw = await codec.encodeMap(m, { compress: false });
  eq(raw[5], 0, 'compress:false → compression 字节是 0');
  const backRaw = await codec.decodeMap(raw);
  sameBytes(backRaw.layers[Core.LAYER_SCENE].desc, m.layers[Core.LAYER_SCENE].desc, '裸路径往返一致');

  // ==== 相位 ④ 错误要带错因回到调用方 ====
  await rejects(function () { return codec.decodeMap(new Uint8Array(20)); },
                '损坏文件 → promise 被拒', 'magic');
  await rejects(function () { return codec.decodeMap(new Uint8Array([1, 2, 3])); },
                '太短的文件 → promise 被拒', '小于头部');
  const bad = new Uint8Array(bytes);
  bad[5] = 9;                                   // 未知 compression
  await rejects(function () { return codec.decodeMap(bad); }, '未知 compression → 被拒', 'compression');

})();
