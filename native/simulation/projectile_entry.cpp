#include "projectile_entry.h"
#include <godot_cpp/core/object.hpp>

using namespace godot;
void NativeProjectileEntry::_bind_methods() {
#define ENTRY_ACCESS(type, name) \
    ClassDB::bind_method(D_METHOD("_native_set_" #name, "value"), &NativeProjectileEntry::native_set_##name); \
    ClassDB::bind_method(D_METHOD("_native_get_" #name), &NativeProjectileEntry::native_get_##name); \
    ADD_PROPERTY(PropertyInfo(GetTypeInfo<type>::VARIANT_TYPE, #name, PROPERTY_HINT_NONE, "", PROPERTY_USAGE_NONE), "_native_set_" #name, "_native_get_" #name);
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
    ClassDB::bind_method(D_METHOD("set_bullet", "value"), &NativeProjectileEntry::set_bullet);
    ClassDB::bind_method(D_METHOD("get_bullet"), &NativeProjectileEntry::get_bullet);
    ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "bullet", PROPERTY_HINT_NODE_TYPE, "NativeBulletBody", PROPERTY_USAGE_NONE), "set_bullet", "get_bullet");
    ClassDB::bind_method(D_METHOD("initialize", "bullet", "state", "tick", "confirmed"), &NativeProjectileEntry::initialize);
    ClassDB::bind_method(D_METHOD("reset_at", "state", "tick"), &NativeProjectileEntry::reset_at);
}
void NativeProjectileEntry::set_bullet(NativeBulletBody *value) { bullet_id = value ? uint64_t(value->get_instance_id()) : 0; }
NativeBulletBody *NativeProjectileEntry::get_bullet() const { return bullet_id ? Object::cast_to<NativeBulletBody>(ObjectDB::get_instance(bullet_id)) : nullptr; }
void NativeProjectileEntry::initialize(NativeBulletBody *body, const Dictionary &initial, int64_t at, bool known) {
    set_bullet(body); origin_state = initial.duplicate(); checkpoints = Dictionary();
    origin_tick = at; birth_tick = at + 1; tick = at; sim_tick = at; moved_tick = -1; retired_tick = -1;
    confirmed = known; active = !known;
    if (known) checkpoints[at] = initial.duplicate();
}
void NativeProjectileEntry::reset_at(const Dictionary &initial, int64_t at) {
    restore_at(ProjectileMotionState::from_dictionary(initial), at);
}
void NativeProjectileEntry::restore_at(const ProjectileMotionState &initial, int64_t at) {
    if (NativeBulletBody *body = get_bullet()) body->restore_motion_state(initial);
    tick = at; sim_tick = at; moved_tick = -1; active = true; retired_tick = -1;
}
void godot::register_native_projectile_entry() { ClassDB::register_class<NativeProjectileEntry>(); }
