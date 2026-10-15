// build_dist.js —— 把整个编辑器打成**一个 HTML 文件**(dist/cyrm-editor.html)。
// 做法:按 editor.html 的 <script src> 顺序把每个分片原样内联,再把独立版的运行时垫片
// (standalone_shim.js)接在最后;worker.js 只作为**字符串**带进去(同页实例要用它的源码)。
// ★ 生成物不要手改:改完源码重跑 `node build_dist.js`;漂了用 `node build_dist.js --check` 抓。
// 用法:node build_dist.js [--check]
'use strict';

const fs = require('fs');
const path = require('path');

const DIR = __dirname;
const OUT = path.join(DIR, 'dist', 'cyrm-editor.html');

function build() {
  const html = fs.readFileSync(path.join(DIR, 'editor.html'), 'utf8');
  const worker = fs.readFileSync(path.join(DIR, 'worker.js'), 'utf8');
  const shim = fs.readFileSync(path.join(DIR, 'standalone_shim.js'), 'utf8');
  // 图集也内联:file:// 下旁边没有 structure.png,不内联就是"画布全空"(自检会点名)。
  const atlas = 'data:image/png;base64,' +
    fs.readFileSync(path.join(DIR, 'structure.png')).toString('base64');
  const inlined = [];
  const missing = [];

  let out = html.replace(/[ \t]*<script src="([^"]+)"><\/script>/g, function (m, rel) {
    const file = path.join(DIR, rel);
    if (!fs.existsSync(file)) { missing.push(rel); return m; }
    const src = fs.readFileSync(file, 'utf8');
    // 内联的前提:源码里不能出现 </script(否则提前闭合,静默截断后半页)。
    if (src.indexOf('</script') >= 0) throw new Error(rel + ' 里含 </script,无法内联');
    inlined.push(rel);
    return '<script>\n/* == ' + rel + ' == */\n' + src.replace(/\s+$/, '') + '\n</script>';
  });
  if (missing.length) throw new Error('editor.html 引用了不存在的文件:' + missing.join(', '));

  const config = [
    '<script>',
    '// 单文件版的运行时开关(见 level_editor/standalone_shim.js):没有服务器,没有 Worker。',
    'window.__CYRM_STANDALONE__ = true;',
    'window.__CYRM_ATLAS_URL__ = ' + JSON.stringify(atlas) + ';',
    'window.__CYRM_WORKER_SRC__ = ' + JSON.stringify(worker) + ';',
    '</script>',
  ].join('\n');
  out = out.replace(/<body>/, '<body>\n' + config);
  out = out.replace(/<\/body>/, '<script>\n/* == standalone_shim.js == */\n' + shim.replace(/\s+$/, '') + '\n</script>\n</body>');
  out = out.replace(/<head>/,
    '<head>\n<!-- 生成物:node build_dist.js 产出;改源码后重跑,别手改这个文件。 -->');
  return { text: out, inlined: inlined };
}

module.exports = { build, OUT };

function main() {
  const res = build();
  if (process.argv.indexOf('--check') >= 0) {
    if (!fs.existsSync(OUT)) { console.error('DIST CHECK FAIL:还没有 ' + OUT); process.exit(1); }
    const cur = fs.readFileSync(OUT, 'utf8');
    if (cur === res.text) { console.log('DIST CHECK OK(' + res.inlined.length + ' 片,' + res.text.length + ' 字节)'); process.exit(0); }
    let i = 0;
    while (i < cur.length && i < res.text.length && cur[i] === res.text[i]) i++;
    console.error('DIST CHECK FAIL:与源码不一致(第 ' + i + ' 字符起)。重跑 node build_dist.js');
    process.exit(1);
  }
  fs.mkdirSync(path.dirname(OUT), { recursive: true });
  fs.writeFileSync(OUT, res.text);
  console.log('写出 ' + path.relative(process.cwd(), OUT) + ':' + res.inlined.length + ' 片内联,' + res.text.length + ' 字节');
}

if (require.main === module) main();
