#include "simulation.h"
#include "motion_track.h"
#include "weapon_body.h"
#include "bullet_body.h"
#include "projectile_entry.h"
#include <godot_cpp/core/object.hpp>
#include <godot_cpp/classes/shape2d.hpp>
#include <algorithm>
#include <cmath>
#include <cstring>

using namespace godot;

namespace {
enum InputBits { UP = 1, DOWN = 2, CHARGE = 4 };
enum Pose { STAND, MOVE, FLY, DASH, SQUAT };
double sign(double value) { return value > 0 ? 1 : (value < 0 ? -1 : 0); }
double approach(double current, double target, double rate, double delta) {
    return current + (target - current) * (1.0 - std::exp(-rate * delta));
}
double clip_bounds(Rect2 bounds, int axis, double distance, const std::vector<Rect2> &obstacles) {
    const int across = 1 - axis;
    const Vector2 start = bounds.position, end = bounds.get_end();
    const double center = bounds.get_center()[axis];
    for (const Rect2 &obstacle : obstacles) {
        const Vector2 other_start = obstacle.position, other_end = obstacle.get_end();
        const double overlap = std::min(double(end[across]), double(other_end[across])) -
            std::max(double(start[across]), double(other_start[across]));
        if (overlap <= 0) continue;
        if (distance > 0 && center < obstacle.get_center()[axis]) {
            const double gap = double(other_start[axis]) - double(end[axis]);
            if (gap > -overlap) distance = std::min(distance, std::max(gap, 0.0));
        } else if (distance < 0 && center > obstacle.get_center()[axis]) {
            const double gap = double(other_end[axis]) - double(start[axis]);
            if (gap < overlap) distance = std::max(distance, std::min(gap, 0.0));
        }
    }
    return distance;
}
}

NativeActorBody::NativeActorBody() { input.instantiate(); }

