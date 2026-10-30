#pragma once
#include "simulation.h"
#include "projectile_snapshot.h"

namespace godot {
class NativePredictionFrame : public RefCounted {
    GDCLASS(NativePredictionFrame, RefCounted)
protected:
    static void _bind_methods();
public:
    struct Contact {
        int64_t role = 0, team = 0;
        Vector2 position;
        bool downed = false, rewinding = false;
    };
    std::vector<Contact> contacts;
#define FRAME_FIELD(type, name) \
    type name = {}; \
    type get_##name() const { return name; } \
    void set_##name(const type &value) { name = value; }
    FRAME_FIELD(Array, player)
    FRAME_FIELD(Array, cursor)
    FRAME_FIELD(Dictionary, remote)
    FRAME_FIELD(Dictionary, layers)
    FRAME_FIELD(Dictionary, time)
    FRAME_FIELD(Ref<NativeProjectileSnapshot>, projectiles)
    FRAME_FIELD(int64_t, revision)
    FRAME_FIELD(int64_t, geometry)
    FRAME_FIELD(int64_t, terrain)
    FRAME_FIELD(bool, rewinding)
#undef FRAME_FIELD
};

class NativePredictionHistory : public RefCounted {
    GDCLASS(NativePredictionHistory, RefCounted)
    struct Remote {
        int64_t role = 0, respawn_tick = 0;
        uint64_t actor_id = 0;
        Ref<NativeActorCollider> collider;
        int64_t sampled_layer = 0;
        bool present = false, rewinding = false;
    };
    Dictionary frames, projectiles, hitboxes;
    Dictionary remote_modes, remote_layers;
    std::vector<Remote> remotes;
    bool metadata_valid = false;
    size_t projectile_capacity = 0;
    int keep = 0;
protected:
    static void _bind_methods();
public:
    void bind_sources(const Dictionary &states, const Dictionary &entries, const Dictionary &boxes, int limit);
    void configure_remotes(const Array &records);
    void capture_hitboxes(int64_t tick, const Array &players);
    void remember(int64_t tick, NativeActorBody *player, int64_t instance, const Array &inventory,
        const Array &cursor, const Dictionary &time, int64_t revision, int64_t geometry, int64_t terrain);
};
void register_native_history();
} // namespace godot
