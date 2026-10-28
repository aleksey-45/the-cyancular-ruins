#pragma once
#include "simulation.h"

namespace godot {

struct ActorMotionState {
#define MOTION_FIELD(type, name, key, read, write) type name = {};
#include "motion_fields.inc"
#undef MOTION_FIELD
    int pose = 0;
    static ActorMotionState from_dictionary(const Dictionary &state, int pose);
    static ActorMotionState capture(const NativeActorBody &body);
    Dictionary to_dictionary() const;
    void restore(NativeActorBody &body) const;
};

// One bounded, contiguous trajectory per authoritative anchor. Generation and
// sampling use typed states; dictionaries exist only at the network adapter.
class NativeMotionTrack : public RefCounted {
    GDCLASS(NativeMotionTrack, RefCounted)
    std::vector<ActorMotionState> samples;
    Rect2 bounds;
    int horizon = 0, hp = 0, waterproof = 0;
    bool downed = false, locked = false;
    double axis = 0;
    int64_t held = 0;
    Vector2 movement_multiplier;
protected:
    static void _bind_methods();
public:
    void initialize(const Dictionary &data, int limit, Rect2 initial_bounds);
    int size() const { return int(samples.size()); }
    Rect2 get_bounds() const { return bounds; }
    int extend(NativeActorBody *body, int ahead, double delta, double time_multiplier,
        bool pvp, const Ref<NativeTerrain> &geometry, double cover_margin);
    void apply(NativeActorBody *body, int index, bool stale) const;
};
} // namespace godot