void NativeActorBody::_bind_methods() {
#define ACTOR_FIELD(type, name, initial) \
    ClassDB::bind_method(D_METHOD("_native_set_" #name, "value"), &NativeActorBody::native_set_##name); \
    ClassDB::bind_method(D_METHOD("_native_get_" #name), &NativeActorBody::native_get_##name); \
    ADD_PROPERTY(PropertyInfo(GetTypeInfo<type>::VARIANT_TYPE, #name, PROPERTY_HINT_NONE, "", PROPERTY_USAGE_NONE), "_native_set_" #name, "_native_get_" #name);
#include "actor_fields.inc"
#undef ACTOR_FIELD
#define BIND_ACCESS(name, info) \
    ClassDB::bind_method(D_METHOD("set_" #name, "value"), &NativeActorBody::set_##name); \
    ClassDB::bind_method(D_METHOD("get_" #name), &NativeActorBody::get_##name); \
    { PropertyInfo property = info; property.usage = PROPERTY_USAGE_NONE; ADD_PROPERTY(property, "set_" #name, "get_" #name); }
    BIND_ACCESS(step_input, PropertyInfo(Variant::OBJECT, "step_input", PROPERTY_HINT_RESOURCE_TYPE, "NativeActorInput"));
    BIND_ACCESS(hulls, PropertyInfo(Variant::ARRAY, "hulls", PROPERTY_HINT_ARRAY_TYPE, "CollisionShape2D"));
    BIND_ACCESS(actor_colliders, PropertyInfo(Variant::ARRAY, "actor_colliders"));
    BIND_ACCESS(actor_queries, PropertyInfo(Variant::ARRAY, "actor_queries"));
    BIND_ACCESS(step_actions, PropertyInfo(Variant::ARRAY, "step_actions"));
#undef BIND_ACCESS
    ClassDB::bind_method(D_METHOD("get_motion_contacts"), &NativeActorBody::get_motion_contacts);
    ADD_PROPERTY(PropertyInfo(Variant::ARRAY, "motion_contacts", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_NONE), "", "get_motion_contacts");
    ClassDB::bind_method(D_METHOD("get_terrain_motion_cache"), &NativeActorBody::get_terrain_motion_cache);
    ADD_PROPERTY(PropertyInfo(Variant::DICTIONARY, "terrain_motion_cache", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_NONE), "", "get_terrain_motion_cache");
    ClassDB::bind_method(D_METHOD("configure_motion", "values"), &NativeActorBody::configure_motion);
    ClassDB::bind_method(D_METHOD("native_step_actor", "delta", "time_mult", "pvp", "terrain"), &NativeActorBody::native_step_actor);
    ClassDB::bind_method(D_METHOD("set_simulation_weapon", "value"), &NativeActorBody::set_simulation_weapon);
    ClassDB::bind_method(D_METHOD("get_simulation_weapon"), &NativeActorBody::get_simulation_weapon);
    ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "simulation_weapon", PROPERTY_HINT_NODE_TYPE, "NativeWeaponBody", PROPERTY_USAGE_NONE), "set_simulation_weapon", "get_simulation_weapon");
    ClassDB::bind_method(D_METHOD("set_simulation_visuals", "value"), &NativeActorBody::set_simulation_visuals);
    ClassDB::bind_method(D_METHOD("get_simulation_visuals"), &NativeActorBody::get_simulation_visuals);
    ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "simulation_visuals", PROPERTY_HINT_NODE_TYPE, "Node2D", PROPERTY_USAGE_NONE), "set_simulation_visuals", "get_simulation_visuals");
    ClassDB::bind_method(D_METHOD("bind_prediction_projectiles", "entries"), &NativeActorBody::bind_prediction_projectiles);
    ClassDB::bind_method(D_METHOD("native_apply_recoil", "push"), &NativeActorBody::native_apply_recoil);
    ClassDB::bind_method(D_METHOD("native_apply_impulse", "source", "force"), &NativeActorBody::native_apply_impulse);
    ClassDB::bind_method(D_METHOD("native_simulate_hit", "source", "damage", "force"), &NativeActorBody::native_simulate_hit);
    ClassDB::bind_method(D_METHOD("native_force_down"), &NativeActorBody::native_force_down);
    ClassDB::bind_method(D_METHOD("native_queries_match", "queries"), &NativeActorBody::native_queries_match);
    ClassDB::bind_method(D_METHOD("apply_collision_pose"), &NativeActorBody::apply_collision_pose);
    ClassDB::bind_method(D_METHOD("collision_stance"), &NativeActorBody::collision_stance);
    ClassDB::bind_method(D_METHOD("collision_rect"), &NativeActorBody::collision_rect);
    ClassDB::bind_method(D_METHOD("set_crouched", "crouched"), &NativeActorBody::set_crouched);
    ClassDB::bind_method(D_METHOD("cancel_charge"), &NativeActorBody::cancel_charge);
    ClassDB::bind_method(D_METHOD("cancel_jump_state"), &NativeActorBody::cancel_jump_state);
    ClassDB::bind_method(D_METHOD("reset_motion"), &NativeActorBody::reset_motion);
    ClassDB::bind_method(D_METHOD("capture_motion_state"), &NativeActorBody::capture_motion_state);
    ClassDB::bind_method(D_METHOD("restore_motion_state", "state", "pose"), &NativeActorBody::restore_motion_state);
    ClassDB::bind_method(D_METHOD("native_apply_authoritative_state", "hp", "waterproof", "downed"), &NativeActorBody::native_apply_authoritative_state);
    ClassDB::bind_method(D_METHOD("capture_prediction_prefix", "weapon_instance", "inventory"), &NativeActorBody::capture_prediction_prefix);
    ClassDB::bind_method(D_METHOD("capture_state_native", "weapon_instance", "inventory"), &NativeActorBody::capture_state_native);
    ClassDB::bind_method(D_METHOD("write_driver_state_native", "state", "weapon_instance", "inventory"), &NativeActorBody::write_driver_state_native);
    ClassDB::bind_method(D_METHOD("restore_logic_state", "state"), &NativeActorBody::restore_logic_state);
}

void NativeActorBody::configure_motion(const Dictionary &values) {
#define ACTOR_FIELD(type, name, initial) if (values.has(#name)) name = static_cast<type>(values[#name]);
#include "actor_fields.inc"
#undef ACTOR_FIELD
}

bool NativeActorBody::MotionKey::operator==(const MotionKey &other) const {
    return transform == other.transform && hull == other.hull && travel == other.travel &&
        rect == other.rect && shape == other.shape && mask == other.mask && margin == other.margin;
}
uint64_t NativeActorBody::MotionKey::hash() const {
    uint64_t result = 1469598103934665603ULL;
    const auto add = [&result](double value) {
        // Equal signed zeroes must hash equally. Compare complete keys after hashing.
        if (value == 0) value = 0;
        uint64_t bits; std::memcpy(&bits, &value, sizeof(bits));
        result = (result ^ bits) * 1099511628211ULL;
    };
    for (int i = 0; i < 3; ++i) { add(transform[i].x); add(transform[i].y); add(hull[i].x); add(hull[i].y); }
    add(travel.x); add(travel.y); add(rect.position.x); add(rect.position.y); add(rect.size.x); add(rect.size.y);
    add(margin); result = (result ^ uint64_t(mask)) * 1099511628211ULL;
    return (result ^ shape.get_id()) * 1099511628211ULL;
}

std::vector<Rect2> NativeActorBody::obstacles(uint32_t mask, Vector2 anchor) const {
    std::vector<Rect2> result;
    result.reserve(colliders.size());
    for (int i = 0; i < colliders.size(); ++i) {
        NativeActorCollider *other = Object::cast_to<NativeActorCollider>(colliders[i]);
        if (other && other->get_source() && other->get_source() != this && (mask & other->get_collision_layer()))
            result.push_back(other->world_rect(anchor));
    }
    return result;
}
double NativeActorBody::query_motion(Rect2 bounds, int axis, double distance, const std::vector<Rect2> &values) {
    const double result = clip_bounds(bounds, axis, distance, values);
    if (track_actor_queries) actor_queries.push_back(Array::make(axis, bounds, distance, result, get_collision_mask(), get_global_position()));
    return result;
}
bool NativeActorBody::query_overlap(Rect2 bounds) {
    bool result = false;
    for (const Rect2 &obstacle : obstacles(get_collision_mask(), get_global_position())) {
        if (bounds.intersects(obstacle)) { result = true; break; }
    }
    if (track_actor_queries) actor_queries.push_back(Array::make(-1, bounds, 0.0, result, get_collision_mask(), get_global_position()));
    return result;
}
bool NativeActorBody::native_queries_match(const Array &queries) const {
    for (int i = 0; i < queries.size(); ++i) {
        const Array query = queries[i];
        const auto rects = obstacles(int(query[4]), query[5]);
        const Rect2 bounds = query[1];
        if (int(query[0]) == -1) {
            bool overlap = false;
            for (const Rect2 &other : rects) if (bounds.intersects(other)) { overlap = true; break; }
            if (overlap != bool(query[3])) return false;
        } else if (clip_bounds(bounds, int(query[0]), double(query[2]), rects) != double(query[3])) return false;
    }
    return true;
}

Ref<KinematicCollision2D> NativeActorBody::terrain_motion(Vector2 travel, Transform2D hull, RID shape, Rect2 rect) {
    if (!cache_terrain_motion) return move_and_collide(travel, false, get_safe_margin());
    if (terrain_motion_revision != geometry_revision || (cache_markers.is_empty() && !cache_index.empty())) {
        cache_index.clear(); cache_markers.clear(); cache_next = 0;
        // Release collision references as well as the key index.
        for (auto &entry : motion_cache) entry.contact.unref();
        terrain_motion_revision = geometry_revision;
    }
    MotionKey key{get_global_transform(), hull, travel, rect, shape, get_collision_mask(), get_safe_margin()};
    const uint64_t hash = key.hash();
    const auto found = cache_index.find(hash);
    if (found != cache_index.end() && motion_cache[found->second].key == key) {
        const auto &entry = motion_cache[found->second];
        set_global_transform(entry.destination);
        return entry.contact;
    }
    const Ref<KinematicCollision2D> hit = move_and_collide(travel, false, get_safe_margin());
    size_t index;
    if (found != cache_index.end()) index = found->second;
    else {
        index = cache_next;
        if (cache_index.size() == motion_cache.size()) {
            cache_index.erase(motion_cache[index].hash);
            cache_markers.erase(int64_t(motion_cache[index].hash));
        }
        cache_next = (cache_next + 1) % motion_cache.size();
        cache_index[hash] = index;
    }
    motion_cache[index] = CacheEntry{key, get_global_transform(), hit, hash};
    cache_markers[int64_t(hash)] = true;
    return hit;
}

Vector2 NativeActorBody::move_by_internal(Vector2 motion) {
    ERR_FAIL_COND_V(hulls.size() < 2, Vector2());
    const auto rects = obstacles(get_collision_mask(), get_global_position());
    CollisionShape2D *hull = Object::cast_to<CollisionShape2D>(hulls[collision_stance()]);
    const Transform2D local = hull->get_transform();
    const Ref<Shape2D> shape = hull->get_shape();
    const Rect2 shape_rect = shape->get_rect();
    const RID shape_rid = cache_terrain_motion ? shape->get_rid() : RID();
    Vector2 blocked;
    for (int axis = 0; axis < 2; ++axis) {
        const double distance = motion[axis];
        if (distance == 0) continue;
        const Rect2 bounds = (get_global_transform() * local).xform(shape_rect);
        const double clipped = query_motion(bounds, axis, distance, rects);
        Vector2 travel; travel[axis] = real_t(clipped);
        if (track_motion_bounds) {
            Rect2 destination = bounds; destination.position += travel;
            motion_bounds = motion_bounds.merge(bounds.merge(destination).grow(get_safe_margin() + 1.0));
        }
        const Ref<KinematicCollision2D> hit = terrain_motion(travel, local, shape_rid, shape_rect);
        if (hit.is_valid()) motion_contacts.push_back(hit);
        const bool shortened = hit.is_valid() && std::abs(double(hit->get_travel()[axis])) + .001 < std::abs(clipped);
        if (clipped != distance || shortened || (hit.is_valid() && double(hit->get_normal()[axis]) * distance < 0))
            blocked[axis] = real_t(sign(distance));
    }
    return blocked;
}
void NativeActorBody::move_actor(double delta) {
    Vector2 motion = (native_velocity + motion_knock_velocity) * delta;
    if (_grounded && motion.y >= 0) motion.y = real_t(std::max(double(motion.y), double(get_floor_snap_length())));
    const Vector2 blocked = move_by_internal(motion);
    _grounded = blocked.y > 0;
    if (blocked.x != 0) { native_velocity.x = 0; motion_knock_velocity.x = 0; cancel_charge(); }
    if (blocked.y != 0) { native_velocity.y = 0; motion_knock_velocity.y = 0; }
    motion_knock_velocity *= std::exp(-knock_decay_rate * delta);
}
void NativeActorBody::brake(double delta) {
    native_velocity.x = real_t(approach(native_velocity.x, 0, _grounded ? brake_ground : brake_air, delta));
    if (std::abs(double(native_velocity.x)) < stop_snap) native_velocity.x = 0;
}
void NativeActorBody::wrap() {
    if (geometry.is_null()) return;
    const Vector2 at = get_global_position(), wrapped = simulation_wrap(at, geometry->size());
    if (at != wrapped) set_global_position(wrapped);
}

void NativeActorBody::apply_collision_pose() {
    ++collision_revision;
    const int stance = collision_stance();
    if (_collision_stance == stance || hulls.size() < 2) return;
    _collision_stance = stance;
    for (int i = 0; i < hulls.size(); ++i) Object::cast_to<CollisionShape2D>(hulls[i])->set_disabled(i != stance);
}
Rect2 NativeActorBody::collision_rect() const {
    if (hulls.size() < 2) return Rect2(get_global_position(), Vector2());
    const CollisionShape2D *hull = Object::cast_to<CollisionShape2D>(hulls[collision_stance()]);
    return (get_global_transform() * hull->get_transform()).xform(hull->get_shape()->get_rect());
}
void NativeActorBody::set_crouched(bool crouched) {
    if (crouched == is_squat) return;
    is_squat = crouched;
    apply_collision_pose();
    if (crouched) return;
    bool blocked = test_move(get_global_transform(), Vector2(), Ref<KinematicCollision2D>(), 0, true);
    if (query_overlap(collision_rect())) blocked = true;
    if (blocked) { is_squat = true; apply_collision_pose(); }
}
void NativeActorBody::reset_motion() {
    set_velocity(Vector2()); _grounded = false; state = STAND; state_lock_timer = 0;
    is_squat = false; cancel_jump_state(); cancel_charge(); _last_move_dir = 0; _last_move_timer = 0;
    climb_latched = false; in_water = false; motion_knock_velocity = Vector2(); apply_collision_pose();
}

void NativeActorBody::update_swim(double delta, Vector2 mult) {
    const Vector2 position = get_global_position();
    const Vector2 feet(position.x, real_t(std::max(double(position.y) + swim_foot_min, double(collision_rect().get_end().y))));
    in_water = !geometry->empty() && geometry->water(feet);
    if (!in_water) return;
    const double tm = speed_mult > 0 ? speed_mult : 1;
    const double target = input->axis * swim_speed * double(mult.x) * tm;
    native_velocity.x = real_t(approach(native_velocity.x, target, swim_accel, delta));
    native_velocity.y = real_t(((input->held & UP) ? swim_up : swim_down) * tm);
}
bool NativeActorBody::over_climb_tile() const {
    if (geometry->empty()) return false;
    const Vector2 position = get_global_position();
    return geometry->climb_speed(NativeTerrain::texture(geometry->value(geometry->cell(position + Vector2(0, climb_foot_offset))))) > 0 ||
        geometry->climb_speed(NativeTerrain::texture(geometry->value(geometry->cell(position)))) > 0;
}
bool NativeActorBody::ladder_top(Vector2i foot) const {
    const int below = geometry->value(foot + Vector2i(0, 1));
    return below != 0 && geometry->climb_speed(NativeTerrain::texture(below)) > 0;
}
void NativeActorBody::update_climb(double, Vector2 mult) {
    if (!climb_latched && !(input->pressed & UP)) return;
    if (geometry->empty() || is_squat) { climb_latched = false; return; }
    const Vector2 position = get_global_position();
    const Vector2i foot = geometry->cell(position + Vector2(0, climb_foot_offset));
    const int fv = geometry->value(foot), cv = geometry->value(geometry->cell(position));
    const int ft = NativeTerrain::texture(fv);
    const double fs = geometry->climb_speed(ft), cs = geometry->climb_speed(NativeTerrain::texture(cv));
    const bool foot_channel = fv != 0 && fs > 0, center_channel = cv != 0 && cs > 0;
    if (!climb_latched && (center_channel || foot_channel) && (input->pressed & UP)) climb_latched = true;
    if (climb_latched && !center_channel && !foot_channel && !ladder_top(foot)) climb_latched = false;
    if (!climb_latched) return;
    const double tm = speed_mult > 0 ? speed_mult : 1;
    if (input->vertical_axis < 0) {
        if (foot_channel || !ladder_top(foot)) {
            const double speed = climb_speed * std::max(fs, cs) * climb_vertical_mult * double(mult.y) * tm;
            native_velocity.y = real_t(input->vertical_axis * speed); return;
        }
        if (input->pressed & UP) {
            climb_latched = false;
            native_velocity.y = real_t(jump_velocity * double(mult.y));
            cancel_jump_state(); return;
        }
        native_velocity.y = 0; return;
    }
    if (input->vertical_axis > 0) {
        const double descent = geometry->descent_speed(ft);
        if (descent <= 0) { climb_latched = false; return; }
        native_velocity.y = real_t(input->vertical_axis * climb_speed * descent * climb_vertical_mult * double(mult.y) * tm);
        return;
    }
    native_velocity.y = 0;
}
void NativeActorBody::update_waterproof(double delta, bool pvp) {
    bool submerged = false;
    if (in_water) {
        const Vector2 breath = get_global_position() + Vector2(0, breath_line_offset);
        submerged = breath.y > geometry->water_surface(get_global_position());
    }
    if (submerged != _was_submerged) { _was_submerged = submerged; _waterproof_timer = 0; }
    _waterproof_timer += delta;
    if (_waterproof_timer >= (submerged ? water_drain_interval : water_recover_interval)) {
        _waterproof_timer = 0;
        waterproof = submerged ? std::max<int64_t>(waterproof - 1, 0) : std::min(waterproof + 1, max_waterproof);
    }
    if (waterproof <= 0) {
        _waterproof_drown_timer += delta;
        if (_waterproof_drown_timer >= water_drown_damage_interval) {
            _waterproof_drown_timer = 0;
            if (!pvp) { Dictionary action; action["kind"] = "hit"; action["pos"] = get_global_position(); action["damage"] = water_damage; step_actions.push_back(action); }
        }
    }
}
void NativeActorBody::impulse(int kind) {
    Dictionary action; action["kind"] = "impulse"; action["value"] = kind; step_actions.push_back(action);
}
void NativeActorBody::update_vertical(double delta, bool latched, Vector2 mult) {
    if (latched || in_water) return;
    if (_grounded) coyote_timer = coyote_time;
    else {
        const double grav_mult = is_charge ? charge_air_gravity_mult : 1;
        native_velocity.y = real_t(double(native_velocity.y) + gravity * grav_mult * delta);
        coyote_timer = std::max(coyote_timer - delta, 0.0);
    }
    if (input->pressed & UP) jump_buffer_timer = jump_buffer_time;
    else jump_buffer_timer = std::max(jump_buffer_timer - delta, 0.0);
    if (jump_buffer_timer > 0 && (_grounded || coyote_timer > 0) && !is_squat) {
        if (is_charge) cancel_charge();
        native_velocity.y = real_t(jump_velocity * double(mult.y));
        jump_buffer_timer = 0; coyote_timer = 0; jump_cut_applied = false; impulse(jump_impulse);
    }
    if (!jump_cut_applied && (input->released & UP) && native_velocity.y < 0) {
        native_velocity.y = real_t(double(native_velocity.y) * jump_cut_factor); jump_cut_applied = true;
    }
}
void NativeActorBody::update_crouch_dash() {
    if (climb_latched || in_water) return;
    if (!_grounded && (input->pressed & DOWN) && !over_climb_tile()) native_velocity.y = real_t(charge_down_velocity);
    const bool want_squat = _grounded && (input->held & DOWN);
    if (want_squat && !is_squat) is_charge = false;
    set_crouched(want_squat);
    if (!is_charge && !is_squat && (input->pressed & CHARGE)) {
        is_charge = true; charge_timer = charge_duration; impulse(dash_impulse);
        if (_last_move_timer > 0) facing_direction = _last_move_dir;
    }
}
void NativeActorBody::update_horizontal(double delta, Vector2 mult) {
    if (in_water) return;
    if (is_charge) {
        native_velocity.x = real_t(charge_velocity * facing_direction);
        charge_timer -= delta; if (charge_timer <= 0) is_charge = false;
    } else {
        const double speed = (is_squat ? crouch_walk_speed : move_speed) * speed_mult;
        const double target = input->axis * speed * double(mult.x);
        if (input->axis != 0) native_velocity.x = real_t(approach(native_velocity.x, target, _grounded ? accel_ground : accel_air, delta));
        else brake(delta);
    }
}
void NativeActorBody::update_facing(double delta) {
    if (!is_charge && input->axis != 0) {
        facing_direction = input->axis > 0 ? 1 : -1; _last_move_dir = facing_direction; _last_move_timer = charge_dir_window;
    } else _last_move_timer = std::max(_last_move_timer - delta, 0.0);
}
void NativeActorBody::update_pose(double delta) {
    int desired = STAND;
    if (in_water) desired = std::abs(double(native_velocity.x)) > 1 ? MOVE : STAND;
    else if (is_charge) desired = DASH;
    else if (is_squat) desired = SQUAT;
    else if (!_grounded) desired = FLY;
    else if (native_velocity.x != 0) desired = MOVE;
    if (state_lock_timer > 0) state_lock_timer -= delta;
    else if (state != desired) { state = desired; state_lock_timer = state_lock_time; }
    apply_collision_pose();
}
void NativeActorBody::slide_reactions(Vector2 incoming) {
    if (is_charge) {
        for (int i = 0; i < motion_contacts.size(); ++i) {
            const Ref<KinematicCollision2D> contact = motion_contacts[i];
            if (contact.is_valid() && std::abs(double(contact->get_normal().x)) > .5) {
                cancel_charge(); native_velocity.x = 0; break;
            }
        }
    }
    for (int i = 0; i < motion_contacts.size(); ++i) {
        const Ref<KinematicCollision2D> contact = motion_contacts[i];
        const Vector2 normal = contact->get_normal();
        const CollisionObject2D *terrain = Object::cast_to<CollisionObject2D>(contact->get_collider());
        if (!terrain || !(terrain->get_collision_layer() & 1) || incoming.dot(normal) >= 0) continue;
        const Vector2 point = simulation_wrap(contact->get_position() - normal, geometry->size());
        if (geometry->elastic_alive(point)) {
            native_velocity = native_velocity.slide(normal) + normal * elastic_bounce; break;
        }
    }
}
void NativeActorBody::native_simulate_motion(double delta, Vector2 mult, double time_mult, bool motion_only,
        bool pvp, const Ref<NativeTerrain> &world) {
    if (rewinding) return;
    ERR_FAIL_COND(world.is_null() || input.is_null());
    world->flush_collisions();
    if (geometry != world) terrain_motion_revision = -1;
    geometry = world;
    if (!world->empty()) map_dimensions = world->size();
    geometry_revision = world->get_geometry_revision(); speed_mult = time_mult;
    force_update_transform(); motion_contacts.clear(); native_velocity = get_velocity();
    if (sim_downed) {
        _pre_move_vy = 0;
        if (_grounded) coyote_timer = coyote_time;
        else native_velocity.y = real_t(double(native_velocity.y) + gravity * delta);
        brake(delta); move_actor(delta); wrap(); set_velocity(native_velocity); return;
    }
    update_swim(delta, mult);
    if (!motion_only) update_waterproof(delta, pvp);
    if (!in_water) update_climb(delta, mult);
    else { is_charge = false; is_squat = false; }
    const bool latched = !in_water && climb_latched;
    update_vertical(delta, latched, mult);
    update_crouch_dash(); update_horizontal(delta, mult); update_facing(delta); update_pose(delta);
    _pre_move_vy = in_water || latched ? 0 : native_velocity.y;
    const Vector2 incoming = native_velocity + motion_knock_velocity;
    move_actor(delta); slide_reactions(incoming); wrap(); set_velocity(native_velocity);
}

void NativeActorBody::set_simulation_weapon(Node2D *value) { weapon_id = value ? uint64_t(value->get_instance_id()) : 0; }
Node2D *NativeActorBody::get_simulation_weapon() const { return weapon_id ? Object::cast_to<Node2D>(ObjectDB::get_instance(weapon_id)) : nullptr; }
NativeWeaponBody *NativeActorBody::active_weapon() const { return Object::cast_to<NativeWeaponBody>(get_simulation_weapon()); }
void NativeActorBody::set_simulation_visuals(Node2D *value) { visual_root_id = value ? uint64_t(value->get_instance_id()) : 0; }
Node2D *NativeActorBody::get_simulation_visuals() const { return visual_root_id ? Object::cast_to<Node2D>(ObjectDB::get_instance(visual_root_id)) : nullptr; }
Vector2 NativeActorBody::native_shot_origin(Node2D *muzzle) const {
    const Node2D *visual = get_simulation_visuals();
    return visual ? muzzle->get_global_position() - (visual->get_global_position() - get_global_position()) : muzzle->get_global_position();
}
void NativeActorBody::bind_prediction_projectiles(const Dictionary &entries) { prediction_projectiles = entries; prediction_registry_bound = true; }
int NativeActorBody::count_prediction_projectiles(int64_t type) const {
    int count = 0;
    const Array ids = prediction_projectiles.keys();
    for (int i = 0; i < ids.size(); ++i) {
        const int64_t id = ids[i];
        const NativeProjectileEntry *entry = Object::cast_to<NativeProjectileEntry>(prediction_projectiles[id]);
        const NativeBulletBody *bullet = entry ? entry->get_bullet() : nullptr;
        if (bullet && id >> 48 == role && bullet->type_id == type && entry->active && entry->tick < combat_tick && !bullet->finished) ++count;
    }
    return count;
}
void NativeActorBody::native_apply_recoil(double push) {
    if (is_squat) return;
    if (climb_latched) push *= climb_recoil_mult;
    Vector2 velocity = get_velocity();
    velocity.x = real_t(double(velocity.x) - facing_direction * push);
    set_velocity(velocity);
}
void NativeActorBody::native_apply_impulse(Vector2 source, double force) {
    const Vector2 position = get_global_position();
    Vector2 away = (position - source).normalized();
    if (map_dimensions.x > 0 && map_dimensions.y > 0) {
        Vector2 distance;
        for (int axis = 0; axis < 2; ++axis) {
            double value = double(position[axis]) - double(source[axis]);
            if (std::abs(value) > double(map_dimensions[axis]) * .5) value = -(value > 0 ? 1 : -1) * (double(map_dimensions[axis]) - std::abs(value));
            distance[axis] = real_t(value);
        }
        if (!distance.is_zero_approx()) away = distance.normalized();
    }
    if (away == Vector2()) away = Vector2(-double(facing_direction), 0);
    if (force < 0) set_velocity(Vector2(double(away.x) * hit_knockback, double(away.y) * hit_knockback - hit_knockback_up));
    else motion_knock_velocity = away * force;
}
bool NativeActorBody::native_force_down() {
    if (sim_downed) return false;
    sim_downed = true; set_rotation(real_t(-Math_PI / 2.0 * facing_direction)); _grounded = false;
    apply_collision_pose();
    if (NativeWeaponBody *weapon = active_weapon()) weapon->cancel_aim();
    return true;
}
bool NativeActorBody::native_simulate_hit(Vector2 source, int damage, double force) {
    cancel_charge(); sim_hp -= damage; sim_iframes = hit_iframes; native_apply_impulse(source, force);
    return sim_hp <= 0 && native_force_down();
}
void NativeActorBody::native_step_actor(double delta, double time_mult, bool pvp,
        const Ref<NativeTerrain> &world) {
    if (rewinding) return;
    NativeWeaponBody *weapon = active_weapon();
    if (!sim_downed) {
        sim_iframes = std::max(sim_iframes - delta, 0.0);
        if (weapon) {
            if (input.is_valid() && (input->pressed & 16)) weapon->start_reload();
            weapon->tick_weapon(delta * time_mult);
        }
    }
    native_simulate_motion(delta, weapon && !sim_downed ? weapon->get_movement_multiplier() : Vector2(1, 1), time_mult, false, pvp, world);
}

Dictionary NativeActorBody::capture_motion_state() const {
    return ActorMotionState::capture(*this).to_dictionary();
}
void NativeActorBody::restore_motion_state(const Dictionary &st, int pose) {
    ActorMotionState::from_dictionary(st, pose).restore(*this);
}
void NativeActorBody::native_apply_authoritative_state(int hp, int wp, bool down) {
    sim_hp = hp; waterproof = wp; sim_downed = down;
    set_rotation(down ? -Math_PI / 2.0 * facing_direction : 0.0);
    apply_collision_pose();
}
Array NativeActorBody::capture_prediction_prefix(int64_t instance, const Array &inventory) const {
    return Array::make(get_global_position(), _grounded, pvp_haste_mult, get_velocity(), facing_direction,
        state_lock_timer, coyote_timer, jump_buffer_timer, jump_cut_applied, is_squat, is_charge,
        charge_timer, _last_move_dir, _last_move_timer, climb_latched, in_water, motion_knock_velocity,
        shot_serial, _waterproof_timer, _was_submerged, _waterproof_drown_timer, sim_iframes,
        _controls_locked, instance, inventory, state, waterproof, sim_hp, sim_downed);
}
Array NativeActorBody::capture_prediction_state_native(int64_t instance, const Array &inventory) const {
    Array values = capture_prediction_prefix(instance, inventory);
    if (const NativeWeaponBody *weapon = active_weapon()) weapon->append_prediction_state(values);
    return values;
}
void NativeActorBody::write_driver_state_native(Dictionary st, int64_t instance, const Array &inventory) const {
    st["shot_serial"] = shot_serial; st["wp_t"] = _waterproof_timer; st["wp_s"] = _was_submerged;
    st["wp_d"] = _waterproof_drown_timer; st["ifr"] = sim_iframes; st["locked"] = _controls_locked;
    st["winst"] = instance; st["inv"] = inventory;
    if (const NativeWeaponBody *weapon = active_weapon()) weapon->write_driver_state(st);
}
Dictionary NativeActorBody::capture_state_native(int64_t instance, const Array &inventory) const {
    Dictionary st = capture_motion_state(); write_driver_state_native(st, instance, inventory);
    st["state"] = state; st["wp"] = waterproof; st["hp"] = sim_hp; st["down"] = sim_downed;
    return st;
}
void NativeActorBody::restore_logic_state(const Dictionary &st) {
    restore_motion_state(st, st["state"]);
    _controls_locked = st["locked"];
    shot_serial = st["shot_serial"];
    native_apply_authoritative_state(st["hp"], st["wp"], st["down"]);
    sim_iframes = st["ifr"]; _waterproof_timer = st["wp_t"];
    _was_submerged = st["wp_s"]; _waterproof_drown_timer = st["wp_d"];
}
