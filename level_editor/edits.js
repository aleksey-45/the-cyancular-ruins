// 每个子格只记录修改前后数值的异或值。用该值异或一次即可撤销，再异或一次即可重做。
// 对地图尺寸或元数据执行撤销和重做时，交换地图当前字段与修改记录里的字段。
globalThis.Edits = (function () {
  'use strict';

  function toggle(map, edit) {
    if (edit.kind === 'cells') {
      const values = Core.layerArray(map, edit.layer);
      for (let i = 0; i < edit.idx.length; i++) values[edit.idx[i]] ^= edit.xor[i];
    } else {
      for (const key of Object.keys(edit.fields)) {
        const previous = map[key];
        map[key] = edit.fields[key];
        edit.fields[key] = previous;
      }
    }
    return edit;
  }

  // 先从原图收集所有修改，再统一写入。移动选区时，即使原位置和目标重叠，也能完整读取原选区。
  function cells(map, layer, plan) {
    const values = Core.layerArray(map, layer);
    if (!values || !values.length) return null;
    const indices = [], xor = [];
    plan(values, (index, next) => {
      const change = values[index] ^ next;
      if (change !== 0) {
        indices.push(index);
        xor.push(change);
      }
    });
    if (!indices.length) return null;
    return toggle(map, {kind: 'cells', layer, idx: Int32Array.from(indices), xor: Uint32Array.from(xor),
                        cost: 12 + 12 * indices.length});
  }

  // 根据出生点、敌人和复活点的数量估算记录占用的内存。若记录里保存了整张地图，还要计入各图层的大小。
  function fieldCost(map, whole) {
    let cost = 32 * (map.players.length + map.enemies.length + map.respawns.length);
    if (whole) {
      for (let layer = 0; layer < map.layers.length; layer++) {
        cost += Core.layerArray(map, layer)?.byteLength || 0;
      }
    }
    return cost;
  }

  function replace(map, fields, kind = 'spawn') {
    const whole = kind === 'whole';
    const cost = 64 + fieldCost(map, whole);
    const edit = toggle(map, {kind, fields});
    edit.cost = cost + fieldCost(map, whole);
    return edit;
  }

  function resize(map, replacement) {
    const {name, ...fields} = replacement;
    return replace(map, fields, 'whole');
  }

  function history({maxSteps = 200, maxBytes = 64 * 1024 * 1024} = {}) {
    const entries = [];
    let cursor = 0, cost = 0;
    return {
      push(edit) {
        if (!edit) return;
        entries.length = cursor;
        entries.push(edit);
        cursor++;
        cost += edit.cost;
        while (cursor > maxSteps || (cost > maxBytes && cursor > 1)) {
          cost -= entries.shift().cost;
          cursor--;
        }
      },
      step(map, dir) {
        const next = cursor + dir;
        if (next < 0 || next > entries.length) return null;
        const edit = entries[Math.min(cursor, next)];
        cursor = next;
        cost += dir * edit.cost;
        return toggle(map, edit);
      },
      depth() { return cursor; },
      redoDepth() { return entries.length - cursor; },
      clear() { entries.length = cursor = cost = 0; },
    };
  }

  return {cells, replace, resize, history};
})();
