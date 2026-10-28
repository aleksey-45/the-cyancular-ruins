#include "terrain.h"
#include <algorithm>
#include <chrono>
#include <cmath>
#include <godot_cpp/classes/collision_shape2d.hpp>
#include <godot_cpp/classes/static_body2d.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/object.hpp>

using namespace godot;
namespace {
int wrap(int value, int span) {
    const int n = value % span;
    return n < 0 ? n + span : n;
}
Vector2 delta(Vector2 a, Vector2 b, Vector2 size) {
    Vector2 d = b - a;
    for (int axis = 0; axis < 2; ++axis) {
        if (d[axis] > size[axis] * .5)
            d[axis] -= size[axis];
        else if (d[axis] < -size[axis] * .5)
            d[axis] += size[axis];
    }
    return d;
}
bool intersects_wrapped(Rect2 bounds, Rect2 region, Vector2 size) {
    for (int y = -1; y <= 1; ++y)
        for (int x = -1; x <= 1; ++x)
            if (bounds.intersects(Rect2(region.position + Vector2(x * size.x, y * size.y), region.size)))
                return true;
    return false;
}
} // namespace

void NativeTerrain::_bind_methods() {
#define BIND0(name) ClassDB::bind_method(D_METHOD(#name), &NativeTerrain::name)
#define BIND(name, ...) ClassDB::bind_method(D_METHOD(#name, __VA_ARGS__), &NativeTerrain::name)
    BIND(configure, "grid", "subgrid", "definitions", "settings");
    BIND0(empty);
    BIND0(size);
    BIND(set_empty_world_bounds, "bounds");
    BIND0(get_sub_columns);
    BIND0(get_sub_rows);
    BIND0(get_geometry_revision);
    BIND0(get_collision_revision);
    BIND0(get_revision);
    BIND(set_revision, "value");
    BIND0(get_generation);
    BIND0(get_needs_state);
    BIND(set_authoritative, "value");
    BIND(cell, "position");
    BIND(value, "cell");
    BIND(sub_of, "position");
    BIND(sub_texture, "sub");
    BIND(get_hp, "sub");
    BIND(sub_alive, "sub");
    BIND(water, "position");
    BIND(water_surface, "position");
    BIND(water_multiplier, "position");
    BIND(line_of_sight, "from", "to");
    BIND(line_of_sight_cells, "from", "to");
    BIND(rect_overlaps, "bounds", "tile_size", "with_liquid");
    BIND(topmost_solid_row, "bounds", "tile_size");
    BIND(trace_beam, "origin", "direction", "length", "bounces");
    BIND0(get_grid_snapshot);
    BIND0(get_subgrid_snapshot);
    BIND0(get_tile_hp_snapshot);
    BIND0(get_hp_snapshot);
    BIND(get_collision_snapshot, "destructible");
    BIND(capture_cell, "cell");
    BIND(damage_sub, "sub", "amount", "source", "owner");
    BIND(damage_impact, "position", "normal", "amount", "owner");
    BIND(damage_tile, "cell", "amount", "source", "owner");
    BIND(damage_blast, "center", "radius", "damage", "owner");
    BIND(destructible_subs, "center", "radius", "include_dead");
    BIND(apply_hp, "sub", "hp", "owner");
    BIND(restore_hp, "sub", "hp");
    BIND(apply_values, "values");
    BIND0(reset);
    BIND0(take_network_changes);
    BIND0(get_modified);
    BIND0(take_rewards);
    BIND(attach, "parent");
    BIND0(flush_collisions);
    BIND(set_collision_profiling, "enabled");
    BIND0(take_collision_profile);
    BIND(flush_visuals, "layer");
    BIND0(dirty_count);
    BIND(invalidate_chunk, "chunk");
    BIND0(invalidate_all);
    BIND(affects_since, "revision", "bounds");
    ClassDB::bind_method(D_METHOD("notify_geometry_changed", "region"), &NativeTerrain::geometry_changed);
    BIND(predict_blast, "id", "type", "center", "tick", "radius", "damage");
    BIND(apply_authority, "patch");
    BIND(difference, "tick", "generation", "revision");
    BIND(can_restore, "tick", "generation");
    BIND(unchanged_since, "tick", "bounds");
    BIND(restore_checkpoint, "tick");
    BIND(acknowledge, "tick");
    BIND(prune_before, "tick");
    BIND(reset_prediction, "tick");
    BIND0(pending_cells);
    BIND(prediction_cells_at, "tick");
    BIND0(history_stats);
    BIND(set_rewind_enabled, "enabled");
    BIND(seal_rewind, "time");
    BIND(rewind_between, "target", "cursor");
    BIND(prune_rewind, "cutoff");
    BIND(truncate_rewind, "time");
    BIND0(rewind_count);
    BIND0(pending_rewind_count);
    ADD_PROPERTY(PropertyInfo(Variant::INT, "revision"), "set_revision", "get_revision");
    ADD_PROPERTY(PropertyInfo(Variant::INT, "generation"), "", "get_generation");
    ADD_PROPERTY(PropertyInfo(Variant::BOOL, "needs_state"), "", "get_needs_state");
    ADD_SIGNAL(MethodInfo("changed"));
#undef BIND
#undef BIND0
}

