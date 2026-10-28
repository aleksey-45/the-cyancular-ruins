#pragma once
#include "simulation.h"

namespace godot {
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
