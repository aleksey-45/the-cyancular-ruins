#pragma once
#include "simulation.h"

namespace godot {
struct ProjectileMotionState {
    int64_t type = 0;
    Vector2 position, velocity;
    double traveled = 0, fuse_elapsed = 0, fuse_duration = 0;
    bool fuse_active = false, direct_hit = false;
    static ProjectileMotionState from_dictionary(const Dictionary &state);
    Dictionary to_dictionary() const;
    bool matches(const Dictionary &state) const;
};

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
    void bind_physics(const Ref<NativeTerrain> &world, double gravity, double drag, double damping);
    void set_shooter(Node *node);
    Node *get_shooter() const;
    void set_source_node(Node *value);
    Node *get_source_node() const;
    int advance_physics(double delta, bool canonical);
    Ref<KinematicCollision2D> get_native_impact() const { return impact; }
    Dictionary motion_state() const;
    void restore_motion(const Dictionary &state);
    ProjectileMotionState capture_motion() const;
    void restore_motion_state(const ProjectileMotionState &state);
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
