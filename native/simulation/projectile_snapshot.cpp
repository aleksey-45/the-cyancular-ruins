#include "projectile_snapshot.h"
#include <algorithm>

using namespace godot;
void NativeProjectileSnapshot::_bind_methods() {
    ClassDB::bind_method(D_METHOD("matches", "states", "role"), &NativeProjectileSnapshot::matches, DEFVAL(0));
    ClassDB::bind_method(D_METHOD("state_matches", "id", "state"), &NativeProjectileSnapshot::state_matches);
    ClassDB::bind_method(D_METHOD("insert_state", "id", "state"), &NativeProjectileSnapshot::insert_state);
    ClassDB::bind_method(D_METHOD("can_restore", "entries", "tick"), &NativeProjectileSnapshot::can_restore);
    ClassDB::bind_method(D_METHOD("restore", "entries", "tick"), &NativeProjectileSnapshot::restore);
}
const NativeProjectileSnapshot::Record *NativeProjectileSnapshot::find(int64_t id) const {
    const auto at = std::lower_bound(records.begin(), records.end(), id,
        [](const Record &record, int64_t value) { return record.id < value; });
    return at != records.end() && at->id == id ? &*at : nullptr;
}
Ref<NativeProjectileSnapshot> NativeProjectileSnapshot::capture(const Dictionary &entries, size_t capacity) {
    Ref<NativeProjectileSnapshot> saved;
    saved.instantiate();
    saved->records.reserve(std::min(capacity, size_t(entries.size())));
    const Array ids = entries.keys();
    for (int i = 0; i < ids.size(); ++i) {
        const Ref<NativeProjectileEntry> entry = entries[ids[i]];
        if (entry.is_null() || !entry->active) continue;
        const NativeBulletBody *bullet = entry->get_bullet();
        if (bullet && !bullet->finished) saved->records.push_back({ids[i], bullet->capture_motion()});
    }
    std::sort(saved->records.begin(), saved->records.end(), [](const Record &a, const Record &b) { return a.id < b.id; });
    return saved;
}
bool NativeProjectileSnapshot::matches(const Dictionary &states, int64_t role) const {
    int count = 0;
    for (const Record &record : records) {
        if (role && record.id >> 48 != role) continue;
        if (!states.has(record.id) || !record.motion.matches(states[record.id])) return false;
        ++count;
    }
    return count == states.size();
}
bool NativeProjectileSnapshot::state_matches(int64_t id, const Dictionary &state) const {
    const Record *record = find(id);
    return record && record->motion.matches(state);
}
void NativeProjectileSnapshot::insert_state(int64_t id, const Dictionary &state) {
    auto at = std::lower_bound(records.begin(), records.end(), id,
        [](const Record &record, int64_t value) { return record.id < value; });
    const ProjectileMotionState motion = ProjectileMotionState::from_dictionary(state);
    if (at != records.end() && at->id == id) at->motion = motion;
    else records.insert(at, {id, motion});
}
bool NativeProjectileSnapshot::can_restore(const Dictionary &entries, int64_t tick) const {
    for (const Record &record : records) {
        if (!entries.has(record.id)) return false;
        const Ref<NativeProjectileEntry> entry = entries[record.id];
        const NativeBulletBody *bullet = entry.is_valid() ? entry->get_bullet() : nullptr;
        if (!bullet || bullet->type_id != record.motion.type || (entry->confirmed && entry->birth_tick > tick)) return false;
    }
    return true;
}
void NativeProjectileSnapshot::restore(const Dictionary &entries, int64_t tick) const {
    const Array ids = entries.keys();
    for (int i = 0; i < ids.size(); ++i) {
        const Ref<NativeProjectileEntry> entry = entries[ids[i]];
        const Record *record = find(ids[i]);
        if (record) entry->restore_at(record->motion, tick);
        else {
            entry->active = false;
            if (NativeBulletBody *bullet = entry->get_bullet()) bullet->finished = true;
        }
    }
}
void godot::register_native_projectile_snapshot() { ClassDB::register_class<NativeProjectileSnapshot>(); }
