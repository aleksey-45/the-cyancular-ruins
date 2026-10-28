#pragma once
#include "simulation.h"

namespace godot {
class NativeWeaponBody : public Node2D {
    GDCLASS(NativeWeaponBody, Node2D)
    uint64_t player_id = 0, muzzle_id = 0;
    bool authority_owner = false;
    bool external_held = false, external_pressed = false, external_released = false;
    Vector2 external_aim;
    Vector2 aim() const;
    void auto_aim();
    int live_projectiles() const;
    void sound(const String &value);
protected:
    static void _bind_methods();
public:
#define WEAPON_FIELD(type, name, initial, exported) \
    type name = initial; \
    void native_set_##name(type value) { name = value; } \
    type native_get_##name() const { return name; }
#include "weapon_fields.inc"
#undef WEAPON_FIELD
    void set_player(Node2D *value);
    Node2D *get_player() const;
    NativeActorBody *actor() const;
    void bind_owner(Node2D *player, bool authority);
    void bind_muzzle(Node2D *value);
    void external_input(bool held, bool pressed, bool released, Vector2 aim);
    void initialize_magazine();
    void reset_simulation_state(int mag, int full);
    void tick_weapon(double delta);
    void try_fire();
    void fire();
    void start_reload();
    void cancel_aim() { _aiming = false; }
    bool is_previewing() const { return _aiming; }
    bool is_reloading() const { return _reloading; }
    double reload_progress() const;
    Vector2 get_movement_multiplier() const;
    Vector2 clamped_aim() const;
    void apply_aim_pose(double angle, int facing);
    Array projectile_specs(const Dictionary &action) const;
    void append_prediction_state(Array &values) const;
    void write_driver_state(Dictionary &state) const;
    void restore_driver_state(const Dictionary &state);
    static double clamp_pitch(Vector2 direction, int facing, double limit);
    static int aim_facing_hint(Vector2 direction);
};
void register_native_weapon();
} // namespace godot