void NativeTerrain::configure(const Array &macro, const Array &subgrid, const Dictionary &definitions,
                              const Dictionary &settings) {
    rows = macro.size();
    columns = rows ? Array(macro[0]).size() : 0;
    tile_size = settings.get("tile_size", 64);
    sub_size = settings.get("sub_size", 16);
    chunk_cells = settings.get("chunk_cells", 12);
    cache_states = settings.get("cache_states", 4);
    solid_code = settings.get("solid_code", 31);
    wall_type = settings.get("wall_type", 0);
    liquid_type = settings.get("liquid_type", 2);
    ledge_thickness = settings.get("ledge_thickness", 6);
    blast_inner = settings.get("blast_inner", .4);
    authoritative = settings.get("authoritative", false);
    ERR_FAIL_COND(tile_size <= 0 || sub_size <= 0 || tile_size % sub_size || chunk_cells <= 0 || cache_states <= 0);
    per_tile = tile_size / sub_size;
    ERR_FAIL_COND(chunk_cells * per_tile > 64);
    map_size = Vector2(columns * tile_size, rows * tile_size);
    blast_decay = definitions.get("explosion_decay", .75);
    const Dictionary tiles = definitions.get("tiles", Dictionary());
    int max_texture = 0;
    for (int y = 0; y < rows; ++y) {
        const Array row = macro[y];
        for (int x = 0; x < columns; ++x)
            max_texture = std::max(max_texture, texture(row[x]));
    }
    for (int y = 0; y < subgrid.size(); ++y) {
        const Array row = subgrid[y];
        for (int x = 0; x < row.size(); ++x)
            max_texture = std::max(max_texture, int(row[x]));
    }
    const Array keys = tiles.keys();
    for (int i = 0; i < keys.size(); ++i)
        max_texture = std::max(max_texture, int(String(keys[i]).to_int()));
    materials.assign(size_t(max_texture) + 1, Material());
    for (int i = 0; i <= max_texture; ++i) {
        const Dictionary d = tiles.get(String::num_int64(i), Dictionary());
        Material &m = materials[size_t(i)];
        const String type = d.get("type", "wall");
        m.type = type == "wall" ? wall_type : type == "liquid" ? liquid_type : type == "passage" ? 1 : 3;
        m.hp = d.get("hp", 1);
        m.bullet = d.get("bullet_destroyable", false);
        m.explosion = d.get("explosion_destroyable", false);
        m.elastic = d.get("elastic", false);
        m.climb = d.get("climb_speed", 0.0);
        m.descent = d.get("climb_descent_speed", 0.0);
        m.decay = d.get("explosion_decay", blast_decay);
        m.ledge = d.get("collision_ledge", 0);
    }
    grid.resize(size_t(columns) * rows);
    tile_hp.resize(grid.size());
    for (int y = 0; y < rows; ++y) {
        const Array row = macro[y];
        for (int x = 0; x < columns; ++x) {
            const int i = y * columns + x;
            grid[i] = row[x];
            tile_hp[i] = material(texture(grid[i])).hp;
        }
    }
    sub_rows = subgrid.is_empty() ? rows * per_tile : subgrid.size();
    sub_columns = subgrid.is_empty() ? columns * per_tile : Array(subgrid[0]).size();
    textures.resize(size_t(sub_rows) * sub_columns);
    hp.resize(textures.size());
    TypedArray<Array> texture_rows;
    for (int y = 0; y < sub_rows; ++y) {
        Array snapshot_row;
        const Array row = subgrid.is_empty() ? Array() : Array(subgrid[y]);
        for (int x = 0; x < sub_columns; ++x) {
            int tex = 0;
            if (!subgrid.is_empty())
                tex = row[x];
            else if (y / per_tile < rows && x / per_tile < columns) {
                const int packed = grid[(y / per_tile) * columns + x / per_tile];
                const int quadrant = (y % per_tile) / (per_tile / 2) * 2 + (x % per_tile) / (per_tile / 2);
                if (packed & (1 << quadrant))
                    tex = texture(packed);
            }
            const int i = y * sub_columns + x;
            textures[i] = tex;
            hp[i] = tex ? material(tex).hp : 0;
            snapshot_row.push_back(tex);
        }
        snapshot_row.make_read_only();
        texture_rows.push_back(snapshot_row);
    }
    texture_rows.make_read_only();
    subgrid_snapshot = texture_rows;
    initial_grid = grid;
    initial_hp = hp;
    initial_tile_hp = tile_hp;
    base.clear();
    authority.clear();
    prediction.clear();
    blast_kernels.clear();
    kernel_builds = 0;
    collision_us = collision_chunks = 0;
    network_changes.clear();
    modified.clear();
    rewards.clear();
    rewind_pending.clear();
    rewind_entries.clear();
    rewind_enabled = false;
    visual_changes.clear();
    dirty.clear();
    revision = 0;
    floor_tick = authority_tick = -1;
    needs_state = false;
    ++generation;
    ++data_revision;
    ++collision_revision;
    permanent_dirty = ledges_dirty = true;
    chunks.clear();
    geometry_changes.clear();
    ++geometry_revision;
    ++grid_revision;
    ++tile_revision;
    grid_snapshot_revision = hp_snapshot_revision = tile_snapshot_revision = -1;
}

