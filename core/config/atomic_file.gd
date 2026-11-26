class_name AtomicFile
extends RefCounted

static func save(path: String, store: Callable) -> Error:
	var target := ProjectSettings.globalize_path(path)
	var temporary := "%s.%d.%d.tmp" % [target, OS.get_process_id(), Time.get_ticks_usec()]
	var file := FileAccess.open(temporary, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	var stored: bool = store.call(file)
	file.flush()
	var error := file.get_error() if stored else ERR_FILE_CANT_WRITE
	file.close()
	if error == OK: error = DirAccess.rename_absolute(temporary, target)
	if error != OK:
		DirAccess.remove_absolute(temporary)
	return error
