#include "combat_kernel.h"
#include <godot_cpp/core/object.hpp>
#include <algorithm>
#include <cmath>
#include <limits>
#include <set>

using namespace godot;
namespace {
const double infinity = std::numeric_limits<double>::infinity();
NativeProjectileEntry *entry_of(const Variant &value) { return Object::cast_to<NativeProjectileEntry>(value); }
NativeBulletBody *body_of(const Variant &value) { const NativeProjectileEntry *entry = entry_of(value); return entry ? entry->get_bullet() : nullptr; }
Vector2 shortest_delta(Vector2 from, Vector2 to, Vector2 size) {
    double x = double(to.x) - double(from.x), y = double(to.y) - double(from.y);
    if (std::abs(x) > double(size.x) * .5) x = -(x > 0 ? 1 : -1) * (double(size.x) - std::abs(x));
    if (std::abs(y) > double(size.y) * .5) y = -(y > 0 ? 1 : -1) * (double(size.y) - std::abs(y));
    return Vector2(x, y);
}
Array ensure_array(Dictionary &dict, int64_t key) {
    if (!dict.has(key)) dict[key] = Array();
    return dict[key];
}
Dictionary ensure_dictionary(Dictionary &dict, int64_t key) {
    if (!dict.has(key)) dict[key] = Dictionary();
    return dict[key];
}
}

