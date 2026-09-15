'use strict';
// 从 data/enemies.json 重新生成 structure-editor.html 内嵌的敌人注册表
// (/*__ENEMY_REGISTRY_BEGIN__*/ ... /*__ENEMY_REGISTRY_END__*/ 之间)。
// 用法:node level_editor/sync-enemies.js [--check]
//   --check: 只校验不写盘。改了 data/enemies.json 忘跑本脚本(或在 json 里加了字段却忘了
//            同步下面的字段级手抄)→ HTML 内嵌的那份**静默漂移**。一致退出 0;漂移退出 1。
const fs = require('fs');
const path = require('path');

const dir = __dirname;
const jsonPath = path.join(dir, '..', 'data', 'enemies.json');
const htmlPath = path.join(dir, 'structure-editor.html');

const json = JSON.parse(fs.readFileSync(jsonPath, 'utf8'));
const enemies = (json.enemies || []).map(function (e) {
  return {
    id: String(e.id),
    name: String(e.name),
    // display_name:击杀播报用的中文名(EnemySpawner.display_name_of 读它)。
    // ★ 本脚本是**字段级手抄**:enemies.json 加字段时必须同步加到这里,否则 HTML 内嵌的这份
    //   会静默丢字段(编辑器当下不用它,丢了也没人报错 —— 正是那种安静的漂移)。
    display_name: String(e.display_name || e.name),
    scene: String(e.scene),
    color: String(e.color || '#999999')
  };
});
const block = '/*__ENEMY_REGISTRY_BEGIN__*/\nwindow.ENEMY_REGISTRY = ' +
  JSON.stringify(enemies, null, 2) + ';\n/*__ENEMY_REGISTRY_END__*/';

// ★ 上面那份是**字段级手抄**的守卫:源 json 里出现的每个键都必须被映射到。
//   只比对"生成物 vs 重新生成"是**抓不到**这个的 —— 两边用的是同一份映射,漏抄的字段
//   在两边一样地缺,`--check` 照样绿。故单独查一遍键覆盖。
//   有字段**故意**不进编辑器时,加进下面这个名单并写明理由,别默默漏掉。
const NOT_IN_EDITOR = [];   // 当前为空:enemies.json 的 5 个字段全部进注册表
const generatedKeys = {};
enemies.forEach(function (e) { Object.keys(e).forEach(function (k) { generatedKeys[k] = true; }); });
const dropped = {};
(json.enemies || []).forEach(function (e) {
  Object.keys(e).forEach(function (k) {
    if (!generatedKeys[k] && NOT_IN_EDITOR.indexOf(k) < 0) dropped[k] = true;
  });
});
if (Object.keys(dropped).length) {
  console.error('FAIL: data/enemies.json 里有字段没被抄进注册表: ' + Object.keys(dropped).join(', '));
  console.error('      要么在 map 里带上它,要么加进 NOT_IN_EDITOR 并写明理由。');
  process.exit(1);
}

let html = fs.readFileSync(htmlPath, 'utf8');
const re = /\/\*__ENEMY_REGISTRY_BEGIN__\*\/[\s\S]*?\/\*__ENEMY_REGISTRY_END__\*\//;
if (!re.test(html)) {
  console.error('FAIL: 未在 HTML 找到注册表标记 /*__ENEMY_REGISTRY_BEGIN__*/');
  process.exit(1);
}

if (process.argv.includes('--check')) {
  // 只比**注册表块**本身(HTML 其余部分与本脚本无关);行尾归一,免得编辑器改成 CRLF 就误报
  // (该 HTML 主体本来就是 CRLF,内嵌块是 LF —— 正是这种混排最容易踩)。
  const norm = function (s) { return s.replace(/\r\n/g, '\n'); };
  const actual = norm(html.match(re)[0]);
  const expected = norm(block);
  if (actual === expected) {
    console.log('ok: structure-editor.html 的敌人注册表与 data/enemies.json 一致(' +
      enemies.map(function (e) { return e.id; }).join(', ') + ')');
    process.exit(0);
  }
  console.error('FAIL: structure-editor.html 的敌人注册表已漂移 —— 跑 `node level_editor/sync-enemies.js` 重新生成');
  const a = actual.split('\n');
  const b = expected.split('\n');
  for (let i = 0; i < Math.max(a.length, b.length); i++) {
    if (a[i] !== b[i]) {
      console.error('  注册表块第 ' + (i + 1) + ' 行');
      console.error('    盘上: ' + String(a[i]).slice(0, 120));
      console.error('    应为: ' + String(b[i]).slice(0, 120));
      break;
    }
  }
  process.exit(1);
}

html = html.replace(re, block);
fs.writeFileSync(htmlPath, html);
console.log('ok: 敌人注册表已同步 ' + enemies.map(function (e) { return e.id; }).join(', '));
