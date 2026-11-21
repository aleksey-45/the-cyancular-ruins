#pragma once

#include <fast-lzma2.h>
#define XXH_PRIVATE_API
#include <xxhash.h>
#undef XXH_PRIVATE_API
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <cstring>

class CyrmStorage : public godot::RefCounted {
    GDCLASS(CyrmStorage, godot::RefCounted)
    static constexpr size_t HEADER = 13; // CYRM, version, uncompressed length, checksum of the stream.
    static constexpr size_t LIMIT = 64 * 1024 * 1024;
    inline static const int64_t MAX_FILE_BYTES = HEADER + FL2_compressBound(LIMIT);

protected:
    static void _bind_methods() {
        BIND_CONSTANT(MAX_FILE_BYTES);
        godot::ClassDB::bind_static_method("CyrmStorage", godot::D_METHOD("pack", "raw"), &CyrmStorage::pack);
        godot::ClassDB::bind_static_method("CyrmStorage", godot::D_METHOD("unpack", "file"), &CyrmStorage::unpack);
    }

public:
    static godot::PackedByteArray pack(const godot::PackedByteArray &raw) {
        const size_t length = raw.size();
        if (!length || length > LIMIT) return {};
        const size_t bound = FL2_compressBound(length);
        godot::PackedByteArray file;
        if (file.resize(HEADER + bound) != godot::OK) return {};
        auto *out = file.ptrw();
        const size_t written = FL2_compressMt(out + HEADER, bound, raw.ptr(), length, 3, 2);
        if (FL2_isError(written)) return {};
        const uint32_t checksum = XXH32(out + HEADER, written, 0);
        std::memcpy(out, "CYRM\x05", 5);
        file.encode_u32(5, length);
        file.encode_u32(9, checksum);
        file.resize(HEADER + written);
        return file;
    }

    static godot::PackedByteArray unpack(const godot::PackedByteArray &file) {
        if (file.size() <= int64_t(HEADER) || file.size() > MAX_FILE_BYTES) return {};
        if (std::memcmp(file.ptr(), "CYRM\x05", 5) != 0) return {};
        const size_t length = file.decode_u32(5);
        const auto *stream = file.ptr() + HEADER;
        const size_t size = file.size() - HEADER;
        if (!length || length > LIMIT || XXH32(stream, size, 0) != file.decode_u32(9)) return {};
        if (FL2_findDecompressedSize(stream, size) != length) return {};
        godot::PackedByteArray raw;
        if (raw.resize(length) != godot::OK || FL2_decompress(raw.ptrw(), length, stream, size) != length) return {};
        return raw;
    }
};
