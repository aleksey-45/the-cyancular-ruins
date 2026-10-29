#pragma once
#include "bullet_body.h"

namespace godot {
// Scene nodes remain scene-owned. The hot lifecycle record uses typed members;
// protocol anchors/checkpoints retain Dictionaries only at the input boundary.
class NativeProjectileEntry : public RefCounted {
    GDCLASS(NativeProjectileEntry, RefCounted)
    uint64_t bullet_id = 0;
protected:
    static void _bind_methods();
public:
    int64_t origin_tick = 0, birth_tick = 0, tick = 0, sim_tick = 0, moved_tick = -1, retired_tick = -1;
    bool confirmed = false, active = false;
    Dictionary origin_state, checkpoints;
    void set_bullet(NativeBulletBody *value);
    NativeBulletBody *get_bullet() const;
    void initialize(NativeBulletBody *body, const Dictionary &initial, int64_t at, bool known);
    void reset_at(const Dictionary &initial, int64_t at);
    void restore_at(const ProjectileMotionState &initial, int64_t at);
#define ENTRY_ACCESS(type, name) \
    void native_set_##name(type value) { name = value; } \
    type native_get_##name() const { return name; }
    ENTRY_ACCESS(int64_t, origin_tick)
    ENTRY_ACCESS(int64_t, birth_tick)
    ENTRY_ACCESS(int64_t, tick)
    ENTRY_ACCESS(int64_t, sim_tick)
    ENTRY_ACCESS(int64_t, moved_tick)
    ENTRY_ACCESS(int64_t, retired_tick)
    ENTRY_ACCESS(bool, confirmed)
    ENTRY_ACCESS(bool, active)
    ENTRY_ACCESS(Dictionary, origin_state)
    ENTRY_ACCESS(Dictionary, checkpoints)
#undef ENTRY_ACCESS
};
void register_native_projectile_entry();
} // namespace godot
