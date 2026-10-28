#include "weapon_body.h"
#include "bullet_body.h"
#include <godot_cpp/classes/random_number_generator.hpp>
#include <godot_cpp/classes/scene_tree.hpp>
#include <godot_cpp/core/object.hpp>
#include <algorithm>
#include <cmath>

using namespace godot;

void NativeWeaponBody::_bind_methods() {
#define WEAPON_FIELD(type, name, initial, exported) \
    ClassDB::bind_method(D_METHOD("_native_set_" #name, "value"), &NativeWeaponBody::native_set_##name); \
    ClassDB::bind_method(D_METHOD("_native_get_" #name), &NativeWeaponBody::native_get_##name); \
    ADD_PROPERTY(PropertyInfo(GetTypeInfo<type>::VARIANT_TYPE, #name, PROPERTY_HINT_NONE, "", exported ? PROPERTY_USAGE_DEFAULT : PROPERTY_USAGE_NONE), "_native_set_" #name, "_native_get_" #name);
#include "weapon_fields.inc"
#undef WEAPON_FIELD
    ClassDB::bind_method(D_METHOD("set_player", "value"), &NativeWeaponBody::set_player);
    ClassDB::bind_method(D_METHOD("get_player"), &NativeWeaponBody::get_player);
    ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "player", PROPERTY_HINT_NODE_TYPE, "Node2D", PROPERTY_USAGE_NONE), "set_player", "get_player");
    ClassDB::bind_method(D_METHOD("native_bind_owner", "player", "authority"), &NativeWeaponBody::bind_owner);
    ClassDB::bind_method(D_METHOD("native_bind_muzzle", "muzzle"), &NativeWeaponBody::bind_muzzle);
    ClassDB::bind_method(D_METHOD("native_external_input", "held", "pressed", "released", "aim"), &NativeWeaponBody::external_input);
    ClassDB::bind_method(D_METHOD("native_initialize_magazine"), &NativeWeaponBody::initialize_magazine);
    ClassDB::bind_method(D_METHOD("native_reset_simulation", "mag", "full"), &NativeWeaponBody::reset_simulation_state);
    ClassDB::bind_method(D_METHOD("native_restore_driver_state", "state"), &NativeWeaponBody::restore_driver_state);
    ClassDB::bind_method(D_METHOD("native_tick_weapon", "delta"), &NativeWeaponBody::tick_weapon);
    ClassDB::bind_method(D_METHOD("native_try_fire"), &NativeWeaponBody::try_fire);
    ClassDB::bind_method(D_METHOD("native_fire"), &NativeWeaponBody::fire);
    ClassDB::bind_method(D_METHOD("native_start_reload"), &NativeWeaponBody::start_reload);
    ClassDB::bind_method(D_METHOD("cancel_aim"), &NativeWeaponBody::cancel_aim);
    ClassDB::bind_method(D_METHOD("is_previewing"), &NativeWeaponBody::is_previewing);
    ClassDB::bind_method(D_METHOD("is_reloading"), &NativeWeaponBody::is_reloading);
    ClassDB::bind_method(D_METHOD("reload_progress"), &NativeWeaponBody::reload_progress);
    ClassDB::bind_method(D_METHOD("get_movement_multiplier"), &NativeWeaponBody::get_movement_multiplier);
    ClassDB::bind_method(D_METHOD("native_clamped_aim"), &NativeWeaponBody::clamped_aim);
    ClassDB::bind_method(D_METHOD("_apply_aim_pose", "angle", "facing"), &NativeWeaponBody::apply_aim_pose);
    ClassDB::bind_method(D_METHOD("projectile_specs", "action"), &NativeWeaponBody::projectile_specs);
    ClassDB::bind_static_method("NativeWeaponBody", D_METHOD("native_clamp_pitch", "direction", "facing", "limit"), &NativeWeaponBody::clamp_pitch);
    ClassDB::bind_static_method("NativeWeaponBody", D_METHOD("native_aim_facing_hint", "direction"), &NativeWeaponBody::aim_facing_hint);
}
void NativeWeaponBody::set_player(Node2D *value) { player_id = value ? uint64_t(value->get_instance_id()) : 0; }
Node2D *NativeWeaponBody::get_player() const { return player_id ? Object::cast_to<Node2D>(ObjectDB::get_instance(player_id)) : nullptr; }
NativeActorBody *NativeWeaponBody::actor() const { return Object::cast_to<NativeActorBody>(get_player()); }
void NativeWeaponBody::bind_owner(Node2D *value, bool authority) { set_player(value); authority_owner = authority; }
void NativeWeaponBody::bind_muzzle(Node2D *value) { muzzle_id = value ? uint64_t(value->get_instance_id()) : 0; }
void NativeWeaponBody::external_input(bool held, bool pressed, bool released, Vector2 direction) {
    external_held = held; external_pressed = pressed; external_released = released; external_aim = direction;
}
void NativeWeaponBody::initialize_magazine() {
    mag_ammo = pending_mag == -2 ? mag_size : std::clamp(pending_mag, int64_t(0), mag_size);
    pending_mag = -2; _mag_ready = true;
}
void NativeWeaponBody::reset_simulation_state(int mag, int full) {
    mag_ammo = mag == full ? mag_size : std::clamp<int64_t>(mag, 0, mag_size);
    pending_mag = -2; _mag_ready = true; _reloading = false; _reload_t = 0;
    _aiming = false; _fire_buffered = false; _aim_facing = 1; _current_aim_facing = 1;
}
void NativeWeaponBody::sound(const String &value) {
    if (NativeActorBody *body = actor()) { Dictionary action; action["kind"] = "sound"; action["sound"] = value; body->step_actions.push_back(action); }
}
void NativeWeaponBody::start_reload() {
    if (!_mag_ready || _reloading || mag_ammo >= mag_size) return;
    _reloading = true; _reload_t = reload_time; sound("reload");
}
double NativeWeaponBody::reload_progress() const { return _reloading ? 1 - _reload_t / std::max(reload_time, .01) : -1; }
double NativeWeaponBody::clamp_pitch(Vector2 direction, int facing, double limit) {
    const Vector2 local(direction.x * facing, direction.y);
    return std::clamp(double(local.angle()), -limit * (Math_PI / 180.0), limit * (Math_PI / 180.0));
}
int NativeWeaponBody::aim_facing_hint(Vector2 direction) { return std::abs(double(direction.x)) > .1 ? (direction.x > 0 ? 1 : -1) : 0; }
Vector2 NativeWeaponBody::aim() const {
    const NativeActorBody *body = actor();
    if (!body) return external_aim;
    const Vector2 value = body->stepping ? body->get_step_input()->aim : external_aim;
    return value == Vector2() ? Vector2(body->facing_direction, 0) : value;
}
void NativeWeaponBody::apply_aim_pose(double angle, int facing) {
    if (get_rotation() != angle) set_rotation(real_t(angle));
    Vector2 size = get_scale();
    if (size.x != facing) { size.x = real_t(facing); set_scale(size); }
}
void NativeWeaponBody::auto_aim() {
    const Vector2 direction = aim();
    int facing = int(_aim_facing), hint = aim_facing_hint(direction);
    if (hint) {
        facing = hint; _aim_facing = facing;
        if (NativeActorBody *body = actor(); body && !body->is_charge) body->facing_direction = facing;
    }
    _current_aim_facing = facing;
    apply_aim_pose(clamp_pitch(direction, facing, pitch_clamp_deg) * facing, facing);
}
Vector2 NativeWeaponBody::clamped_aim() const {
    const double angle = clamp_pitch(aim(), int(_current_aim_facing), pitch_clamp_deg);
    const Vector2 local = Vector2::from_angle(real_t(angle));
    return Vector2(local.x * _current_aim_facing, local.y);
}
int NativeWeaponBody::live_projectiles() const {
    NativeActorBody *body = actor();
    if (!body) return 0;
    if (body->has_prediction_registry()) return body->count_prediction_projectiles(type_id);
    if (!is_inside_tree()) return 0;
    int count = 0;
    const TypedArray<Node> bullets = get_tree()->get_nodes_in_group("bullet");
    for (int i = 0; i < bullets.size(); ++i) {
        const NativeBulletBody *bullet = Object::cast_to<NativeBulletBody>(bullets[i]);
        if (!bullet) continue;
        if (authority_owner ? bullet->get_shooter() == body && bullet->type_id == type_id && !bullet->finished : bullet->get_source_node() == this) ++count;
    }
    return count;
}
void NativeWeaponBody::tick_weapon(double delta) {
    NativeActorBody *body = actor();
    if (!body || body->sim_downed) return;
    fire_cd_timer = std::max(fire_cd_timer - delta, 0.0);
    if (_reloading) {
        _reload_t -= delta;
        if (_reload_t <= 0) { _reloading = false; mag_ammo = mag_size; sound("switch"); }
    }
    auto_aim();
    if (_fire_buffered && fire_cd_timer == 0) { _fire_buffered = false; fire(); }
    const Ref<NativeActorInput> input = body->get_step_input();
    const bool held = body->stepping ? (input->held & 8) != 0 : external_held;
    const bool pressed = body->stepping ? (input->pressed & 8) != 0 : external_pressed;
    const bool released = body->stepping ? (input->released & 8) != 0 : external_released;
    if (heavy_aim) {
        if (pressed) _aiming = true;
        if (released) { _aiming = false; try_fire(); }
        if (!held && !pressed) _aiming = false;
    } else if (full_auto ? held || pressed : pressed) try_fire();
}
void NativeWeaponBody::try_fire() {
    if (fire_cd_timer > 0) {
        if (fire_cooldown > .5 && fire_cd_timer <= fire_cooldown * .2) _fire_buffered = true;
        return;
    }
    fire();
}
void NativeWeaponBody::fire() {
    NativeActorBody *body = actor();
    if (!body || body->sim_downed || _reloading) return;
    if (mag_ammo <= 0) { if (_mag_ready) start_reload(); return; }
    fire_cd_timer = fire_cooldown;
    if (max_live_projectiles > 0 && live_projectiles() >= max_live_projectiles) return;
    auto_aim();
    Node2D *muzzle = muzzle_id ? Object::cast_to<Node2D>(ObjectDB::get_instance(muzzle_id)) : nullptr;
    ERR_FAIL_NULL(muzzle);
    const Vector2 origin = body->native_shot_origin(muzzle);
    const int64_t serial = ++body->shot_serial;
    Dictionary action; action["kind"] = "fire"; action["dir"] = clamped_aim(); action["serial"] = serial;
    action["pos"] = origin; action["input_seq"] = body->input_seq; action["input_epoch"] = body->input_epoch;
    body->step_actions.push_back(action);
    mag_ammo = std::max<int64_t>(mag_ammo - 1, 0);
    if (!mag_ammo) start_reload();
    body->native_apply_recoil(recoil_push);
}
Vector2 NativeWeaponBody::get_movement_multiplier() const {
    const bool active = penalty_mode == 1 ? fire_cd_timer > 0 : (penalty_mode == 2 && (_aiming || fire_cd_timer > 0));
    return active ? Vector2(move_penalty, jump_penalty) : Vector2(1, 1);
}
Array NativeWeaponBody::projectile_specs(const Dictionary &action) const {
    const NativeActorBody *body = actor();
    ERR_FAIL_NULL_V(body, Array());
    Ref<RandomNumberGenerator> rng; rng.instantiate();
    const int64_t serial = action["serial"], role = body->role;
    rng->set_seed(Variant(String::num_int64(role) + ":" + String::num_int64(serial)).hash());
    const double spread = spread_deg * (Math_PI / 180.0);
    const Vector2 direction = action["dir"];
    Array result;
    for (int i = 0; i < pellet_count; ++i) {
        const double angle = double(direction.angle()) + rng->randf_range(-spread, spread);
        const Vector2 velocity = Vector2::from_angle(real_t(angle)) * bullet_speed * body->pvp_haste_mult;
        Dictionary spec; spec["id"] = (role << 48) | (serial << 8) | i; spec["type_id"] = type_id;
        spec["pos"] = action["pos"]; spec["vel"] = velocity; spec["traveled"] = 0.0;
        spec["fuse_active"] = false; spec["fuse_elapsed"] = 0.0; spec["fuse_duration"] = 0.0; spec["direct_hit"] = false;
        result.push_back(spec);
    }
    return result;
}
void NativeWeaponBody::append_prediction_state(Array &values) const {
    values.append_array(Array::make(fire_cd_timer, _aiming, _fire_buffered, _aim_facing,
        _current_aim_facing, mag_ammo, _reloading, _reload_t));
}
void NativeWeaponBody::write_driver_state(Dictionary &state) const {
    state["fire_cd"] = fire_cd_timer; state["aiming"] = _aiming; state["fire_buf"] = _fire_buffered;
    state["aim_f"] = _aim_facing; state["aim_cf"] = _current_aim_facing;
    state["mag"] = mag_ammo; state["rld"] = _reloading; state["rld_t"] = _reload_t;
}
void NativeWeaponBody::restore_driver_state(const Dictionary &state) {
    fire_cd_timer = state["fire_cd"]; _aiming = state["aiming"]; _fire_buffered = state["fire_buf"];
    _aim_facing = state["aim_f"]; _current_aim_facing = state["aim_cf"];
    const int64_t mag = std::clamp<int64_t>(state["mag"], 0, mag_size);
    if (is_inside_tree()) mag_ammo = mag;
    else pending_mag = mag;
    _reloading = state["rld"]; _reload_t = state["rld_t"];
}
void godot::register_native_weapon() { ClassDB::register_class<NativeWeaponBody>(); }
