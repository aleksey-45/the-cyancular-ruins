#pragma once
#include "projectile_entry.h"
#include <vector>

namespace godot {
// Each history frame owns its values; network dictionaries and other frames cannot mutate them.
class NativeProjectileSnapshot : public RefCounted {
    GDCLASS(NativeProjectileSnapshot, RefCounted)
    struct Record { int64_t id; ProjectileMotionState motion; };
    std::vector<Record> records;
    const Record *find(int64_t id) const;
protected:
    static void _bind_methods();
public:
    static Ref<NativeProjectileSnapshot> capture(const Dictionary &entries, size_t capacity);
    size_t size() const { return records.size(); }
    bool matches(const Dictionary &states, int64_t role = 0) const;
    bool state_matches(int64_t id, const Dictionary &state) const;
    void insert_state(int64_t id, const Dictionary &state);
    bool can_restore(const Dictionary &entries, int64_t tick) const;
    void restore(const Dictionary &entries, int64_t tick) const;
};
void register_native_projectile_snapshot();
} // namespace godot
