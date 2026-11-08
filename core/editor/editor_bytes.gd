class_name EditorBytes
extends RefCounted

# 镜像 level_editor/core/20_bytes.js —— 小端字节读写器与 CRC32。
# ★ 不抛错:Reader 越界时置 failed/error 并返回 0,上层每次读后必须判 failed(见 .tmp/editor-port-contract.md)。


class Writer:
	var buf: PackedByteArray = PackedByteArray()

	func u8(v: int) -> Writer:
		buf.append(v & 0xFF)
		return self

	func u16(v: int) -> Writer:
		buf.append(v & 0xFF)
		buf.append((v >> 8) & 0xFF)
		return self

	func u32(v: int) -> Writer:
		buf.append(v & 0xFF)
		buf.append((v >> 8) & 0xFF)
		buf.append((v >> 16) & 0xFF)
		buf.append((v >> 24) & 0xFF)
		return self

	func bytes(arr: PackedByteArray) -> Writer:
		buf.append_array(arr)
		return self

	func finish() -> PackedByteArray:
		return buf


class Reader:
	var b: PackedByteArray
	var p: int = 0
	var failed: bool = false
	var error: String = ""

	func _init(bytes: PackedByteArray) -> void:
		b = bytes

	func _need(n: int) -> bool:
		if p + n > b.size():
			failed = true
			if error == "":
				error = "ByteReader: 越界读(%d+%d > %d)" % [p, n, b.size()]
			return false
		return true

	func u8() -> int:
		if not _need(1):
			return 0
		var v := int(b[p])
		p += 1
		return v

	func u16() -> int:
		if not _need(2):
			return 0
		var v := int(b[p]) | (int(b[p + 1]) << 8)
		p += 2
		return v

	func u32() -> int:
		if not _need(4):
			return 0
		var v := int(b[p]) | (int(b[p + 1]) << 8) | (int(b[p + 2]) << 16) | (int(b[p + 3]) << 24)
		p += 4
		return v & 0xFFFFFFFF

	func bytes(n: int) -> PackedByteArray:
		if not _need(n):
			return PackedByteArray()
		var out := b.slice(p, p + n)
		p += n
		return out

	func remaining() -> int:
		return b.size() - p


# CRC32(IEEE 802.3,多项式 0xEDB88320)。表必须是 64 位:0xEDB88320 超 int32,存 int32 会符号扩展。
static var _crc_table: PackedInt64Array = PackedInt64Array()


static func crc32(data: PackedByteArray) -> int:
	if _crc_table.is_empty():
		_crc_table.resize(256)
		for i in 256:
			var c := i
			for k in 8:
				c = (c >> 1) ^ (0xEDB88320 if (c & 1) == 1 else 0)
			_crc_table[i] = c
	var crc := 0xFFFFFFFF
	for byte in data:
		crc = _crc_table[(crc ^ byte) & 0xFF] ^ (crc >> 8)
	return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF
