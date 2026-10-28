#include "simulation.h"
#include "motion_track.h"
#include "bullet_body.h"
#include "weapon_body.h"
#include "combat_kernel.h"
#include "prediction_history.h"
#include "projectile_entry.h"
#include <godot_cpp/core/object.hpp>
#include <godot_cpp/classes/shape2d.hpp>
#include <algorithm>
#include <cmath>

using namespace godot;

void NativeActorInput::_bind_methods() {
    ClassDB::bind_method(D_METHOD("prepare", "record", "locked"), &NativeActorInput::prepare);
#define INPUT_FIELD(type, name, initial) \
    ClassDB::bind_method(D_METHOD("_native_set_" #name, "value"), &NativeActorInput::native_set_##name); \
    ClassDB::bind_method(D_METHOD("_native_get_" #name), &NativeActorInput::native_get_##name); \
    ADD_PROPERTY(PropertyInfo(GetTypeInfo<type>::VARIANT_TYPE, #name, PROPERTY_HINT_NONE, "", PROPERTY_USAGE_NONE), "_native_set_" #name, "_native_get_" #name);
#include "input_fields.inc"
#undef INPUT_FIELD
}

void NativeActorInput::prepare(const Dictionary &record, bool locked) {
    raw_axis = record["ax"];
    raw_held = record["held"];
    aim = record["aim"];
    axis = locked ? 0 : raw_axis;
    held = locked ? 0 : raw_held;
    pressed = locked ? 0 : int64_t(record["pressed"]);
    released = locked ? 0 : int64_t(record["released"]);
    weapon_inst = locked ? 0 : int64_t(record["winst"]);
    vertical_axis = (held & 1) ? -1 : ((held & 2) ? 1 : 0);
}

Vector2 godot::simulation_wrap(Vector2 position, Vector2 size) {
    // Match GridPathfinder's single-wrap arithmetic, including float rounding.
    for (int axis = 0; axis < 2; ++axis) {
        if (size[axis] <= 0) continue;
        if (position[axis] >= size[axis]) position[axis] -= size[axis];
        else if (position[axis] < 0) position[axis] += size[axis];
    }
    return position;
}

Vector2 godot::simulation_nearest(Vector2 position, Vector2 anchor, Vector2 size) {
    for (int axis = 0; axis < 2; ++axis) {
        if (size[axis] <= 0) continue;
        const double distance = double(position[axis]) - double(anchor[axis]);
        if (distance > double(size[axis]) * .5) position[axis] -= size[axis];
        else if (distance < -double(size[axis]) * .5) position[axis] += size[axis];
    }
    return position;
}

void NativeActorCollider::_bind_methods() {
    ClassDB::bind_method(D_METHOD("initialize", "source", "layer"), &NativeActorCollider::initialize);
    ClassDB::bind_method(D_METHOD("set_source", "source"), &NativeActorCollider::set_source);
    ClassDB::bind_method(D_METHOD("get_source"), &NativeActorCollider::get_source);
    ClassDB::bind_method(D_METHOD("set_collision_layer", "layer"), &NativeActorCollider::set_collision_layer);
    ClassDB::bind_method(D_METHOD("get_collision_layer"), &NativeActorCollider::get_collision_layer);
    ClassDB::bind_method(D_METHOD("world_rect", "anchor"), &NativeActorCollider::world_rect);
    ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "source", PROPERTY_HINT_NODE_TYPE, "NativeActorBody"), "set_source", "get_source");
    ADD_PROPERTY(PropertyInfo(Variant::INT, "collision_layer"), "set_collision_layer", "get_collision_layer");
}
void NativeActorCollider::initialize(NativeActorBody *source, int64_t p_layer) {
    set_source(source);
    layer = p_layer;
}
void NativeActorCollider::set_source(NativeActorBody *source) {
    source_id = source ? uint64_t(source->get_instance_id()) : 0;
    revision = -1;
}
NativeActorBody *NativeActorCollider::get_source() const {
    return source_id ? Object::cast_to<NativeActorBody>(ObjectDB::get_instance(source_id)) : nullptr;
}
Rect2 NativeActorCollider::world_rect(Vector2 anchor) {
    NativeActorBody *source = get_source();
    if (!source) return Rect2();
    if (revision != source->collision_revision) {
        revision = source->collision_revision;
        const int current_stance = source->collision_stance();
        Transform2D transform = source->get_global_transform();
        transform.set_origin(Vector2());
        if (stance != current_stance || basis != transform) {
            stance = current_stance;
            basis = transform;
            if (stance >= source->hulls.size()) return Rect2();
            const CollisionShape2D *hull = Object::cast_to<CollisionShape2D>(source->hulls[stance]);
            local_rect = (transform * hull->get_transform()).xform(hull->get_shape()->get_rect());
        }
    }
    Rect2 result = local_rect;
    result.position += simulation_nearest(source->get_global_position(), anchor,
        source->map_dimensions);
    return result;
}

static void initialize_simulation(ModuleInitializationLevel level) {
    if (level != MODULE_INITIALIZATION_LEVEL_SCENE) return;
    ClassDB::register_class<NativeActorInput>();
    register_native_terrain();
    ClassDB::register_class<NativeActorBody>();
    ClassDB::register_class<NativeMotionTrack>();
    ClassDB::register_class<NativeActorCollider>();
    register_native_bullet();
    register_native_projectile_entry();
    register_native_weapon();
    register_native_combat();
    register_native_history();
}
static void terminate_simulation(ModuleInitializationLevel) {}
extern "C" GDExtensionBool GDE_EXPORT simulation_init(GDExtensionInterfaceGetProcAddress proc,
        GDExtensionClassLibraryPtr library, GDExtensionInitialization *initialization) {
    GDExtensionBinding::InitObject init(proc, library, initialization);
    init.register_initializer(initialize_simulation);
    init.register_terminator(terminate_simulation);
    init.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);
    return init.init();
}
