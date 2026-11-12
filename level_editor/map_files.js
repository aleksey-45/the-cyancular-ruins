'use strict';

const MapFiles = (() => {
  const NAME_PATTERN = /^[A-Za-z0-9_-]{1,64}\.cyrm$/;

  function checkName(name) {
    if (!NAME_PATTERN.test(name)) throw new Error('地图名限 1–64 个英文字母、数字、下划线或连字符');
    return name;
  }

  function backupName(name) { return name + '.' + crypto.randomUUID() + '.bak'; }

  function download(name, bytes) {
    const url = URL.createObjectURL(new Blob([bytes], {type: 'application/octet-stream'}));
    const link = document.createElement('a');
    link.href = url;
    link.download = name;
    link.click();
    setTimeout(() => URL.revokeObjectURL(url), 60000);
  }

  function server() {
    const url = name => '/api/map?p=' + encodeURIComponent(checkName(name));
    async function request(path, method = 'GET', body) {
      const res = await fetch(path, method === 'GET' ? undefined : {
        method, body, headers: {'Content-Type': 'application/json'},
      });
      if (!res.ok) throw new Error(await res.text());
      return res;
    }
    return {
      label: '服务器 maps/', scope: '',
      async list() { return (await (await request('/api/maps')).json()).maps; },
      async read(name) { return new Uint8Array(await (await request(url(name))).arrayBuffer()); },
      async write(name, bytes, {create, backup} = {}) {
        const query = create ? '&create=1' : backup ? '&backup=1' : '';
        return (await request(url(name) + query, 'PUT', bytes)).json();
      },
      async rename(from, to) {
        await request(url(from) + '&to=' + encodeURIComponent(checkName(to)), 'POST');
      },
      async remove(name) { await request(url(name), 'DELETE'); },
    };
  }

  function directory(handle, scope) {
    function mutate(task) {
      return navigator.locks ? navigator.locks.request('cyrm-directory-write', task) : task();
    }
    async function exists(name) {
      try { await handle.getFileHandle(name); return true; }
      catch (e) { if (e.name === 'NotFoundError') return false; throw e; }
    }
    async function read(name) {
      const file = await (await handle.getFileHandle(name)).getFile();
      return new Uint8Array(await file.arrayBuffer());
    }
    async function writeFile(name, bytes, create) {
      if (create && await exists(name)) throw new Error('同名文件已存在：' + name);
      const target = await handle.getFileHandle(name, {create: !!create});
      let writer;
      try {
        writer = await target.createWritable({mode: 'exclusive'});
        await writer.write(bytes);
        await writer.close();
      } catch (e) {
        if (writer) await writer.abort().catch(() => {});
        if (create) await handle.removeEntry(name).catch(() => {});
        throw e;
      }
    }
    return {
      label: '本地目录 · ' + handle.name, scope,
      async list() {
        const rows = [];
        for await (const entry of handle.values()) {
          if (entry.kind !== 'file' || !NAME_PATTERN.test(entry.name)) continue;
          const file = await entry.getFile();
          rows.push({name: file.name, size: file.size, mtime: file.lastModified});
        }
        return rows.sort((a, b) => a.name.localeCompare(b.name));
      },
      read: name => read(checkName(name)),
      write(name, bytes, {create, backup} = {}) {
        checkName(name);
        return mutate(async () => {
          const original = backup ? backupName(name) : null;
          if (original) await writeFile(original, await read(name), true);
          await writeFile(name, bytes, create);
          return {name, size: bytes.length, backup: original};
        });
      },
      rename(from, to) {
        checkName(from);
        checkName(to);
        return mutate(async () => {
          await writeFile(to, await read(from), true);
          try { await handle.removeEntry(from); }
          catch (e) { throw new Error('已写入 ' + to + '，删除原件失败：' + e.message); }
        });
      },
      remove: name => mutate(() => handle.removeEntry(checkName(name))),
    };
  }

  function downloads(send = download) {
    const files = new Map();
    return {
      label: '浏览器下载', scope: 'download:',
      async list() { return Array.from(files.values(), ({name, size, mtime}) => ({name, size, mtime})); },
      async read(name) { return files.get(checkName(name)).bytes; },
      async write(name, bytes, {create} = {}) {
        checkName(name);
        if (create && files.has(name)) throw new Error('同名文件已存在：' + name);
        send(name, bytes);
        files.set(name, {name, size: bytes.length, mtime: Date.now(), bytes});
        return {name, size: bytes.length, download: true};
      },
    };
  }

  return {NAME_PATTERN, checkName, backupName, server, directory, downloads, download};
})();

if (typeof module !== 'undefined') module.exports = MapFiles;