const NativeTerrain::Material &NativeTerrain::material(int tex) const {
    static const Material fallback;
    return tex >= 0 && tex < int(materials.size()) ? materials[size_t(tex)] : fallback;
}
int NativeTerrain::sub_index(Vector2i at) const {
    return at.x < 0 || at.y < 0 || at.x >= sub_columns || at.y >= sub_rows ? -1 : at.y * sub_columns + at.x;
}
Vector2i NativeTerrain::sub_position(int i) const {
    return Vector2i(i % sub_columns, i / sub_columns);
}
int NativeTerrain::macro_of(int i) const {
    return (i / sub_columns / per_tile) * columns + (i % sub_columns / per_tile);
}
Vector2i NativeTerrain::cell(Vector2 position) const {
    return empty() ? Vector2i()
                   : Vector2i(wrap(int(std::floor(position.x / tile_size)), columns),
                              wrap(int(std::floor(position.y / tile_size)), rows));
}
int NativeTerrain::value(Vector2i at) const {
    return empty() ? 0 : grid[wrap(at.y, rows) * columns + wrap(at.x, columns)];
}
int NativeTerrain::sub_texture(Vector2i at) const {
    const int i = sub_index(at);
    return i < 0 ? 0 : textures[i];
}
int NativeTerrain::get_hp(Vector2i at) const {
    const int i = sub_index(at);
    return i < 0 ? 0 : hp[i];
}
Vector2i NativeTerrain::sub_of(Vector2 position) const {
    return sub_columns && sub_rows ? Vector2i(wrap(int(std::floor(position.x / sub_size)), sub_columns),
                                              wrap(int(std::floor(position.y / sub_size)), sub_rows))
                                   : Vector2i();
}
double NativeTerrain::climb_speed(int tex) const {
    return material(tex).climb;
}
double NativeTerrain::descent_speed(int tex) const {
    return material(tex).descent;
}
bool NativeTerrain::water(Vector2 position) const {
    const int v = value(cell(position));
    return v && material(texture(v)).type == liquid_type;
}
double NativeTerrain::water_surface(Vector2 position) const {
    if (!water(position))
        return position.y;
    const Vector2i at = cell(position);
    int top = at.y;
    for (int n = 0; n < rows; ++n) {
        const int above = wrap(top - 1, rows), v = value(Vector2i(at.x, above));
        if (!v || material(texture(v)).type != liquid_type)
            return top * tile_size;
        top = above;
    }
    return 0;
}
double NativeTerrain::water_multiplier(Vector2 position) const {
    return water(position) ? material(texture(value(cell(position)))).decay : 1;
}
bool NativeTerrain::line_of_sight(Vector2 from, Vector2 to) const {
    return line_of_sight_cells(cell(from), cell(to));
}
bool NativeTerrain::line_of_sight_cells(Vector2i from, Vector2i to) const {
    if (empty())
        return false;
    const Vector2i a(wrap(from.x, columns), wrap(from.y, rows)), b(wrap(to.x, columns), wrap(to.y, rows));
    int dx = b.x - a.x, dy = b.y - a.y;
    if (dx > columns / 2)
        dx -= columns;
    else if (dx < -columns / 2)
        dx += columns;
    if (dy > rows / 2)
        dy -= rows;
    else if (dy < -rows / 2)
        dy += rows;
    if (!dx && !dy)
        return true;
    int x = a.x, y = a.y;
    const int sx = dx > 0 ? 1 : -1, sy = dy > 0 ? 1 : -1;
    dx = std::abs(dx);
    dy = std::abs(dy);
    int error = dx - dy;
    while (true) {
        const int v = value(Vector2i(x, y));
        if (v && material(texture(v)).type == wall_type)
            return false;
        if (x == b.x && y == b.y)
            break;
        const int twice = 2 * error;
        if (twice > -dy) {
            error -= dy;
            x = wrap(x + sx, columns);
        }
        if (twice < dx) {
            error += dx;
            y = wrap(y + sy, rows);
        }
    }
    return true;
}
bool NativeTerrain::elastic_alive(Vector2 position) const {
    const int i = sub_index(sub_of(position));
    return i >= 0 && hp[i] > 0 && material(textures[i]).elastic;
}

