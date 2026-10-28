#include "motion_track.h"

using namespace godot;

ActorMotionState ActorMotionState::from_dictionary(const Dictionary &state, int pose) {
    ActorMotionState result;
#define MOTION_FIELD(type, name, key, read, write) result.name = state[key];
#include "motion_fields.inc"
#undef MOTION_FIELD
    result.pose = pose;
    return result;
}
ActorMotionState ActorMotionState::capture(const NativeActorBody &body) {
    ActorMotionState result;
#define MOTION_FIELD(type, name, key, read, write) result.name = read;
#include "motion_fields.inc"
#undef MOTION_FIELD
    result.pose = body.state;
    return result;
}
Dictionary ActorMotionState::to_dictionary() const {
    Dictionary result;
#define MOTION_FIELD(type, name, key, read, write) result[key] = name;
#include "motion_fields.inc"
#undef MOTION_FIELD
    return result;
}
void ActorMotionState::restore(NativeActorBody &body) const {
#define MOTION_FIELD(type, name, key, read, write) { const type value = name; write; }
#include "motion_fields.inc"
#undef MOTION_FIELD
    body.state = pose;
    body.apply_collision_pose();
}

void NativeMotionTrack::_bind_methods() {
    ClassDB::bind_method(D_METHOD("initialize", "data", "limit", "initial_bounds"), &NativeMotionTrack::initialize);
    ClassDB::bind_method(D_METHOD("size"), &NativeMotionTrack::size);
    ClassDB::bind_method(D_METHOD("get_bounds"), &NativeMotionTrack::get_bounds);
    ClassDB::bind_method(D_METHOD("extend", "body", "ahead", "delta", "time_multiplier", "pvp", "terrain", "cover_margin"), &NativeMotionTrack::extend);
    ClassDB::bind_method(D_METHOD("apply", "body", "index", "stale"), &NativeMotionTrack::apply);
}
void NativeMotionTrack::initialize(const Dictionary &data, int limit, Rect2 initial_bounds) {
    ERR_FAIL_COND(limit < 0);
    samples.clear();
    horizon = limit;
    samples.reserve(size_t(horizon) + 1);
    samples.push_back(ActorMotionState::from_dictionary(data, data["pose"]));
    bounds = initial_bounds;
    hp = data["hp"]; waterproof = data["waterproof"]; downed = data["downed"];
    locked = data["locked"]; axis = data["axis"]; held = int64_t(data["held"]) & 3;
    movement_multiplier = data["move_mult"];
}
int NativeMotionTrack::extend(NativeActorBody *body, int ahead, double delta, double time_multiplier,
        bool pvp, const Ref<NativeTerrain> &geometry, double cover_margin) {
    ERR_FAIL_COND_V(!body || samples.empty() || ahead < 0 || ahead > horizon || geometry.is_null(), 0);
    if (ahead < size()) return 0;
    const Ref<NativeActorInput> input = body->get_step_input();
    ERR_FAIL_COND_V(input.is_null(), 0);
    samples.back().restore(*body);
    body->rewinding = false;
    body->_controls_locked = locked;
    body->native_apply_authoritative_state(hp, waterproof, downed);
    // Continue only the known sustained input. No new edges, weapon or gameplay.
    input->raw_axis = axis; input->raw_held = held; input->aim = Vector2();
    input->axis = locked ? 0 : axis; input->held = locked ? 0 : held;
    input->pressed = 0; input->released = 0; input->weapon_inst = 0;
    input->vertical_axis = (input->held & 1) ? -1 : ((input->held & 2) ? 1 : 0);
    body->step_actions.clear();
    body->set_actor_colliders(Array());
    const int previous = size();
    while (size() <= ahead) {
        body->motion_bounds = body->collision_rect().grow(cover_margin);
        body->native_simulate_motion(delta, movement_multiplier, time_multiplier, true, pvp,
            geometry);
        bounds = bounds.merge(body->motion_bounds);
        samples.push_back(ActorMotionState::capture(*body));
    }
    return size() - previous;
}
void NativeMotionTrack::apply(NativeActorBody *body, int index, bool stale) const {
    ERR_FAIL_COND(!body || index < 0 || index >= size());
    samples[size_t(index)].restore(*body);
    body->_controls_locked = locked;
    body->set_global_position(simulation_wrap(body->get_global_position(), body->map_dimensions));
    if (stale) {
        body->set_velocity(Vector2());
        body->motion_knock_velocity = Vector2();
    }
    body->rewinding = false;
    body->native_apply_authoritative_state(hp, waterproof, downed);
}
