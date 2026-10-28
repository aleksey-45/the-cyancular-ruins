#include "bullet_body.h"
#include <godot_cpp/core/object.hpp>
#include <godot_cpp/classes/geometry2d.hpp>
#include <cmath>
#include <limits>

using namespace godot;

void NativeBulletBody::_bind_methods() {
    const auto field_usage = [](const StringName &name) {
        return name == StringName("explodes") || name == StringName("direct_hit_damage") ||
            name == StringName("fuse_time") || name == StringName("hit_fuse_time") ||
            name == StringName("explosion_radius") || name == StringName("explosion_damage") ||
            name == StringName("explosion_knockback") ? PROPERTY_USAGE_DEFAULT : PROPERTY_USAGE_NONE;
    };
    ClassDB::bind_integer_constant("NativeBulletBody", "AdvanceResult", "MOVED", MOVED);
    ClassDB::bind_integer_constant("NativeBulletBody", "AdvanceResult", "BOUNCED", BOUNCED);
    ClassDB::bind_integer_constant("NativeBulletBody", "AdvanceResult", "TERRAIN_HIT", TERRAIN_HIT);
    ClassDB::bind_integer_constant("NativeBulletBody", "AdvanceResult", "RANGE_END", RANGE_END);
    ClassDB::bind_integer_constant("NativeBulletBody", "AdvanceResult", "FUSE_END", FUSE_END);
#define BULLET_FIELD(type, name, initial) \
    ClassDB::bind_method(D_METHOD("_native_set_" #name, "value"), &NativeBulletBody::native_set_##name); \
    ClassDB::bind_method(D_METHOD("_native_get_" #name), &NativeBulletBody::native_get_##name); \
    ADD_PROPERTY(PropertyInfo(GetTypeInfo<type>::VARIANT_TYPE, #name, PROPERTY_HINT_NONE, "", field_usage(#name)), "_native_set_" #name, "_native_get_" #name);
#include "bullet_fields.inc"
#undef BULLET_FIELD
    ClassDB::bind_method(D_METHOD("configure_bullet", "values"), &NativeBulletBody::configure_bullet);
    ClassDB::bind_method(D_METHOD("bind_physics", "geometry", "gravity", "drag", "damping"), &NativeBulletBody::bind_physics);
    ClassDB::bind_method(D_METHOD("set_shooter", "node"), &NativeBulletBody::set_shooter);
    ClassDB::bind_method(D_METHOD("get_shooter"), &NativeBulletBody::get_shooter);
    ClassDB::bind_method(D_METHOD("native_bind_source_node", "value"), &NativeBulletBody::set_source_node);
    ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "shooter", PROPERTY_HINT_NODE_TYPE, "Node", PROPERTY_USAGE_NONE), "set_shooter", "get_shooter");
    ClassDB::bind_method(D_METHOD("advance_physics", "delta", "canonical"), &NativeBulletBody::advance_physics);
    ClassDB::bind_method(D_METHOD("get_native_impact"), &NativeBulletBody::get_native_impact);
    ClassDB::bind_method(D_METHOD("motion_state"), &NativeBulletBody::motion_state);
    ClassDB::bind_method(D_METHOD("restore_motion", "state"), &NativeBulletBody::restore_motion);
    ClassDB::bind_method(D_METHOD("start_player_fuse"), &NativeBulletBody::start_player_fuse);
    ClassDB::bind_method(D_METHOD("_start_fuse", "duration"), &NativeBulletBody::start_fuse);
    ClassDB::bind_method(D_METHOD("native_player_contact", "players", "radius", "point_only", "map_size", "team"), &NativeBulletBody::native_player_contact);
    ClassDB::bind_method(D_METHOD("native_contact_query", "players", "local", "radius", "point_only", "map_size", "queries"), &NativeBulletBody::native_contact_query);
    ClassDB::bind_static_method("NativeBulletBody", D_METHOD("contact_distance_native", "from", "to", "position", "radius", "map_size"), &NativeBulletBody::contact_distance);
}
void NativeBulletBody::configure_bullet(const Dictionary &values) {
#define BULLET_FIELD(type, name, initial) if (values.has(#name)) name = static_cast<type>(values[#name]);
#include "bullet_fields.inc"
#undef BULLET_FIELD
}
void NativeBulletBody::bind_physics(const Ref<NativeTerrain> &world, double gravity, double drag, double damping) {
    geometry = world; world_gravity = gravity; water_drag = drag; bounce_damping = damping;
}
void NativeBulletBody::set_shooter(Node *node) { shooter_id = node ? uint64_t(node->get_instance_id()) : 0; }
Node *NativeBulletBody::get_shooter() const {
    return shooter_id ? Object::cast_to<Node>(ObjectDB::get_instance(shooter_id)) : nullptr;
}
void NativeBulletBody::set_source_node(Node *value) { source_node_id = value ? uint64_t(value->get_instance_id()) : 0; }
Node *NativeBulletBody::get_source_node() const { return source_node_id ? Object::cast_to<Node>(ObjectDB::get_instance(source_node_id)) : nullptr; }
void NativeBulletBody::start_fuse(double duration) {
    if (!_fuse_active) { _fuse_duration = duration; fuse_started = true; }
    _fuse_active = true;
}
void NativeBulletBody::start_player_fuse() { if (explodes) start_fuse(hit_fuse_time); }
int NativeBulletBody::advance_physics(double delta, bool canonical) {
    ERR_FAIL_COND_V(geometry.is_null(), MOVED);
    geometry->flush_collisions();
    impact.unref();
    if (gravity_factor > 0) {
        velocity_vec.y = real_t(double(velocity_vec.y) + world_gravity * gravity_factor * delta);
        if (!velocity_vec.is_zero_approx()) set_rotation(velocity_vec.angle());
    }
    if (explodes && _fuse_active) {
        _fuse_elapsed += delta;
        if (_fuse_elapsed >= _fuse_duration) return FUSE_END;
    }
    if (geometry->water(get_global_position())) {
        const double factor = std::exp(-water_drag * delta);
        if (factor < 1) velocity_vec *= factor;
    }
    const Vector2 step = velocity_vec * delta;
    traveled += step.length();
    impact = move_and_collide(step);
    if (impact.is_valid()) {
        impact_velocity = velocity_vec;
        if (explodes) {
            const Node *hit = Object::cast_to<Node>(impact->get_collider());
            start_fuse(hit && hit->is_in_group("enemies") ? hit_fuse_time : fuse_time);
            velocity_vec = velocity_vec.bounce(impact->get_normal()) * bounce_damping;
            if (!velocity_vec.is_zero_approx()) set_rotation(velocity_vec.angle());
            return BOUNCED;
        }
        const Node *hit = Object::cast_to<Node>(impact->get_collider());
        if (!apply_damage || !hit || !hit->is_in_group("enemies")) { velocity_vec = Vector2(); finished = true; }
        return TERRAIN_HIT;
    }
    if (traveled >= max_range) return RANGE_END;
    if (canonical) set_global_position(simulation_wrap(get_global_position(), geometry->size()));
    return MOVED;
}
Dictionary NativeBulletBody::motion_state() const {
    Dictionary result;
    result["type_id"] = type_id; result["pos"] = get_position(); result["vel"] = velocity_vec;
    result["traveled"] = traveled; result["fuse_active"] = _fuse_active;
    result["fuse_elapsed"] = _fuse_elapsed; result["fuse_duration"] = _fuse_duration;
    result["direct_hit"] = direct_hit;
    return result;
}
void NativeBulletBody::restore_motion(const Dictionary &st) {
    set_position(st["pos"]); velocity_vec = st["vel"];
    if (!velocity_vec.is_zero_approx()) set_rotation(velocity_vec.angle());
    traveled = st["traveled"]; _fuse_active = st["fuse_active"];
    _fuse_elapsed = st["fuse_elapsed"]; _fuse_duration = st["fuse_duration"];
    adjudicated_pos = get_position(); adjudicated = true;
    finished = false; exploded = false; direct_hit = st["direct_hit"]; fuse_started = false;
    if (is_inside_tree()) force_update_transform();
}
static Vector2 toroidal_to(Vector2 from, Vector2 to, Vector2 size) {
    double dx = double(to.x) - double(from.x), dy = double(to.y) - double(from.y);
    if (std::abs(dx) > double(size.x) * .5) dx = -(dx > 0 ? 1 : -1) * (double(size.x) - std::abs(dx));
    if (std::abs(dy) > double(size.y) * .5) dy = -(dy > 0 ? 1 : -1) * (double(size.y) - std::abs(dy));
    return from + Vector2(dx, dy);
}
double NativeBulletBody::contact_distance(Vector2 from, Vector2 to, Vector2 position, double radius, Vector2 size) {
    const double infinity = std::numeric_limits<double>::infinity();
    const Vector2 center = simulation_nearest(position, from, size);
    if (center.x < std::min(double(from.x), double(to.x)) - radius || center.x > std::max(double(from.x), double(to.x)) + radius ||
        center.y < std::min(double(from.y), double(to.y)) - radius || center.y > std::max(double(from.y), double(to.y)) + radius) return infinity;
    const Vector2 hit = Geometry2D::get_singleton()->get_closest_point_to_segment(center, from, to);
    return hit.distance_squared_to(center) < radius * radius ? double(from.distance_squared_to(hit)) : infinity;
}
NativeActorBody *NativeBulletBody::contact(const Array &players, double radius, bool point_only, Vector2 size, int team) const {
    const Vector2 from = adjudicated && !point_only ? adjudicated_pos : get_global_position();
    const Vector2 to = toroidal_to(from, get_global_position(), size);
    double best = std::numeric_limits<double>::infinity();
    NativeActorBody *victim = nullptr;
    for (int i = 0; i < players.size(); ++i) {
        NativeActorBody *player = Object::cast_to<NativeActorBody>(players[i]);
        if (!player || player->role == entity_id >> 48 || player->sim_downed || player->rewinding || (team && team == player->team)) continue;
        const double distance = contact_distance(from, to, player->get_global_position(), radius, size);
        if (std::isfinite(distance) && (distance < best || (distance == best && victim && player->role < victim->role))) { best = distance; victim = player; }
    }
    return victim;
}
NativeActorBody *NativeBulletBody::native_player_contact(const Array &players, double radius, bool point_only, Vector2 size, int team) const {
    return contact(players, radius, point_only, size, team);
}
NativeActorBody *NativeBulletBody::native_contact_query(const Array &players, NativeActorBody *local,
        double radius, bool point_only, Vector2 size, const Array &queries_in) const {
    const NativeActorBody *owner = Object::cast_to<NativeActorBody>(get_shooter());
    const int team = owner ? int(owner->team) : 0;
    const Vector2 from = adjudicated && !point_only ? adjudicated_pos : get_global_position();
    const Vector2 to = toroidal_to(from, get_global_position(), size);
    double own_distance = std::numeric_limits<double>::infinity();
    if (local && local->role != entity_id >> 48 && !local->sim_downed && !local->rewinding && (!team || team != local->team))
        own_distance = contact_distance(from, to, local->get_global_position(), radius, size);
    NativeActorBody *victim = contact(players, radius, point_only, size, team);
    Array queries = queries_in;
    queries.push_back(Array::make(from, to, radius, entity_id >> 48, team, own_distance, victim ? victim->role : 0));
    return victim;
}
void godot::register_native_bullet() { ClassDB::register_class<NativeBulletBody>(); }
