#pragma once
#include "simulation.h"

namespace godot {
class NativeBulletBody : public CharacterBody2D {
    GDCLASS(NativeBulletBody, CharacterBody2D)
    Ref<NativeTerrain> geometry;
    Ref<KinematicCollision2D> impact;
    uint64_t shooter_id = 0, source_node_id = 0;
    double world_gravity = 0, water_drag = 0, bounce_damping = 0;
    NativeActorBody *contact(const Array &players, double radius, bool point_only,
        Vector2 map_size, int team) const;
protected:
    static void _bind_methods();
public:
    enum AdvanceResult { MOVED, BOUNCED, TERRAIN_HIT, RANGE_END, FUSE_END };
#define BULLET_FIELD(type, name, initial) \
    type name = initial; \
    void native_set_##name(type value) { name = value; } \
    type native_get_##name() const { return name; }
#include "bullet_fields.inc"
#undef BULLET_FIELD
    void configure_bullet(const Dictionary &values);
    void bind_physics(const Ref<NativeTerrain> &world, double gravity, double drag, double damping);
    void set_shooter(Node *node);
    Node *get_shooter() const;
    void set_source_node(Node *value);
    Node *get_source_node() const;
    int advance_physics(double delta, bool canonical);
    Ref<KinematicCollision2D> get_native_impact() const { return impact; }
    Dictionary motion_state() const;
    void restore_motion(const Dictionary &state);
    void start_player_fuse();
    void start_fuse(double duration);
    NativeActorBody *native_player_contact(const Array &players, double radius, bool point_only,
        Vector2 map_size, int team) const;
    NativeActorBody *native_contact_query(const Array &players, NativeActorBody *local,
        double radius, bool point_only, Vector2 map_size, const Array &queries) const;
    static double contact_distance(Vector2 from, Vector2 to, Vector2 position, double radius, Vector2 map_size);
};
void register_native_bullet();
}