Array NativeTerrain::get_grid_snapshot() {
    if (grid_snapshot_revision == grid_revision)
        return grid_snapshot;
    TypedArray<Array> result;
    for (int y = 0; y < rows; ++y) {
        Array row;
        for (int x = 0; x < columns; ++x)
            row.push_back(grid[y * columns + x]);
        row.make_read_only();
        result.push_back(row);
    }
    result.make_read_only();
    grid_snapshot = result;
    grid_snapshot_revision = grid_revision;
    return grid_snapshot;
}
Array NativeTerrain::get_tile_hp_snapshot() {
    if (tile_snapshot_revision == tile_revision)
        return tile_hp_snapshot;
    TypedArray<Array> result;
    for (int y = 0; y < rows; ++y) {
        Array row;
        for (int x = 0; x < columns; ++x)
            row.push_back(tile_hp[y * columns + x]);
        row.make_read_only();
        result.push_back(row);
    }
    result.make_read_only();
    tile_hp_snapshot = result;
    tile_snapshot_revision = tile_revision;
    return tile_hp_snapshot;
}
PackedInt32Array NativeTerrain::get_hp_snapshot() {
    if (hp_snapshot_revision != data_revision) {
        hp_snapshot.resize(hp.size());
        int32_t *out = hp_snapshot.ptrw();
        std::copy(hp.begin(), hp.end(), out);
        hp_snapshot_revision = data_revision;
    }
    return hp_snapshot;
}
Array NativeTerrain::get_collision_snapshot(bool destructible) const {
    TypedArray<Array> out;
    for (int y = 0; y < sub_rows; ++y) {
        Array row;
        for (int x = 0; x < sub_columns; ++x) {
            const int i = y * sub_columns + x;
            const Material &m = material(textures[i]);
            row.push_back(hp[i] > 0 && m.type == wall_type && (m.bullet || m.explosion) == destructible ? solid_code
                                                                                                        : 0);
        }
        row.make_read_only();
        out.push_back(row);
    }
    out.make_read_only();
    return out;
}
NativeTerrain::CellState NativeTerrain::capture(int at) const {
    CellState s;
    s.index = at;
    s.value = grid[at];
    s.hp = tile_hp[at];
    s.subs.reserve(per_tile * per_tile);
    for (int y = 0; y < per_tile; ++y)
        for (int x = 0; x < per_tile; ++x) {
            const int i = sub_index(Vector2i((at % columns) * per_tile + x, (at / columns) * per_tile + y));
            s.subs.push_back(i >= 0 ? hp[i] : 0);
        }
    return s;
}
void NativeTerrain::capture_before(int at) {
    if (rewind_enabled && !rewind_pending.count(at))
        rewind_pending.emplace(at, capture(at));
}
Dictionary NativeTerrain::capture_cell(Vector2i at) const {
    if (at.x < 0 || at.y < 0 || at.x >= columns || at.y >= rows)
        return Dictionary();
    const CellState s = capture(at.y * columns + at.x);
    PackedInt32Array subs;
    subs.resize(s.subs.size());
    std::copy(s.subs.begin(), s.subs.end(), subs.ptrw());
    Dictionary d;
    d["cell"] = at;
    d["tile"] = s.value;
    d["hp"] = s.hp;
    d["subs"] = subs;
    return d;
}
void NativeTerrain::restore(const CellState &s) {
    for (int y = 0; y < per_tile; ++y)
        for (int x = 0; x < per_tile; ++x) {
            const int i = sub_index(Vector2i((s.index % columns) * per_tile + x, (s.index / columns) * per_tile + y));
            const int offset = y * per_tile + x;
            if (i >= 0 && offset < int(s.subs.size()))
                write_hp(i, s.subs[offset], false, false);
        }
    if (grid[s.index] != s.value) {
        ledges_dirty = ledges_dirty || material(texture(grid[s.index])).ledge || material(texture(s.value)).ledge;
        grid[s.index] = s.value;
        ++grid_revision;
    }
    if (tile_hp[s.index] != s.hp) {
        tile_hp[s.index] = s.hp;
        ++tile_revision;
    }
}
void NativeTerrain::refresh_macro(int at) {
    const int x0 = (at % columns) * per_tile, y0 = (at / columns) * per_tile;
    bool alive = false;
    for (int y = y0; y < std::min(y0 + per_tile, sub_rows) && !alive; ++y)
        for (int x = x0; x < std::min(x0 + per_tile, sub_columns); ++x)
            if (hp[y * sub_columns + x] > 0) {
                alive = true;
                break;
            }
    const int next = alive ? initial_grid[at] : 0;
    if (grid[at] != next) {
        grid[at] = next;
        ++grid_revision;
        ledges_dirty = ledges_dirty || material(texture(initial_grid[at])).ledge;
    }
}
void NativeTerrain::mark_collision(int index) {
    const Vector2i sub = sub_position(index),
                   chunk = Vector2i(sub.x / (chunk_cells * per_tile), sub.y / (chunk_cells * per_tile));
    const int key = chunk.y * ((columns + chunk_cells - 1) / chunk_cells) + chunk.x;
    const Rect2 region(Vector2(sub * sub_size), Vector2(sub_size, sub_size));
    auto found = dirty.find(key);
    if (found == dirty.end())
        dirty.emplace(key, region);
    else if (found->second.has_area())
        found->second = found->second.merge(region);
    const Material &m = material(textures[index]);
    if (m.type == wall_type && !m.bullet && !m.explosion)
        permanent_dirty = true;
}
bool NativeTerrain::write_hp(int index, int next, bool record, bool notify, int64_t owner) {
    next = std::max(0, next);
    const int before = hp[index];
    if (before == next)
        return false;
    const int macro = macro_of(index);
    if (record)
        capture_before(macro);
    hp[index] = next;
    ++data_revision;
    if (notify && authoritative) {
        network_changes[index] = next;
        modified[index] = next;
        ++revision;
    }
    if ((before > 0) != (next > 0)) {
        ++collision_revision;
        visual_changes.insert(index);
        mark_collision(index);
        refresh_macro(macro);
        if (notify && before > 0 && next == 0 && owner > 0)
            ++rewards[owner];
    }
    return true;
}
bool NativeTerrain::damage_sub(Vector2i at, int amount, int source, int64_t owner) {
    const int i = sub_index(at);
    if (i < 0 || !textures[i] || hp[i] <= 0 || amount <= 0)
        return false;
    const Material &m = material(textures[i]);
    if (!(source == 0 ? m.bullet : m.explosion))
        return false;
    const bool changed = write_hp(i, hp[i] - amount, true, true, owner);
    if (changed)
        emit_signal("changed");
    return changed && hp[i] == 0;
}
int NativeTerrain::damage_impact(Vector2 position, Vector2 normal, int amount, int64_t owner) {
    if (empty())
        return 0;
    for (int probe = 0; probe < 3; ++probe) {
        const Vector2i at = sub_of(position - normal * (probe * sub_size * .5));
        const int tex = sub_texture(at);
        if (tex && material(tex).bullet) {
            if (amount > 0)
                damage_sub(at, amount, 0, owner);
            return tex;
        }
    }
    return 0;
}
bool NativeTerrain::damage_tile(Vector2i at, int amount, int source, int64_t owner) {
    if (at.x < 0 || at.y < 0 || at.x >= columns || at.y >= rows || amount <= 0)
        return false;
    const int i = at.y * columns + at.x;
    if (!grid[i])
        return false;
    const Material &m = material(texture(grid[i]));
    if (!(source == 0 ? m.bullet : m.explosion))
        return false;
    capture_before(i);
    tile_hp[i] = std::max(0, tile_hp[i] - amount);
    ++tile_revision;
    if (tile_hp[i] > 0)
        return false;
    for (int y = 0; y < per_tile; ++y)
        for (int x = 0; x < per_tile; ++x) {
            const int n = sub_index(at * per_tile + Vector2i(x, y));
            if (n < 0)
                continue;
            const Material &part = material(textures[n]);
            if (source == 0 ? part.bullet : part.explosion)
                write_hp(n, 0, false, true, owner);
        }
    refresh_macro(i);
    emit_signal("changed");
    return grid[i] == 0;
}
std::vector<std::pair<int, int>> NativeTerrain::blast_cells(Vector2 center, double radius, int damage,
                                                            bool include_dead) const {
    std::vector<std::pair<int, int>> out;
    if (sub_columns == 0 || sub_rows == 0 || radius <= 0)
        return out;
    const Vector2i at = sub_of(center);
    const int reach = int(std::ceil(radius / sub_size)) + 1;
    const int width = std::min(2 * reach + 1, sub_columns), height = std::min(2 * reach + 1, sub_rows);
    for (int y = -reach; y < -reach + height; ++y)
        for (int x = -reach; x < -reach + width; ++x) {
            const int sx = wrap(at.x + x, sub_columns), sy = wrap(at.y + y, sub_rows), i = sy * sub_columns + sx;
            if (!textures[i] || (!include_dead && hp[i] <= 0) || !material(textures[i]).explosion)
                continue;
            const double d = delta(center, Vector2((sx + .5) * sub_size, (sy + .5) * sub_size), map_size).length();
            if (d > radius)
                continue;
            const double inner = radius * blast_inner, t = (d - inner) / (radius - inner);
            const int amount = int((d < inner ? damage : d >= radius ? 0 : damage * (1 - t * t)) * blast_decay);
            out.emplace_back(i, amount);
        }
    return out;
}
Array NativeTerrain::destructible_subs(Vector2 center, double radius, bool include_dead) const {
    Array out;
    for (const auto &entry : blast_cells(center, radius, 0, include_dead)) {
        const Vector2i sub = sub_position(entry.first);
        const Vector2 pos = Vector2(sub * sub_size) + Vector2(sub_size * .5, sub_size * .5);
        Dictionary d;
        d["sub"] = sub;
        d["pos"] = pos;
        d["tex"] = textures[entry.first];
        d["d"] = delta(center, pos, map_size).length();
        out.push_back(d);
    }
    return out;
}
int NativeTerrain::damage_blast(Vector2 center, double radius, int damage, int64_t owner) {
    int changed = 0;
    for (const auto &entry : blast_cells(center, radius, damage, false))
        if (entry.second > 0)
            changed += write_hp(entry.first, hp[entry.first] - entry.second, true, true, owner);
    if (changed)
        emit_signal("changed");
    return changed;
}
bool NativeTerrain::apply_hp(Vector2i at, int value, int64_t owner) {
    const int i = sub_index(at);
    if (i < 0)
        return false;
    const bool changed = write_hp(i, value, true, true, owner);
    if (changed)
        emit_signal("changed");
    return changed && hp[i] == 0;
}
void NativeTerrain::restore_hp(Vector2i at, int value) {
    const int i = sub_index(at);
    if (i >= 0)
        write_hp(i, value, false, false);
}
void NativeTerrain::apply_values(const Dictionary &values) {
    const Array keys = values.keys();
    for (int i = 0; i < keys.size(); ++i) {
        const Vector2i at = keys[i];
        const int n = sub_index(at);
        if (n >= 0)
            write_hp(n, values[at], false, false);
    }
}
void NativeTerrain::reset() {
    const bool recording = rewind_enabled;
    rewind_enabled = false;
    for (int i = 0; i < int(hp.size()); ++i)
        write_hp(i, initial_hp[i], false, false);
    grid = initial_grid;
    tile_hp = initial_tile_hp;
    base.clear();
    authority.clear();
    prediction.clear();
    blast_kernels.clear();
    network_changes.clear();
    modified.clear();
    rewards.clear();
    rewind_pending.clear();
    rewind_entries.clear();
    revision = authoritative ? revision + 1 : 0;
    floor_tick = authority_tick = -1;
    needs_state = false;
    ++generation;
    ++data_revision;
    ++grid_revision;
    ++tile_revision;
    rewind_enabled = recording;
    flush_collisions();
}
Dictionary NativeTerrain::take_network_changes() {
    Dictionary out;
    for (const auto &p : network_changes)
        out[sub_position(p.first)] = p.second;
    network_changes.clear();
    return out;
}
Dictionary NativeTerrain::get_modified() const {
    Dictionary out;
    for (const auto &p : modified)
        out[sub_position(p.first)] = p.second;
    return out;
}
Dictionary NativeTerrain::take_rewards() {
    Dictionary out;
    for (const auto &p : rewards)
        out[p.first] = p.second;
    rewards.clear();
    return out;
}

