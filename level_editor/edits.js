// 单格用异或差量，地图字段交换所有权。相同操作可向前或向后应用。
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

  // 每个目标子格只提交一次。读完整个原图后再一起写回，允许源区与目标区重叠。
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

  // 沿用原有历史预算，改变内部表示后，相同操作仍在同一步淘汰旧记录。
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