Dictionary godot::snapshot_projectiles_native(const Dictionary &entries) {
    Dictionary result;
    const Array ids = entries.keys();
    for (int i = 0; i < ids.size(); ++i) {
        NativeProjectileEntry *entry = entry_of(entries[ids[i]]);
        NativeBulletBody *bullet = entry ? entry->get_bullet() : nullptr;
        if (bullet && entry->active && !bullet->finished) result[ids[i]] = bullet->motion_state();
    }
    return result;
}
void NativeCombatKernel::_bind_methods() {
    ClassDB::bind_method(D_METHOD("configure", "player", "sources", "profiles", "rules"), &NativeCombatKernel::configure);
    ClassDB::bind_method(D_METHOD("bind_hitboxes", "value"), &NativeCombatKernel::bind_hitboxes);
    ClassDB::bind_method(D_METHOD("step", "tick", "players", "geometry", "first_prediction"), &NativeCombatKernel::step);
    ClassDB::bind_method(D_METHOD("take_notifications"), &NativeCombatKernel::take_notifications);
    ClassDB::bind_method(D_METHOD("step_beams", "tick", "role", "players", "geometry"), &NativeCombatKernel::step_beams);
    ClassDB::bind_method(D_METHOD("snapshot_projectiles"), &NativeCombatKernel::snapshot_projectiles);
    ClassDB::bind_method(D_METHOD("confirmed_result_at", "id", "tick", "source", "role"), &NativeCombatKernel::confirmed_result_at);
    ClassDB::bind_method(D_METHOD("proxy_queries_match", "tick", "proxies", "actors", "map_size"), &NativeCombatKernel::proxy_queries_match);
    ClassDB::bind_method(D_METHOD("catch_up_remote", "id", "history", "through", "delta", "map_size"), &NativeCombatKernel::catch_up_remote);
}
void NativeCombatKernel::configure(NativeActorBody *player, const Dictionary &sources,
        const Dictionary &weapon_profiles, const Dictionary &rules) {
    local_id = player ? uint64_t(player->get_instance_id()) : 0;
    projectiles = sources["projectiles"]; blasts = sources["blasts"]; beams = sources["beams"]; hits = sources["hits"]; ended = sources["ended"];
    outcomes = sources["outcomes"]; proxy_queries = sources["proxy_queries"]; owner_modes = sources["owner_modes"];
    hitboxes = sources["hitboxes"];
    keep = rules["keep"]; radius = rules["contact_radius"]; inner_fraction = rules["inner_fraction"];
    blocked_fraction = rules["blocked_fraction"]; beam_hit_mult = rules["beam_hit_mult"]; target_window = rules["target_window"];
    step_delta = rules["dt"];
    profiles.clear();
    const Array ids = weapon_profiles.keys();
    for (int i = 0; i < ids.size(); ++i) {
        const Dictionary data = weapon_profiles[ids[i]];
        profiles[int64_t(ids[i])] = Profile{double(data["impact"]), double(data["explosion_radius"]),
            double(data["explosion_knockback"]), int(data["damage"]), int(data["explosion_damage"])};
    }
}
NativeActorBody *NativeCombatKernel::local() const {
    return local_id ? Object::cast_to<NativeActorBody>(ObjectDB::get_instance(local_id)) : nullptr;
}
std::vector<int64_t> NativeCombatKernel::attack_ids(const Dictionary &entries, int source, int64_t role) const {
    std::set<int64_t> included;
    const Array ids = entries.keys();
    for (int i = 0; i < ids.size(); ++i) {
        const int64_t id = ids[i];
        if (role && id >> 48 != role) continue;
        if (source != 1) {
            const NativeProjectileEntry *entry = entry_of(entries[id]);
            const NativeBulletBody *bullet = entry ? entry->get_bullet() : nullptr;
            if (!entry || ((!entry->active || !bullet || bullet->finished) && entry->birth_tick != tick)) continue;
        } else if (int64_t(Dictionary(entries[id])["tick"]) != tick) continue;
        included.insert(id);
    }
    const Array hit_ids = hits.keys();
    for (int i = 0; i < hit_ids.size(); ++i) {
        const int64_t id = hit_ids[i];
        if (included.count(id)) continue;
        const Array records = hits[id];
        for (int h = 0; h < records.size(); ++h) {
            const Dictionary hit = records[h];
            if (int64_t(hit["tick"]) == tick && int(hit["source"]) == source && (!role || int64_t(hit["shooter"]) == role)) { included.insert(id); break; }
        }
    }
    return {included.begin(), included.end()};
}
Dictionary NativeCombatKernel::confirmed_hit(int64_t id, int source, int64_t role) const {
    return confirmed_result_at(id, tick, source, role);
}
Dictionary NativeCombatKernel::confirmed_result_at(int64_t id, int64_t at, int source, int64_t role) const {
    const Array records = hits.get(id, Array());
    for (int i = 0; i < records.size(); ++i) {
        const Dictionary hit = records[i];
        if (int64_t(hit["tick"]) == at && int(hit["source"]) == source && int64_t(hit["victim"]) == role) return hit;
    }
    return Dictionary();
}
void NativeCombatKernel::remember_outcome(const Array &key, const Dictionary &value) {
    Dictionary at = ensure_dictionary(outcomes, tick); at[key] = value;
}
void NativeCombatKernel::apply_hit(int64_t id, int source, NativeActorBody *target, Vector2 position, double force, int damage) {
    if (!target || target != local()) return;
    const Vector2 previous_velocity = target->get_velocity();
    const Dictionary confirmed = confirmed_hit(id, source, target->role);
    if (confirmed.is_empty()) target->native_simulate_hit(position, damage, force);
    else {
        target->facing_direction = confirmed["facing"];
        target->native_simulate_hit(position, target->sim_hp - int(confirmed["hp"]), 0);
        target->motion_knock_velocity = confirmed["knock"];
        target->native_apply_authoritative_state(confirmed["hp"], target->waterproof, int(confirmed["hp"]) <= 0);
    }
    Dictionary value;
    value["pos"] = position; value["hp"] = target->sim_hp; value["facing"] = target->facing_direction;
    value["knock"] = target->motion_knock_velocity; value["velocity_unchanged"] = previous_velocity == target->get_velocity();
    remember_outcome(Array::make("hit", id, source, target->role), value);
}
bool NativeCombatKernel::apply_confirmed_hits(int64_t id, int source, int64_t role) {
    bool applied = false;
    const Array records = hits.get(id, Array());
    for (int i = 0; i < records.size(); ++i) {
        const Dictionary hit = records[i];
        if (int64_t(hit["tick"]) != tick || int(hit["source"]) != source || (role && int64_t(hit["shooter"]) != role)) continue;
        for (int p = 0; p < players.size(); ++p) {
            NativeActorBody *player = Object::cast_to<NativeActorBody>(players[p]);
            if (player && player->role == int64_t(hit["victim"])) { apply_hit(id, source, player, hit["pos"], 0); applied = true; }
        }
    }
    return applied;
}
void NativeCombatKernel::simulate_projectile(NativeBulletBody *bullet, double delta) {
    const int result = bullet->advance_physics(delta, true);
    if (result == NativeBulletBody::RANGE_END || result == NativeBulletBody::FUSE_END) {
        if (bullet->explodes) bullet->exploded = true;
        bullet->finished = true;
    }
}
void NativeCombatKernel::reset_projectile(NativeProjectileEntry *entry, const Dictionary &state, int64_t at) {
    if (entry) entry->reset_at(state, at);
}
NativeActorBody *NativeCombatKernel::contact(NativeBulletBody *bullet, bool point_only) {
    const Array queries = ensure_array(proxy_queries, tick);
    return bullet->native_contact_query(players, local(), radius, point_only, geometry->size(), queries);
}
void NativeCombatKernel::finish_direct(NativeBulletBody *bullet) {
    remember_outcome(Array::make("contact", bullet->entity_id), Dictionary());
    bullet->direct_hit = true;
    if (bullet->explodes) bullet->start_player_fuse();
    else bullet->finished = true;
}
void NativeCombatKernel::step_blast(int64_t id) {
    const bool exists = blasts.has(id) && int64_t(Dictionary(blasts[id])["tick"]) == tick;
    if (exists) {
        if (projectiles.has(id)) {
            if (NativeBulletBody *bullet = body_of(projectiles[id])) { bullet->finished = true; bullet->exploded = true; }
        }
        const Dictionary blast = blasts[id];
        const auto found = profiles.find(int64_t(blast["type_id"]));
        ERR_FAIL_COND(found == profiles.end());
        const Profile &profile = found->second;
        if (first_prediction) notifications.push_back(Array::make("detonated", blast));
        NativeActorBody *target = nullptr;
        for (int i = 0; i < players.size(); ++i) if (Object::cast_to<NativeActorBody>(players[i]) == local()) { target = local(); break; }
        if (target && !target->sim_downed && !target->rewinding && confirmed_hit(id, 2, target->role).is_empty()) {
            const Vector2 center = blast["pos"];
            const double distance = shortest_delta(center, target->get_global_position(), geometry->size()).length();
            if (distance <= profile.radius) {
                const bool blocked = !geometry->empty() && !geometry->line_of_sight(center, target->get_global_position());
                const double cover = distance <= profile.radius * inner_fraction ? 1 : (blocked ? blocked_fraction : 1);
                const double mult = cover * geometry->water_multiplier(target->get_global_position());
                const auto falloff = [&](double maximum) {
                    const double inner = profile.radius * inner_fraction;
                    if (distance < inner) return maximum;
                    if (distance >= profile.radius) return 0.0;
                    const double fraction = (distance - inner) / (profile.radius - inner);
                    return maximum * (1 - fraction * fraction);
                };
                apply_hit(id, 2, target, center, falloff(profile.knock) * mult, int(falloff(profile.blast_damage) * mult));
            }
        }
    }
    apply_confirmed_hits(id, 2);
    if (!exists) return;
    const Dictionary blast = blasts[id];
    remember_outcome(Array::make("blast", id), blast.duplicate());
    const auto profile = profiles.find(int64_t(blast["type_id"]));
    ERR_FAIL_COND(profile == profiles.end());
    geometry->predict_blast(id, blast["type_id"], blast["pos"], blast["tick"],
        profile->second.radius, profile->second.blast_damage);
    // Subsequent projectiles query the terrain produced by this attack.
    geometry->flush_collisions();
}
void NativeCombatKernel::step(int64_t at, const Array &targets,
        const Ref<NativeTerrain> &world, bool first) {
    ERR_FAIL_COND(world.is_null());
    tick = at; players = targets; geometry = world; first_prediction = first;
    const Array recorded = outcomes.keys();
    for (int i = 0; i < recorded.size(); ++i) if (int64_t(recorded[i]) < tick - keep) outcomes.erase(recorded[i]);
    proxy_queries.erase(tick - keep); owner_modes.erase(tick - keep);
    const auto ids = attack_ids(projectiles, 2);
    std::set<int64_t> ordered(ids.begin(), ids.end());
    const Array blast_ids = blasts.keys();
    for (int i = 0; i < blast_ids.size(); ++i) if (int64_t(Dictionary(blasts[blast_ids[i]])["tick"]) == tick) ordered.insert(blast_ids[i]);
    if (!local()) return;
    for (const int64_t id : ordered) {
        if (!projectiles.has(id)) {
            step_blast(id);
            continue;
        }
        NativeProjectileEntry *entry = entry_of(projectiles[id]);
        NativeBulletBody *bullet = entry ? entry->get_bullet() : nullptr;
        if (!bullet) continue;
        NativeActorBody *owner = Object::cast_to<NativeActorBody>(bullet->get_shooter());
        if (owner && owner != local()) {
            Dictionary modes = ensure_dictionary(owner_modes, tick); modes[owner->role] = owner->rewinding;
        }
        if (!entry->active && entry->confirmed && entry->birth_tick == tick)
            reset_projectile(entry, entry->origin_state, entry->origin_tick);
        if (ended.has(id) && int64_t(ended[id]) <= tick) bullet->finished = true;
        if (!entry->active || tick <= entry->tick || bullet->finished || (owner && owner->rewinding)) {
            step_blast(id);
            continue;
        }
        while (entry->sim_tick < tick - 1 && !bullet->finished) {
            simulate_projectile(bullet, step_delta); ++entry->sim_tick;
        }
        if (bullet->finished) continue;
        entry->sim_tick = tick; entry->moved_tick = tick; bullet->adjudicated_pos = bullet->get_position();
        if (bullet->explodes && !bullet->_fuse_active && contact(bullet, true)) bullet->start_player_fuse();
        simulate_projectile(bullet, step_delta);
        const Dictionary checkpoints = entry->checkpoints;
        if (checkpoints.has(tick)) bullet->restore_motion(checkpoints[tick]);
        bullet->fuse_started = false;
        if (bullet->exploded && !(blasts.has(id) && bool(Dictionary(blasts[id])["confirmed"]))) {
            Dictionary blast; blast["id"] = id; blast["type_id"] = bullet->type_id;
            blast["pos"] = bullet->get_position(); blast["tick"] = tick; blast["confirmed"] = false; blasts[id] = blast;
        }
        step_blast(id);
    }
    step_contacts();
}
void NativeCombatKernel::step_contacts() {
    for (int64_t id : attack_ids(projectiles, 0)) {
        const bool confirmed = apply_confirmed_hits(id, 0);
        if (!projectiles.has(id)) continue;
        NativeProjectileEntry *entry = entry_of(projectiles[id]);
        NativeBulletBody *bullet = entry ? entry->get_bullet() : nullptr;
        if (!bullet) continue;
        if (confirmed) { finish_direct(bullet); continue; }
        const NativeActorBody *owner = Object::cast_to<NativeActorBody>(bullet->get_shooter());
        if (!entry->active || entry->moved_tick != tick || bullet->exploded || bullet->direct_hit || (owner && owner->rewinding)) continue;
        bool known = false;
        const Array records = hits.get(id, Array());
        for (int i = 0; i < records.size(); ++i) if (int(Dictionary(records[i])["source"]) == 0) { known = true; break; }
        NativeActorBody *victim = nullptr;
        Vector2 position = bullet->get_position();
        if (!known) victim = contact(bullet);
        else for (int i = 0; i < records.size(); ++i) {
            const Dictionary hit = records[i];
            if (int(hit["source"]) != 0 || int64_t(hit["tick"]) != tick) continue;
            for (int p = 0; p < players.size(); ++p) {
                NativeActorBody *player = Object::cast_to<NativeActorBody>(players[p]);
                if (player && player->role == int64_t(hit["victim"])) { victim = player; position = hit["pos"]; }
            }
        }
        if (!victim) continue;
        apply_hit(id, 0, victim, position, bullet->hit_impact, int(bullet->explodes ? bullet->direct_hit_damage : bullet->hit_damage));
        finish_direct(bullet);
    }
}
Array NativeCombatKernel::take_notifications() { Array result = notifications; notifications = Array(); return result; }
Vector2 NativeCombatKernel::path_contact(const PackedVector2Array &points, Rect2 rect, double corridor, Vector2 size) {
    for (int i = 0; i + 1 < points.size(); ++i) {
        const Vector2 center = simulation_nearest(rect.get_center(), points[i], size);
        const Rect2 anchored(center - rect.size * .5, rect.size);
        const Rect2 expanded = anchored.grow(corridor);
        const Vector2 a = points[i], direction = points[i + 1] - a, minimum = expanded.position, maximum = expanded.position + expanded.size;
        double t0 = 0, t1 = 1;
        bool intersects = true;
        for (int axis = 0; axis < 2; ++axis) {
            const double p = a[axis], delta = direction[axis], low = minimum[axis], high = maximum[axis];
            if (std::abs(delta) < 1e-9) { if (p < low || p > high) { intersects = false; break; } }
            else {
                double near = (low - p) / delta, far = (high - p) / delta;
                if (near > far) std::swap(near, far);
                t0 = std::max(t0, near); t1 = std::min(t1, far);
                if (t0 > t1) { intersects = false; break; }
            }
        }
        if (intersects) return a + direction * t0;
    }
    return Vector2(infinity, 0);
}
bool NativeCombatKernel::step_beams(int64_t at, int64_t role, const Array &targets, const Ref<NativeTerrain> &world) {
    ERR_FAIL_COND_V(world.is_null(), false);
    tick = at; players = targets; geometry = world;
    bool queried = false;
    for (int64_t id : attack_ids(beams, 1, role)) {
        if (beams.has(id)) {
            const Dictionary beam = beams[id];
            if (int64_t(beam["tick"]) == tick && int64_t(beam["shooter_role"]) == role) {
                queried = true;
                Dictionary bounds, contacts;
                NativeActorBody *owner = nullptr;
                for (int i = 0; i < players.size(); ++i) {
                    NativeActorBody *candidate = Object::cast_to<NativeActorBody>(players[i]);
                    if (candidate && candidate->role == role) owner = candidate;
                }
                for (int i = 0; i < players.size(); ++i) {
                    NativeActorBody *player = Object::cast_to<NativeActorBody>(players[i]);
                    if (!player || player != local() || player->role == role || player->sim_downed || player->rewinding ||
                            (owner && owner->team && owner->team == player->team) || !confirmed_hit(id, 1, player->role).is_empty()) continue;
                    Rect2 rect = player->collision_rect();
                    if (owner == local()) {
                        const int64_t view_tick = std::clamp(owner->view_tick, tick - target_window, tick);
                        const Dictionary boxes = hitboxes.get(view_tick, Dictionary());
                        rect = boxes.get(player->role, rect);
                    }
                    bounds[player->role] = rect;
                    const Vector2 point = path_contact(beam["pts"], rect, double(beam["half_width"]) * beam_hit_mult, world->size());
                    if (std::isfinite(double(point.x))) {
                        contacts[player->role] = point;
                        const auto profile = profiles.find(int64_t(beam["type_id"]));
                        ERR_CONTINUE(profile == profiles.end());
                        apply_hit(id, 1, player, point, profile->second.impact, profile->second.damage);
                    }
                }
                Dictionary result = beam.duplicate(); result["targets"] = bounds; result["contacts"] = contacts;
                remember_outcome(Array::make("beam", id), result);
            }
        }
        apply_confirmed_hits(id, 1, role);
    }
    return queried;
}
bool NativeCombatKernel::proxy_queries_match(int64_t at, const Array &proxies, const Dictionary &actors, Vector2 size) const {
    const Dictionary modes = owner_modes.get(at, Dictionary());
    const Array roles = modes.keys();
    for (int i = 0; i < roles.size(); ++i) {
        if (!actors.has(roles[i])) return false;
        const NativeActorBody *actor = Object::cast_to<NativeActorBody>(actors[roles[i]]);
        if (!actor || actor->rewinding != bool(modes[roles[i]])) return false;
    }
    const Array queries = proxy_queries.get(at, Array());
    for (int i = 0; i < queries.size(); ++i) {
        const Array query = queries[i];
        double best = query[5];
        const NativeActorBody *own = local();
        int64_t victim = std::isfinite(best) && own ? own->role : 0;
        for (int p = 0; p < proxies.size(); ++p) {
            const NativeActorBody *player = Object::cast_to<NativeActorBody>(proxies[p]);
            if (!player || player->role == int64_t(query[3]) || player->sim_downed || player->rewinding || (int64_t(query[4]) && int64_t(query[4]) == player->team)) continue;
            const double distance = NativeBulletBody::contact_distance(query[0], query[1], player->get_global_position(), query[2], size);
            if (distance < best || (std::isfinite(distance) && distance == best && player->role < victim)) { best = distance; victim = player->role; }
        }
        if (victim != int64_t(query[6])) return false;
    }
    return true;
}
Dictionary NativeCombatKernel::catch_up_remote(int64_t id, const Dictionary &history, int64_t through, double delta, Vector2 size) {
    ERR_FAIL_COND_V(!projectiles.has(id) || !local(), Dictionary());
    NativeProjectileEntry *entry = entry_of(projectiles[id]);
    NativeBulletBody *bullet = entry ? entry->get_bullet() : nullptr;
    ERR_FAIL_NULL_V(bullet, Dictionary());
    NativeActorBody *own = local();
    const NativeActorBody *owner = Object::cast_to<NativeActorBody>(bullet->get_shooter());
    const int64_t team = owner ? owner->team : 0;
    reset_projectile(entry, entry->origin_state, entry->origin_tick);
    Dictionary states, queries; Array contacted;
    for (int64_t at = entry->birth_tick; at <= through; ++at) {
        if (ended.has(id) && int64_t(ended[id]) <= at) bullet->finished = true;
        if (!bullet->finished) {
            bullet->adjudicated_pos = bullet->get_position(); simulate_projectile(bullet, delta);
            entry->sim_tick = at; entry->moved_tick = at;
            const Vector2 from = bullet->adjudicated_pos, to = from + shortest_delta(from, bullet->get_global_position(), size);
            const Dictionary saved = history[at], contacts = saved["contacts"], remote = saved["remote"];
            const Array local_contact = contacts[own->role];
            if (NativeBulletBody::contact_distance(from, to, local_contact[0], radius, size) < infinity) {
                reset_projectile(entry, entry->origin_state, entry->origin_tick); entry->active = false;
                return Dictionary();
            }
            double best = infinity; int64_t victim = 0;
            const Array roles = contacts.keys();
            for (int i = 0; i < roles.size(); ++i) {
                const int64_t role = roles[i];
                if (role == own->role || role == id >> 48) continue;
                const Array target = contacts[role], mode = remote[role];
                if (bool(target[1]) || bool(mode[0]) || (team && team == int64_t(target[2]))) continue;
                const double distance = NativeBulletBody::contact_distance(from, to, target[0], radius, size);
                if (distance < best || (std::isfinite(distance) && distance == best && role < victim)) { best = distance; victim = role; }
            }
            queries[at] = Array::make(from, to, radius, id >> 48, team, infinity, victim);
            if (victim) { bullet->direct_hit = true; bullet->finished = true; contacted.push_back(at); }
        }
        states[at] = !bullet->finished ? bullet->motion_state() : Dictionary();
    }
    Dictionary result; result["states"] = states; result["queries"] = queries; result["contacts"] = contacted;
    return result;
}
void godot::register_native_combat() { ClassDB::register_class<NativeCombatKernel>(); }