void NativeTerrain::geometry_changed(Rect2 region) {
    ++geometry_revision;
    geometry_changes.push_back({geometry_revision, region});
    if (geometry_changes.size() > 128)
        geometry_changes.pop_front();
}
bool NativeTerrain::affects_since(int64_t previous, Rect2 bounds) const {
    if (previous == geometry_revision)
        return false;
    if (geometry_changes.empty() || previous < geometry_changes.front().revision - 1)
        return true;
    for (const GeometryChange &change : geometry_changes)
        if (change.revision > previous &&
            (!change.region.has_area() || intersects_wrapped(bounds, change.region, map_size)))
            return true;
    return false;
}
std::vector<Rect2> NativeTerrain::greedy(int x0, int y0, int x1, int y1, bool destructible) const {
    const int width = x1 - x0, height = y1 - y0;
    std::vector<uint8_t> occupied(size_t(width) * height), used(occupied.size());
    for (int y = y0; y < y1; ++y)
        for (int x = x0; x < x1; ++x) {
            const int i = y * sub_columns + x;
            const Material &m = material(textures[i]);
            occupied[(y - y0) * width + x - x0] =
                hp[i] > 0 && m.type == wall_type && (m.bullet || m.explosion) == destructible;
        }
    std::vector<Rect2> result;
    for (int y = y0; y < y1; ++y)
        for (int x = x0; x < x1; ++x) {
            const int i = (y - y0) * width + x - x0;
            if (!occupied[i] || used[i])
                continue;
            int x2 = x, y2 = y;
            while (x2 + 1 < x1 && occupied[(y - y0) * width + x2 + 1 - x0] && !used[(y - y0) * width + x2 + 1 - x0])
                ++x2;
            while (y2 + 1 < y1) {
                bool can = true;
                for (int cx = x; cx <= x2; ++cx) {
                    const int n = (y2 + 1 - y0) * width + cx - x0;
                    if (!occupied[n] || used[n]) {
                        can = false;
                        break;
                    }
                }
                if (!can)
                    break;
                ++y2;
            }
            for (int ry = y; ry <= y2; ++ry)
                for (int rx = x; rx <= x2; ++rx)
                    used[(ry - y0) * width + rx - x0] = 1;
            result.emplace_back(Vector2((x + x2 + 1) * sub_size * .5, (y + y2 + 1) * sub_size * .5),
                                Vector2((x2 - x + 1) * sub_size, (y2 - y + 1) * sub_size));
        }
    return result;
}
bool NativeTerrain::submit(Chunk &chunk, Node *parent, const String &name, const std::vector<uint64_t> &signature,
                           const std::vector<Rect2> &rects, Rect2 region) {
    StaticBody2D *body = Object::cast_to<StaticBody2D>(ObjectDB::get_instance(chunk.body_id));
    if (body && chunk.current == signature)
        return false;
    if (!body) {
        body = Object::cast_to<StaticBody2D>(parent->get_node_or_null(NodePath(name)));
        if (!body) {
            body = memnew(StaticBody2D);
            body->set_name(name);
            parent->add_child(body);
        }
        chunk.body_id = uint64_t(body->get_instance_id());
    }
    const Array children = body->get_children();
    int total = 0;
    for (const Rect2 &rect : rects) {
        const auto key = std::make_pair(int(rect.size.x), int(rect.size.y));
        Ref<RectangleShape2D> shape;
        auto found = chunk.shapes.find(key);
        if (found == chunk.shapes.end()) {
            if (chunk.shapes.size() >= 64)
                chunk.shapes.clear();
            shape.instantiate();
            shape->set_size(rect.size);
            chunk.shapes.emplace(key, shape);
        } else
            shape = found->second;
        for (int y = -1; y <= 1; ++y)
            for (int x = -1; x <= 1; ++x) {
                CollisionShape2D *node = nullptr;
                if (total < children.size())
                    node = Object::cast_to<CollisionShape2D>(children[total]);
                if (!node) {
                    node = memnew(CollisionShape2D);
                    body->add_child(node);
                }
                if (node->get_shape() != shape)
                    node->set_shape(shape);
                const Vector2 position = rect.position + Vector2(x * map_size.x, y * map_size.y);
                if (node->get_position() != position)
                    node->set_position(position);
                ++total;
            }
    }
    for (int i = total; i < children.size(); ++i) {
        Object *object = children[i];
        Node *node = Object::cast_to<Node>(object);
        if (node)
            memdelete(node);
    }
    chunk.current = signature;
    geometry_changed(region);
    return true;
}
bool NativeTerrain::rebuild(int key, Node *parent, Rect2 region) {
    const int count = (columns + chunk_cells - 1) / chunk_cells, span = chunk_cells * per_tile;
    const int x0 = (key % count) * span, y0 = (key / count) * span, x1 = std::min(x0 + span, sub_columns),
              y1 = std::min(y0 + span, sub_rows);
    std::vector<uint64_t> signature{uint64_t(sub_columns), uint64_t(sub_rows), uint64_t(sub_size)};
    for (int y = y0; y < y1; ++y) {
        uint64_t bits = 0;
        for (int x = x0; x < x1; ++x) {
            const int i = y * sub_columns + x;
            const Material &m = material(textures[i]);
            if (hp[i] > 0 && m.type == wall_type && (m.bullet || m.explosion))
                bits |= uint64_t(1) << (x - x0);
        }
        signature.push_back(bits);
    }
    Chunk &chunk = chunks[key];
    const Layout *selected = nullptr;
    for (const Layout &layout : chunk.layouts)
        if (layout.signature == signature) {
            selected = &layout;
            break;
        }
    if (!selected) {
        chunk.layouts.push_back({signature, greedy(x0, y0, x1, y1, true)});
        if (chunk.layouts.size() > size_t(cache_states))
            chunk.layouts.pop_front();
        selected = &chunk.layouts.back();
    }
    if (!region.has_area())
        region = Rect2(Vector2(x0 * sub_size, y0 * sub_size), Vector2((x1 - x0) * sub_size, (y1 - y0) * sub_size));
    const String name =
        String("DestructibleChunk_") + String::num_int64(key % count) + "_" + String::num_int64(key / count);
    return submit(chunk, parent, name, signature, selected->rects, region);
}
void NativeTerrain::rebuild_permanent(Node *parent) {
    std::vector<uint64_t> signature{uint64_t(sub_columns), uint64_t(sub_rows), uint64_t(sub_size)};
    uint64_t bits = 0;
    int bit = 0;
    for (int i = 0; i < int(hp.size()); ++i) {
        const Material &m = material(textures[i]);
        if (hp[i] > 0 && m.type == wall_type && !m.bullet && !m.explosion)
            bits |= uint64_t(1) << bit;
        if (++bit == 64) {
            signature.push_back(bits);
            bits = 0;
            bit = 0;
        }
    }
    if (bit)
        signature.push_back(bits);
    Chunk &chunk = chunks[-1];
    if (!ObjectDB::get_instance(chunk.body_id) || chunk.current != signature)
        submit(chunk, parent, "WallCollision", signature, greedy(0, 0, sub_columns, sub_rows, false), Rect2());
    permanent_dirty = false;
}
void NativeTerrain::rebuild_ledges(Node *parent) {
    std::vector<Rect2> rects;
    std::vector<uint64_t> signature{uint64_t(columns), uint64_t(rows), uint64_t(ledge_thickness)};
    for (int i = 0; i < int(grid.size()); ++i) {
        const int side = grid[i] ? material(texture(grid[i])).ledge : 0;
        if (!side)
            continue;
        signature.push_back((uint64_t(i) << 1) | uint64_t(side < 0));
        const int x = i % columns, y = i / columns;
        rects.emplace_back(Vector2((x + .5) * tile_size, side > 0 ? y * tile_size + ledge_thickness * .5
                                                                  : (y + 1) * tile_size - ledge_thickness * .5),
                           Vector2(tile_size, ledge_thickness));
    }
    submit(chunks[-2], parent, "ClimbLedges", signature, rects, Rect2());
    ledges_dirty = false;
}
void NativeTerrain::attach(Node *parent) {
    ERR_FAIL_NULL(parent);
    const uint64_t id = uint64_t(parent->get_instance_id());
    if (parent_id != id) {
        chunks.clear();
        parent_id = id;
    }
    permanent_dirty = ledges_dirty = true;
    invalidate_all();
    flush_collisions();
}
int NativeTerrain::flush_collisions() {
    if (dirty.empty() && !permanent_dirty && !ledges_dirty)
        return 0;
    Node *parent = Object::cast_to<Node>(ObjectDB::get_instance(parent_id));
    if (!parent || empty())
        return 0;
    const auto started =
        profile_collisions ? std::chrono::steady_clock::now() : std::chrono::steady_clock::time_point();
    if (permanent_dirty)
        rebuild_permanent(parent);
    if (ledges_dirty)
        rebuild_ledges(parent);
    const int count = dirty.size();
    for (const auto &entry : dirty)
        rebuild(entry.first, parent, entry.second);
    dirty.clear();
    if (profile_collisions) {
        collision_chunks += count;
        collision_us +=
            std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now() - started).count();
    }
    return count;
}
PackedInt64Array NativeTerrain::take_collision_profile() {
    PackedInt64Array result;
    result.push_back(collision_us);
    result.push_back(collision_chunks);
    collision_us = collision_chunks = 0;
    return result;
}
void NativeTerrain::flush_visuals(TileMapLayer *layer) {
    if (!layer)
        return;
    for (int i : visual_changes) {
        const Vector2i sub = sub_position(i), atlas((sub.y % per_tile) * per_tile + sub.x % per_tile, textures[i] - 1);
        for (int y = -1; y <= 1; ++y)
            for (int x = -1; x <= 1; ++x) {
                const Vector2i at = sub + Vector2i(x * sub_columns, y * sub_rows);
                if (hp[i] > 0) {
                    if (layer->get_cell_source_id(at) != 0 || layer->get_cell_atlas_coords(at) != atlas)
                        layer->set_cell(at, 0, atlas);
                } else if (layer->get_cell_source_id(at) != -1)
                    layer->erase_cell(at);
            }
    }
    visual_changes.clear();
}
void NativeTerrain::invalidate_chunk(Vector2i at) {
    const int count = (columns + chunk_cells - 1) / chunk_cells;
    if (at.x < 0 || at.y < 0 || at.x >= count || at.y >= (rows + chunk_cells - 1) / chunk_cells)
        return;
    dirty[at.y * count + at.x] = Rect2();
}
void NativeTerrain::invalidate_all() {
    permanent_dirty = ledges_dirty = true;
    for (int y = 0; y < (rows + chunk_cells - 1) / chunk_cells; ++y)
        for (int x = 0; x < (columns + chunk_cells - 1) / chunk_cells; ++x)
            invalidate_chunk(Vector2i(x, y));
}

