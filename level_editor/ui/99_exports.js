// ui/99_exports.js —— 公开 API 表。node 侧冒烟按它取名字。


globalThis.Editor = {
  boot: boot, bootLoad: bootLoad, guard: guard, status: status, msgOf: msgOf,
  setErrorSink: setErrorSink, reportError: reportError,
  nameFromFile: nameFromFile, detectFormat: detectFormat, mapFromBytes: mapFromBytes,
  openMap: openMap, openFromUrl: openFromUrl, refreshLibrary: refreshLibrary,
  putMapBytes: putMapBytes,
  selfTest: selfTest, refreshStatus: refreshStatus,
  app: app,

  TOOLS: TOOLS, TOOL_LABELS: TOOL_LABELS, DERIVED_TEXTURES: DERIVED_TEXTURES,
  createEmptyMap: createEmptyMap, resizeMap: resizeMap, resizeReportLines: resizeReportLines,
  // ★ 改尺寸面板(规格 A10)与"压缩"开关(规格 §3.5)接上之后,下面这几个才有生产调用点 —— 在那之前
  //   resizeMap 只被 btn-dup 用(尺寸不变),wholeDiff / applyEntry 的 whole 分支只有测试在跑。
  applySize: applySize, sizeInputsSync: sizeInputsSync, adoptMapInto: adoptMapInto,
  optCompress: optCompress, encodeForWrite: encodeForWrite, DEFAULT_COMPRESS: DEFAULT_COMPRESS,
  texturePalette: texturePalette, clampTexture: clampTexture, validateLines: validateLines,
  paintCells: paintCells, valueFor: valueFor, regionCells: regionCells, inRect: inRect,
  idxOf: idxOf, strokePoints: strokePoints, lineTargets: lineTargets, toSub: toSub,
  constrainLine: constrainLine, constrainSquare: constrainSquare,
  applyTool: applyTool, pickAt: pickAt,
  createBucketJob: createBucketJob, createGradientJob: createGradientJob, lerpRGBA: lerpRGBA,
  snapshotSpawns: snapshotSpawns, spawnDiff: spawnDiff, spawnIndexAt: spawnIndexAt,
  addSpawn: addSpawn, removeSpawn: removeSpawn, clearSpawns: clearSpawns,
  commandFor: commandFor, hasSelection: hasSelection, isTypingTarget: isTypingTarget,
  MAX_UNDO: MAX_UNDO, MAX_UNDO_BYTES: MAX_UNDO_BYTES, bytesOfEntry: bytesOfEntry,
  createHistory: createHistory, snapshotMap: snapshotMap, bytesOfSnapshot: bytesOfSnapshot,
  wholeDiff: wholeDiff, applyEntry: applyEntry, diffCells: diffCells, cellCountOf: cellCountOf,
  copyRegion: copyRegion, clipSize: clipSize, pasteRegion: pasteRegion,
  moveRegion: moveRegion, mirrorRegion: mirrorRegion, mirrorSelection: mirrorSelection,
  installInteraction: installInteraction, runJob: runJob, statusLine: statusLine,
  pushAndShow: pushAndShow, doUndo: doUndo, doRedo: doRedo, hitOf: hitOf,
  brushSteps: function () { return BRUSH_STEPS.slice(); }, setBrush: setBrush, setLayer: setLayer,

  buildPanels: buildPanels, syncPanelForLayer: syncPanelForLayer,
  saveCurrent: saveCurrent, saveTargetName: saveTargetName,
  needsV3Confirm: needsV3Confirm, needsV3Backup: needsV3Backup,
  v3BackupName: v3BackupName, isBackupName: isBackupName, freshName: freshName,
  // ★ runSelfTest 是自检那条异步入口的具名收口(相位 ⑮b⑩b ③ 驱动它);dropStaleSelection 给相位 ⑰ 直接用。
  runSelfTest: runSelfTest, dropStaleSelection: dropStaleSelection,
  importEnemyTypes: importEnemyTypes, exportReport: exportReport, showExportReport: showExportReport,
  spawnAt: spawnAt,

  // ── 持久化三层 + 闸 4 ──
  DRAFT_DB: DRAFT_DB, DRAFT_STORE: DRAFT_STORE, CRASH_STORE: CRASH_STORE,
  UI_STATE_KEY: UI_STATE_KEY, MAX_LIB: MAX_LIB, DRAFT_DEBOUNCE_MS: DRAFT_DEBOUNCE_MS,
  draftKey: draftKey, crashIsNewer: crashIsNewer, evictPlan: evictPlan,
  uiStateDefaults: uiStateDefaults, readUiState: readUiState, writeUiState: writeUiState,
  openDraftStore: openDraftStore, saveDraft: saveDraft, loadDraft: loadDraft,
  installCrashFence: installCrashFence, checkCrashSlot: checkCrashSlot,
  applyUiState: applyUiState, persistUi: persistUi, installUiStateSave: installUiStateSave,
  // ★ 下面几个是"接线"那一半的可驱动面:node 侧靠 export 出来的入口 + 一个假 IndexedDB 把同一条链
  //   真跑一遍(见 editor_smoke 相位 ⑮b)。
  markDirty: markDirty, scheduleDraftSave: scheduleDraftSave, flushDraft: flushDraft,
  markDraftSaved: markDraftSaved, offerDraft: offerDraft,
};
