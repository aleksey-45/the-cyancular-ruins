#!/usr/bin/env node
'use strict';

// 从现有入口收集资源，格式与渲染继续使用源码版的实现。
const fs = require('node:fs');
const path = require('node:path');
const root = __dirname;
const defaultOutput = path.join(root, 'dist', 'cyrm-editor.html');

function inlineScript(source) {
  return '<script>\n' + source.replace(/<\/script/gi, '<\\/script') + '\n</script>';
}

function bundle() {
  let html = fs.readFileSync(path.join(root, 'editor.html'), 'utf8');
  const tiles = fs.readFileSync(path.join(root, 'tile_defs.js'), 'utf8');
  const core = fs.readFileSync(path.join(root, 'core.js'), 'utf8');
  const worker = fs.readFileSync(path.join(root, 'worker.js'), 'utf8');
  const dependency = "importScripts('tile_defs.js', 'core.js');";
  if (!worker.includes(dependency)) throw new Error('worker.js 的依赖入口已变化，请更新离线打包器');
  const workerSource = worker.replace(dependency, () => tiles + '\n' + core);
  const atlas = fs.readFileSync(path.join(root, 'structure.png')).toString('base64');
  const bootstrap = 'globalThis.CYRM_OFFLINE = {\n' +
    'workerUrl: URL.createObjectURL(new Blob([' + JSON.stringify(workerSource) + '], {type:"text/javascript"})),\n' +
    'atlasUrl: "data:image/png;base64,' + atlas + '"\n};';
  let injected = false;
  html = html.replace(/<script src="([^"\s]+)"><\/script>/g, function (_, name) {
    const file = path.resolve(root, name);
    if (path.dirname(file) !== root) throw new Error('不支持的脚本路径：' + name);
    const prefix = injected ? '' : inlineScript(bootstrap);
    injected = true;
    return prefix + inlineScript(fs.readFileSync(file, 'utf8'));
  });
  if (!injected) throw new Error('没有找到编辑器脚本');
  return html;
}

function build(output = defaultOutput) {
  fs.mkdirSync(path.dirname(output), { recursive: true });
  fs.writeFileSync(output, bundle(), 'utf8');
  return output;
}

if (require.main === module) {
  if (process.argv[2] === '--check') {
    if (fs.existsSync(defaultOutput) && fs.readFileSync(defaultOutput, 'utf8') === bundle()) {
      console.log('离线版与源码一致');
    } else {
      console.error('请运行 node level_editor/build_dist.js 更新离线版');
      process.exitCode = 1;
    }
  } else {
    console.log(build(process.argv[2] && path.resolve(process.argv[2])));
  }
}
module.exports = { build };
