#pragma once
#include "terrain.h"

#include <godot_cpp/godot.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/classes/character_body2d.hpp>
#include <godot_cpp/classes/collision_shape2d.hpp>
#include <godot_cpp/classes/kinematic_collision2d.hpp>
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/typed_array.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <array>
#include <unordered_map>
#include <vector>

namespace godot {

// Bindings expose scene state to scripts. Simulation accesses members directly.
class NativeActorInput : public RefCounted {
    GDCLASS(NativeActorInput, RefCounted)
protected:
    static void _bind_methods();
public:
#define INPUT_FIELD(type, name, initial) \
    type name = initial; \
    void native_set_##name(type value) { name = value; } \
    type native_get_##name() const { return name; }
#include "input_fields.inc"
#undef INPUT_FIELD
    void prepare(const Dictionary &record, bool locked);
};

class NativeActorBody;
class NativeWeaponBody;
class NativeActorCollider : public RefCounted {
    GDCLASS(NativeActorCollider, RefCounted)
    uint64_t source_id = 0;
    int64_t layer = 0, revision = -1;
    int stance = -1;
    Transform2D basis;
    Rect2 local_rect;
protected:
    static void _bind_methods();
public:
    void initialize(NativeActorBody *source, int64_t p_layer);
    void set_source(NativeActorBody *source);
    NativeActorBody *get_source() const;
    void set_collision_layer(int64_t value) { layer = value; }
    int64_t get_collision_layer() const { return layer; }
    Rect2 world_rect(Vector2 anchor);
};

class NativeActorBody : public CharacterBody2D {
    GDCLASS(NativeActorBody, CharacterBody2D)
    friend class NativeActorCollider;
    Ref<NativeActorInput> input;
    TypedArray<CollisionShape2D> hulls;
    Array colliders, actor_queries;
    TypedArray<KinematicCollision2D> motion_contacts;
    Dictionary cache_markers;
    Ref<NativeTerrain> geometry;
    Vector2 native_velocity;
    double speed_mult = 1;
    int64_t geometry_revision = -1;
    uint64_t weapon_id = 0, visual_root_id = 0;
    Dictionary prediction_projectiles;
    bool prediction_registry_bound = false;

    struct MotionKey {
        Transform2D transform, hull;
        Vector2 travel;
        Rect2 rect;
        RID shape;
        uint32_t mask = 0;
        double margin = 0;
        bool operator==(const MotionKey &other) const;
        uint64_t hash() const;
    };
    struct CacheEntry {
        MotionKey key;
        Transform2D destination;
        Ref<KinematicCollision2D> contact;
        uint64_t hash = 0;
    };
    std::array<CacheEntry, 256> motion_cache;
    std::unordered_map<uint64_t, size_t> cache_index;
    size_t cache_next = 0;

    std::vector<Rect2> obstacles(uint32_t mask, Vector2 anchor) const;
    double query_motion(Rect2 bounds, int axis, double distance, const std::vector<Rect2> &bounds_list);
    bool query_overlap(Rect2 bounds);
    Ref<KinematicCollision2D> terrain_motion(Vector2 travel, Transform2D hull, RID shape, Rect2 rect);
    Vector2 move_by_internal(Vector2 motion);
    void move_actor(double delta);
    void brake(double delta);
    void wrap();
    void update_swim(double delta, Vector2 mult);
    bool over_climb_tile() const;
    bool ladder_top(Vector2i foot) const;
    void update_climb(double delta, Vector2 mult);
    void update_waterproof(double delta, bool pvp);
    void update_vertical(double delta, bool latched, Vector2 mult);
    void update_crouch_dash();
    void update_horizontal(double delta, Vector2 mult);
    void update_facing(double delta);
    void update_pose(double delta);
    void slide_reactions(Vector2 incoming);
    void impulse(int kind);

protected:
    static void _bind_methods();
public:
    NativeActorBody();
#define ACTOR_FIELD(type, name, initial) \
    type name = initial; \
    void native_set_##name(type value) { name = value; } \
    type native_get_##name() const { return name; }
#include "actor_fields.inc"
#undef ACTOR_FIELD
    void configure_motion(const Dictionary &values);
    void set_step_input(const Ref<NativeActorInput> &value) { input = value; }
    Ref<NativeActorInput> get_step_input() const { return input; }
    void set_hulls(const TypedArray<CollisionShape2D> &value) { hulls = value; }
    TypedArray<CollisionShape2D> get_hulls() const { return hulls; }
    void set_actor_colliders(const Array &value) { colliders = value; }
    Array get_actor_colliders() const { return colliders; }
    Array get_actor_queries() const { return actor_queries; }
    void set_actor_queries(const Array &value) { actor_queries = value; }
    TypedArray<KinematicCollision2D> get_motion_contacts() const { return motion_contacts; }
    Dictionary get_terrain_motion_cache() const { return cache_markers; }
    Array step_actions;
    void set_step_actions(const Array &value) { step_actions = value; }
    Array get_step_actions() const { return step_actions; }
    void native_simulate_motion(double delta, Vector2 mult, double time_mult, bool motion_only,
        bool pvp, const Ref<NativeTerrain> &world);
    void native_step_actor(double delta, double time_mult, bool pvp,
        const Ref<NativeTerrain> &world);
    void set_simulation_weapon(Node2D *value);
    Node2D *get_simulation_weapon() const;
    NativeWeaponBody *active_weapon() const;
    void set_simulation_visuals(Node2D *value);
    Node2D *get_simulation_visuals() const;
    Vector2 native_shot_origin(Node2D *muzzle) const;
    void bind_prediction_projectiles(const Dictionary &entries);
    bool has_prediction_registry() const { return prediction_registry_bound; }
    int count_prediction_projectiles(int64_t type) const;
    void native_apply_recoil(double push);
    void native_apply_impulse(Vector2 source, double force);
    bool native_simulate_hit(Vector2 source, int damage, double force);
    bool native_force_down();
    bool native_queries_match(const Array &queries) const;
    void apply_collision_pose();
    int collision_stance() const { return int(is_squat && !sim_downed); }
    Rect2 collision_rect() const;
    void set_crouched(bool crouched);
    void cancel_charge() { is_charge = false; charge_timer = 0; }
    void cancel_jump_state() { coyote_timer = 0; jump_buffer_timer = 0; jump_cut_applied = false; }
    void reset_motion();
    Dictionary capture_motion_state() const;
    void restore_motion_state(const Dictionary &state, int pose);
    void native_apply_authoritative_state(int hp, int waterproof, bool downed);
    Array capture_prediction_prefix(int64_t weapon_instance, const Array &inventory) const;
    Array capture_prediction_state_native(int64_t weapon_instance, const Array &inventory) const;
    Dictionary capture_state_native(int64_t weapon_instance, const Array &inventory) const;
    void write_driver_state_native(Dictionary state, int64_t weapon_instance, const Array &inventory) const;
    void restore_logic_state(const Dictionary &state);
};

Vector2 simulation_nearest(Vector2 position, Vector2 anchor, Vector2 size);
Vector2 simulation_wrap(Vector2 position, Vector2 size);

} // namespace godot
