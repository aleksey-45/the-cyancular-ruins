#pragma once

#include <deque>
#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/classes/rectangle_shape2d.hpp>
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/classes/tile_map_layer.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/rect2.hpp>
#include <map>
#include <set>
#include <vector>

namespace godot {

// Owns terrain data; exported containers are snapshots. The scene owns collision nodes.
class NativeTerrain : public RefCounted {
    GDCLASS(NativeTerrain, RefCounted)
    struct Material {
        int type = 0, hp = 1, ledge = 0;
        bool bullet = false, explosion = false, elastic = false;
        double climb = 0, descent = 0, decay = .75;
    };
    struct Pair {
        int before = 0, after = 0;
    };
    struct TickChanges {
        std::map<int, Pair> cells;
        Rect2 region;
        bool has_region = false;
    };
    struct CellState {
        int index = 0, value = 0, hp = 0;
        std::vector<int32_t> subs;
    };
    struct RewindEntry {
        double time = 0;
        std::vector<CellState> cells;
    };
    struct GeometryChange {
        int64_t revision = 0;
        Rect2 region;
    };
    struct Layout {
        std::vector<uint64_t> signature;
        std::vector<Rect2> rects;
    };
    struct Chunk {
        uint64_t body_id = 0;
        std::vector<uint64_t> current;
        std::deque<Layout> layouts;
        std::map<std::pair<int, int>, Ref<RectangleShape2D>> shapes;
    };
    struct BlastKernel {
        Vector2 position;
        int type = 0;
        double radius = 0;
        int damage = 0;
        int64_t tick = 0;
        std::vector<std::pair<int, int>> cells;
    };
    int columns = 0, rows = 0, sub_columns = 0, sub_rows = 0;
    int tile_size = 64, sub_size = 16, per_tile = 4, chunk_cells = 12, cache_states = 4;
    int wall_type = 0, liquid_type = 2, solid_code = 31, ledge_thickness = 6;
    double blast_inner = .4, blast_decay = .75;
    Vector2 map_size;
    std::vector<Material> materials;
    std::vector<int32_t> grid, initial_grid, textures, hp, initial_hp, tile_hp, initial_tile_hp;
    int64_t data_revision = 0, grid_revision = 0, tile_revision = 0;
    int64_t geometry_revision = 0, collision_revision = 0, revision = 0, generation = 0;
    bool authoritative = false, rewind_enabled = false, needs_state = false;
    int64_t floor_tick = -1, authority_tick = -1;
    std::map<int, int> base, authority, network_changes, modified;
    std::map<int64_t, TickChanges> prediction;
    std::map<int64_t, BlastKernel> blast_kernels;
    std::map<int, CellState> rewind_pending;
    std::deque<RewindEntry> rewind_entries;
    std::map<int64_t, int> rewards;
    std::set<int> visual_changes;
    std::map<int, Rect2> dirty;
    std::deque<GeometryChange> geometry_changes;
    uint64_t parent_id = 0;
    std::map<int, Chunk> chunks;
    bool permanent_dirty = true, ledges_dirty = true;
    Array grid_snapshot, subgrid_snapshot, tile_hp_snapshot;
    PackedInt32Array hp_snapshot;
    int64_t grid_snapshot_revision = -1, hp_snapshot_revision = -1, tile_snapshot_revision = -1;

    const Material &material(int texture) const;
    int sub_index(Vector2i at) const;
    Vector2i sub_position(int index) const;
    int macro_of(int index) const;
    void capture_before(int macro);
    CellState capture(int macro) const;
    void restore(const CellState &saved);
    bool write_hp(int index, int value, bool record, bool notify, int64_t owner = 0);
    void refresh_macro(int macro);
    void mark_collision(int index);
    void geometry_changed(Rect2 region);
    std::map<int, int> values_at(int64_t tick) const;
    bool matches(int64_t tick) const;
    std::vector<std::pair<int, int>> blast_cells(Vector2 center, double radius, int damage, bool include_dead) const;
    std::vector<Rect2> greedy(int x0, int y0, int x1, int y1, bool destructible) const;
    bool submit(Chunk &chunk, Node *parent, const String &name, const std::vector<uint64_t> &signature,
                const std::vector<Rect2> &rects, Rect2 region);
    bool rebuild(int chunk, Node *parent, Rect2 region);
    void rebuild_permanent(Node *parent);
    void rebuild_ledges(Node *parent);

