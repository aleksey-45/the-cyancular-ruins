'use strict';

// 离线版的文件适配器；不覆盖浏览器 fetch、Worker 或编解码实现。
globalThis.StandaloneFiles = (function () {
  function createStore(download) {
    var directory = null;
    var files = new Map();

    function validName(name) {
      return name && name !== '.' && name !== '..' &&
        !/[\\/:*?"<>|\x00-\x1f]/.test(name) && /\.cyrm$/i.test(name);
    }

    async function list() {
      var rows = [];
      if (directory) {
        for await (var entry of directory.values()) {
          if (entry.kind === 'file' && /\.cyrm$/i.test(entry.name)) {
            var file = await entry.getFile();
            rows.push({ name: file.name, size: file.size, mtime: file.lastModified });
          }
        }
      } else {
        files.forEach(function (file, name) {
          if (/\.cyrm$/i.test(name)) rows.push({ name: name, size: file.size, mtime: file.lastModified || Date.now() });
        });
      }
      return rows.sort(function (a, b) { return a.name.localeCompare(b.name); });
    }

    async function request(url, options) {
      var parsed = new URL(url, 'https://cyrm.invalid');
      var method = (options && options.method || 'GET').toUpperCase();
      if (parsed.pathname === '/api/maps' && method === 'GET') {
        return Response.json({ maps: await list() });
      }
      var name = parsed.searchParams.get('p');
      if (parsed.pathname !== '/api/map') return new Response(null, { status: 404 });
      if (!validName(name)) return new Response(null, { status: 400 });
      if (method === 'GET') {
        try {
          var source = directory ? await (await directory.getFileHandle(name)).getFile() : files.get(name);
          return source ? new Response(source) : new Response(null, { status: 404 });
        } catch (error) {
          if (error.name === 'NotFoundError') return new Response(null, { status: 404 });
          throw error;
        }
      }
      if (method !== 'PUT') return new Response(null, { status: 405 });
      var bytes = options.body;
      if (directory) {
        var handle = await directory.getFileHandle(name, { create: true });
        var stream = await handle.createWritable();
        try {
          await stream.write(bytes);
          await stream.close();
        } catch (error) {
          await stream.abort().catch(function () {});
          throw error;
        }
      } else {
        await download(name, bytes);
        files.set(name, bytes);
      }
      return Response.json({ ok: true, name: name });
    }

    return {
      request: request,
      useDirectory: function (handle) { directory = handle; files.clear(); },
      addFiles: function (selection) {
        directory = null;
        Array.from(selection).forEach(function (file) { if (validName(file.name)) files.set(file.name, file); });
      },
    };
  }

  function mount(environment) {
    var store = createStore(function (name, bytes) {
      var url = URL.createObjectURL(bytes);
      var link = document.createElement('a');
      link.href = url;
      link.download = name;
      link.click();
      setTimeout(function () { URL.revokeObjectURL(url); }, 60000);
    });
    environment.request = store.request;
    document.addEventListener('DOMContentLoaded', function () {
      var library = document.getElementById('lib');
      library.querySelector('h2').textContent = '本地地图';
      var note = document.createElement('p');
      note.style.cssText = 'margin:8px 10px;color:var(--dim)';
      note.textContent = '未选择目录时，保存会下载文件，请完成浏览器的下载保存。';
      library.insertBefore(note, document.getElementById('lib-list'));
      var input = document.createElement('input');
      input.type = 'file'; input.accept = '.cyrm'; input.multiple = true; input.hidden = true;
      library.appendChild(input);
      function report(error) {
        if (error.name !== 'AbortError') document.getElementById('status-msg').textContent = '文件操作失败：' + error.message;
      }
      var open = document.createElement('button');
      open.textContent = '打开文件…';
      open.onclick = function () { input.click(); };
      input.onchange = async function () {
        try {
          if (!input.files.length) return;
          if (Editor.app.map && !window.confirm('打开文件会替换当前画布，请先保存当前地图。继续吗？')) return;
          var first = input.files[0].name;
          store.addFiles(input.files);
          note.textContent = '保存会下载文件，请完成浏览器的下载保存。';
          await Editor.refreshLibrary();
          await Editor.openMap(first);
        } catch (error) { report(error); }
        finally { input.value = ''; }
      };
      var buttons = document.getElementById('lib-btns');
      buttons.prepend(open);
      if (typeof window.showDirectoryPicker === 'function') {
        var choose = document.createElement('button');
        choose.textContent = '选择地图目录…';
        choose.onclick = async function () {
          try {
            var handle = await window.showDirectoryPicker({ mode: 'readwrite' });
            // 换目录保留画布，但存盘需先明确新目标，避免把旧地图误写入同名文件。
            if (Editor.app.map && !window.confirm('切换目录后，保存会写入新目录。请先保存当前地图。继续吗？')) return;
            store.useDirectory(handle);
            note.textContent = '保存到目录：' + handle.name;
            await Editor.refreshLibrary();
          } catch (error) { report(error); }
        };
        buttons.prepend(choose);
      }
    });
  }

  return { createStore: createStore, mount: mount };
})();