std::map<int, int> NativeTerrain::values_at(int64_t at) const {
    auto values = base;
    for (const auto &entry : prediction) {
        if (entry.first > at)
            break;
        for (const auto &cell : entry.second.cells)
            values[cell.first] = cell.second.after;
    }
    return values;
}
bool NativeTerrain::matches(int64_t at) const {
    return at >= std::max(floor_tick, authority_tick) && values_at(at) == authority;
}
int NativeTerrain::predict_blast(int64_t id, int type, Vector2 center, int64_t tick, double radius, int damage) {
    BlastKernel &kernel = blast_kernels[id];
    if (kernel.position != center || kernel.type != type || kernel.radius != radius || kernel.damage != damage) {
        kernel.position = center;
        kernel.type = type;
        kernel.radius = radius;
        kernel.damage = damage;
        kernel.cells = blast_cells(center, radius, damage, true);
        ++kernel_builds;
    }
    kernel.tick = tick;
    TickChanges &changes = prediction[tick];
    int count = 0;
    for (const auto &cell : kernel.cells) {
        const int i = cell.first, before = hp[i];
        if (before <= 0 || cell.second <= 0)
            continue;
        if (!base.count(i)) {
            base[i] = before;
            authority[i] = before;
        }
        const int after = std::max(0, before - cell.second);
        auto found = changes.cells.find(i);
        if (found == changes.cells.end())
            changes.cells.emplace(i, Pair{before, after});
        else
            found->second.after = after;
        const Rect2 region(Vector2(sub_position(i) * sub_size), Vector2(sub_size, sub_size));
        changes.region = changes.has_region ? changes.region.merge(region) : region;
        changes.has_region = true;
        count += write_hp(i, after, false, false);
    }
    if (changes.cells.empty())
        prediction.erase(tick);
    return count;
}
void NativeTerrain::apply_authority(const Dictionary &patch) {
    const int64_t tick = patch["tick"];
    const Dictionary cells = patch["cells"];
    const Array keys = cells.keys();
    for (int n = 0; n < keys.size(); ++n) {
        const Vector2i at = keys[n];
        const int i = sub_index(at);
        if (i < 0)
            continue;
        if (!base.count(i)) {
            base[i] = hp[i];
            authority[i] = hp[i];
        }
        int next = cells[at];
        authority[i] = next;
        for (const auto &entry : prediction)
            if (entry.first > tick) {
                auto found = entry.second.cells.find(i);
                if (found != entry.second.cells.end())
                    next = std::max(0, next - (found->second.before - found->second.after));
            }
        write_hp(i, next, false, false);
    }
    authority_tick = std::max(authority_tick, tick);
    revision = patch["revision"];
    needs_state = !matches(authority_tick);
}
String NativeTerrain::difference(int64_t tick, int64_t saved_generation, int64_t map_revision) const {
    if (saved_generation != generation || tick < floor_tick)
        return "terrain_history";
    if (map_revision != revision || tick < authority_tick)
        return "map_revision";
    return matches(tick) ? String() : String("terrain_state");
}
bool NativeTerrain::can_restore(int64_t tick, int64_t saved_generation) const {
    return saved_generation == generation && tick >= std::max(floor_tick, authority_tick) && !needs_state;
}
bool NativeTerrain::unchanged_since(int64_t tick, Rect2 bounds) const {
    if (needs_state || tick < std::max(floor_tick, authority_tick))
        return false;
    for (const auto &entry : prediction)
        if (entry.first > tick &&
            (!entry.second.has_region || intersects_wrapped(bounds, entry.second.region, map_size)))
            return false;
    return true;
}
void NativeTerrain::restore_checkpoint(int64_t tick) {
    for (const auto &entry : values_at(tick))
        write_hp(entry.first, entry.second, false, false);
    prediction.erase(prediction.upper_bound(tick), prediction.end());
    flush_collisions();
}
void NativeTerrain::acknowledge(int64_t tick) {
    floor_tick = tick;
    base = authority;
    prediction.erase(prediction.begin(), prediction.upper_bound(tick));
    for (auto it = blast_kernels.begin(); it != blast_kernels.end();)
        if (it->second.tick <= tick)
            it = blast_kernels.erase(it);
        else
            ++it;
    std::set<int> future;
    for (const auto &entry : prediction)
        for (const auto &cell : entry.second.cells)
            future.insert(cell.first);
    for (auto it = base.begin(); it != base.end();)
        if (!future.count(it->first)) {
            authority.erase(it->first);
            it = base.erase(it);
        } else
            ++it;
    needs_state = false;
}
void NativeTerrain::prune_before(int64_t tick) {
    if (tick <= floor_tick)
        return;
    base = values_at(tick);
    floor_tick = tick;
    prediction.erase(prediction.begin(), prediction.upper_bound(tick));
    for (auto it = blast_kernels.begin(); it != blast_kernels.end();)
        if (it->second.tick <= tick)
            it = blast_kernels.erase(it);
        else
            ++it;
}
void NativeTerrain::reset_prediction(int64_t tick) {
    for (const auto &entry : authority)
        write_hp(entry.first, entry.second, false, false);
    base.clear();
    authority.clear();
    prediction.clear();
    for (auto it = blast_kernels.begin(); it != blast_kernels.end();)
        if (tick < 0 || it->second.tick <= tick)
            it = blast_kernels.erase(it);
        else
            ++it;
    floor_tick = authority_tick = tick;
    ++generation;
    needs_state = false;
}
Dictionary NativeTerrain::pending_cells() const {
    Dictionary out;
    for (const auto &entry : authority)
        if (hp[entry.first] != entry.second)
            out[sub_position(entry.first)] = entry.second;
    return out;
}
Dictionary NativeTerrain::prediction_cells_at(int64_t tick) const {
    Dictionary out;
    for (const auto &entry : values_at(tick))
        out[sub_position(entry.first)] = entry.second;
    return out;
}
Dictionary NativeTerrain::history_stats() const {
    Dictionary out;
    out["prediction_ticks"] = int64_t(prediction.size());
    out["kernels"] = int64_t(blast_kernels.size());
    out["kernel_builds"] = kernel_builds;
    out["rewind_cells"] = rewind_count();
    out["pending_rewind_cells"] = pending_rewind_count();
    out["rewind_enabled"] = rewind_enabled;
    return out;
}
void NativeTerrain::seal_rewind(double time) {
    if (rewind_pending.empty())
        return;
    RewindEntry entry;
    entry.time = time;
    entry.cells.reserve(rewind_pending.size());
    for (auto &cell : rewind_pending)
        entry.cells.push_back(std::move(cell.second));
    rewind_pending.clear();
    rewind_entries.push_back(std::move(entry));
}
void NativeTerrain::rewind_between(double target, double cursor) {
    auto after = [](double time, const RewindEntry &entry) { return time < entry.time; };
    const auto begin = std::upper_bound(rewind_entries.begin(), rewind_entries.end(), target, after);
    auto end = std::upper_bound(begin, rewind_entries.end(), cursor, after);
    while (end != begin) {
        --end;
        for (auto cell = end->cells.rbegin(); cell != end->cells.rend(); ++cell)
            restore(*cell);
    }
    flush_collisions();
}
void NativeTerrain::prune_rewind(double cutoff) {
    while (!rewind_entries.empty() && rewind_entries.front().time < cutoff)
        rewind_entries.pop_front();
}
void NativeTerrain::truncate_rewind(double time) {
    while (!rewind_entries.empty() && rewind_entries.back().time > time)
        rewind_entries.pop_back();
    rewind_pending.clear();
}
int NativeTerrain::rewind_count() const {
    int count = 0;
    for (const RewindEntry &entry : rewind_entries)
        count += entry.cells.size();
    return count;
}

void godot::register_native_terrain() {
    ClassDB::register_class<NativeTerrain>();
}
