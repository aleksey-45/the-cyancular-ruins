#include "prediction_history.h"
#include "combat_kernel.h"
#include <godot_cpp/core/object.hpp>

using namespace godot;
void NativePredictionHistory::_bind_methods() {
    ClassDB::bind_method(D_METHOD("bind_sources", "states", "entries", "hitboxes", "keep"), &NativePredictionHistory::bind_sources);
    ClassDB::bind_method(D_METHOD("capture_hitboxes", "tick", "players"), &NativePredictionHistory::capture_hitboxes);
    ClassDB::bind_method(D_METHOD("configure_remotes", "records"), &NativePredictionHistory::configure_remotes);
    ClassDB::bind_method(D_METHOD("remember", "tick", "player", "instance", "inventory", "cursor", "time", "revision", "geometry", "terrain"), &NativePredictionHistory::remember);
}
void NativePredictionHistory::bind_sources(const Dictionary &states, const Dictionary &entries, const Dictionary &boxes, int limit) {
    frames = states; projectiles = entries; hitboxes = boxes; keep = limit;
}
void NativePredictionHistory::capture_hitboxes(int64_t tick, const Array &players) {
    Dictionary boxes;
    for (int i = 0; i < players.size(); ++i) {
        const NativeActorBody *player = Object::cast_to<NativeActorBody>(players[i]);
        if (player) boxes[player->role] = player->collision_rect();
    }
    hitboxes[tick] = boxes; hitboxes.erase(tick - keep);
}
void NativePredictionHistory::configure_remotes(const Array &records) {
    bool same = records.size() == int(remotes.size());
    for (int i = 0; same && i < records.size(); ++i) {
        const Array record = records[i];
        const NativeActorBody *actor = Object::cast_to<NativeActorBody>(record[1]);
        const Ref<NativeActorCollider> collider = record[2];
        const Remote &old = remotes[size_t(i)];
        same = actor && old.role == int64_t(record[0]) && old.actor_id == uint64_t(actor->get_instance_id())
            && old.collider == collider && old.respawn_tick == int64_t(record[3]);
    }
    if (same) return;
    metadata_valid = false;
    remotes.clear(); remotes.reserve(records.size());
    for (int i = 0; i < records.size(); ++i) {
        const Array record = records[i];
        const NativeActorBody *actor = Object::cast_to<NativeActorBody>(record[1]);
        ERR_CONTINUE(!actor);
        Remote remote;
        remote.role = record[0]; remote.actor_id = uint64_t(actor->get_instance_id());
        remote.collider = record[2]; remote.respawn_tick = record[3];
        remotes.push_back(remote);
    }
}
void NativePredictionHistory::remember(int64_t tick, NativeActorBody *player, int64_t instance,
        const Array &inventory, const Array &cursor, const Dictionary &time,
        int64_t revision, int64_t geometry, int64_t terrain) {
    ERR_FAIL_COND(!player || keep <= 0);
    Dictionary contacts;
    bool changed = !metadata_valid;
    contacts[player->role] = Array::make(player->get_global_position(), player->sim_downed, player->team);
    for (Remote &entry : remotes) {
        const NativeActorBody *actor = Object::cast_to<NativeActorBody>(ObjectDB::get_instance(entry.actor_id));
        const int64_t layer = actor && entry.collider.is_valid() ? entry.collider->get_collision_layer() : 0;
        const bool present = actor != nullptr, rewinding = actor && actor->rewinding;
        changed |= entry.present != present || entry.sampled_layer != layer || entry.rewinding != rewinding;
        entry.present = present; entry.sampled_layer = layer; entry.rewinding = rewinding;
        if (layer) contacts[entry.role] = Array::make(actor->get_global_position(), actor->sim_downed, actor->team);
    }
    if (changed) {
        // Published metadata is immutable. Replace its containers on change;
        // clearing or updating them in place would corrupt earlier checkpoints.
        Dictionary modes, layers;
        for (const Remote &entry : remotes) {
            if (!entry.present) continue;
            Array mode = Array::make(entry.rewinding, entry.respawn_tick);
            mode.make_read_only();
            modes[entry.role] = mode;
            layers[entry.role] = entry.sampled_layer;
        }
        modes.make_read_only(); layers.make_read_only();
        remote_modes = modes; remote_layers = layers; metadata_valid = true;
    }
    Dictionary players, cursors, saved;
    players[player->role] = player->capture_prediction_state_native(instance, inventory);
    cursors[player->role] = cursor;
    saved["players"] = players; saved["cursors"] = cursors; saved["remote"] = remote_modes;
    saved["layers"] = remote_layers; saved["contacts"] = contacts; saved["geometry"] = geometry;
    saved["projectiles"] = snapshot_projectiles_native(projectiles); saved["revision"] = revision;
    saved["time"] = time; saved["terrain"] = terrain; saved["rewinding"] = player->rewinding;
    frames[tick] = saved;
    frames.erase(tick - keep);
}
void godot::register_native_history() { ClassDB::register_class<NativePredictionHistory>(); }