  protected:
    static void _bind_methods();

  public:
    void configure(const Array &macro, const Array &subgrid, const Dictionary &definitions, const Dictionary &settings);
    bool empty() const { return columns == 0 || rows == 0; }
    Vector2 size() const { return map_size; }
    void set_empty_world_bounds(Vector2 bounds) {
        if (empty())
            map_size = bounds;
    }
    int get_sub_columns() const { return sub_columns; }
    int get_sub_rows() const { return sub_rows; }
    int64_t get_geometry_revision() const { return geometry_revision; }
    int64_t get_collision_revision() const { return collision_revision; }
    int64_t get_revision() const { return revision; }
    void set_revision(int64_t value) { revision = value; }
    int64_t get_generation() const { return generation; }
    bool get_needs_state() const { return needs_state; }
    void set_authoritative(bool value) { authoritative = value; }
    Vector2i cell(Vector2 position) const;
    int value(Vector2i cell) const;
    static int texture(int value) { return value / 16; }
    int sub_texture(Vector2i at) const;
    int get_hp(Vector2i at) const;
    bool sub_alive(Vector2i at) const { return get_hp(at) > 0; }
    Vector2i sub_of(Vector2 position) const;
    double climb_speed(int texture) const;
    double descent_speed(int texture) const;
    bool water(Vector2 position) const;
    double water_surface(Vector2 position) const;
    double water_multiplier(Vector2 position) const;
    bool line_of_sight(Vector2 from, Vector2 to) const;
    bool line_of_sight_cells(Vector2i from, Vector2i to) const;
    bool elastic_alive(Vector2 position) const;
    bool rect_overlaps(Rect2 bounds, double tile_size, bool with_liquid) const;
    int topmost_solid_row(Rect2 bounds, double tile_size) const;
    Dictionary trace_beam(Vector2 origin, Vector2 direction, double length, int bounces) const;
    Array get_grid_snapshot();
    Array get_subgrid_snapshot() const { return subgrid_snapshot; }
    Array get_tile_hp_snapshot();
    PackedInt32Array get_hp_snapshot();
    Array get_collision_snapshot(bool destructible) const;
    Dictionary capture_cell(Vector2i cell) const;
    bool damage_sub(Vector2i sub, int amount, int source, int64_t owner);
    int damage_impact(Vector2 position, Vector2 normal, int amount, int64_t owner);
    bool damage_tile(Vector2i cell, int amount, int source, int64_t owner);
    int damage_blast(Vector2 center, double radius, int damage, int64_t owner);
    Array destructible_subs(Vector2 center, double radius, bool include_dead) const;
    bool apply_hp(Vector2i sub, int value, int64_t owner);
    void restore_hp(Vector2i sub, int value);
    void apply_values(const Dictionary &values);
    void reset();
    Dictionary take_network_changes();
    Dictionary get_modified() const;
    Dictionary take_rewards();
    void attach(Node *parent);
    int flush_collisions();
    void flush_visuals(TileMapLayer *layer);
    void invalidate_chunk(Vector2i chunk);
    void invalidate_all();
    bool affects_since(int64_t revision, Rect2 bounds) const;
    int predict_blast(int64_t id, int type, Vector2 center, int64_t tick, double radius, int damage);
    void apply_authority(const Dictionary &patch);
    String difference(int64_t tick, int64_t saved_generation, int64_t map_revision) const;
    bool can_restore(int64_t tick, int64_t saved_generation) const;
    bool unchanged_since(int64_t tick, Rect2 bounds) const;
    void restore_checkpoint(int64_t tick);
    void acknowledge(int64_t tick);
    void prune_before(int64_t tick);
    void reset_prediction(int64_t tick);
    void set_rewind_enabled(bool enabled) { rewind_enabled = enabled; }
    void seal_rewind(double time);
    void rewind_between(double target, double cursor);
    void prune_rewind(double cutoff);
    void truncate_rewind(double time);
};

void register_native_terrain();

} // namespace godot
