#pragma once
#include "bullet_body.h"
#include "projectile_entry.h"
#include <unordered_map>
#include <vector>

namespace godot {
// Attacks read and update terrain synchronously, without script callbacks.
class NativeCombatKernel : public RefCounted {
    GDCLASS(NativeCombatKernel, RefCounted)
    struct Profile { double impact = 0, radius = 0, knock = 0; int damage = 0, blast_damage = 0; };
    struct OwnerMode { int64_t role = 0; bool rewinding = false; };
    struct QueryFrame {
        int64_t tick = -1;
        std::vector<ProjectileContactQuery> contacts;
        std::vector<OwnerMode> owners;
    };
    std::vector<QueryFrame> query_history;
    QueryFrame &query_frame(int64_t at);
    const QueryFrame *find_queries(int64_t at) const;
    void record_owner(QueryFrame &frame, int64_t role, bool rewinding);
    std::unordered_map<int64_t, Profile> profiles;
    Dictionary projectiles, blasts, beams, hits, ended, outcomes, hitboxes;
    uint64_t local_id = 0;
    int keep = 0, target_window = 0;
    double radius = 0, inner_fraction = 0, blocked_fraction = 0, beam_hit_mult = 0, step_delta = 0;
    int64_t tick = 0;
    Array players, notifications;
    Ref<NativeTerrain> geometry;
    bool first_prediction = false;
    NativeActorBody *local() const;
    std::vector<int64_t> attack_ids(const Dictionary &entries, int source, int64_t role = 0,
        const std::vector<int64_t> *candidates = nullptr) const;
    Dictionary confirmed_hit(int64_t id, int source, int64_t role) const;
    bool apply_confirmed_hits(int64_t id, int source, int64_t role = 0);
    void apply_hit(int64_t id, int source, NativeActorBody *target, Vector2 position, double force, int damage = 0);
    void remember_outcome(const Array &key, const Dictionary &value);
    void finish_direct(NativeBulletBody *bullet);
    NativeActorBody *contact(NativeBulletBody *bullet, bool point_only = false);
    void step_blast(int64_t id);
    void step_contacts(const std::vector<int64_t> &candidates);
    static void simulate_projectile(NativeBulletBody *bullet, double delta);
    static void reset_projectile(NativeProjectileEntry *entry, const Dictionary &state, int64_t at);
    static Vector2 path_contact(const PackedVector2Array &points, Rect2 rect, double corridor, Vector2 map_size);
protected:
    static void _bind_methods();
public:
    void configure(NativeActorBody *player, const Dictionary &sources, const Dictionary &weapon_profiles, const Dictionary &rules);
    void bind_hitboxes(const Dictionary &value) { hitboxes = value; }
    void begin_tick(int64_t at);
    void reset_queries();
    void discard_queries_after(int64_t at);
    void commit_catch_up(int64_t id, const Dictionary &plan);
    void step(int64_t at, const Array &targets, const Ref<NativeTerrain> &world, bool first);
    Array take_notifications();
    bool step_beams(int64_t at, int64_t role, const Array &targets, const Ref<NativeTerrain> &world);
    Dictionary confirmed_result_at(int64_t id, int64_t at, int source, int64_t role) const;
    bool proxy_queries_match(int64_t at, const Array &proxies, const Dictionary &actors, Vector2 map_size) const;
    Dictionary catch_up_remote(int64_t id, const Dictionary &history, int64_t through, double delta, Vector2 map_size);
};
void register_native_combat();
} // namespace godot
