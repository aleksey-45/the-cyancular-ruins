#include "terrain.h"
#include <algorithm>
#include <cmath>
#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <limits>

using namespace godot;

bool NativeTerrain::rect_overlaps(Rect2 bounds, double size, bool with_liquid) const {
    if (empty() || size <= 0)
        return false;
    const int x0 = int(std::floor(bounds.position.x / size)), x1 = int(std::floor(bounds.get_end().x / size));
    const int y0 = int(std::floor(bounds.position.y / size)), y1 = int(std::floor(bounds.get_end().y / size));
    for (int y = y0; y <= y1; ++y)
        for (int x = x0; x <= x1; ++x) {
            const int packed = value(Vector2i(x, y));
            if (!packed)
                continue;
            const int type = material(texture(packed)).type;
            if (type == wall_type || (with_liquid && type == liquid_type))
                return true;
        }
    return false;
}

int NativeTerrain::topmost_solid_row(Rect2 bounds, double size) const {
    if (empty() || size <= 0)
        return -1;
    const int x0 = int(std::floor(bounds.position.x / size)), x1 = int(std::floor(bounds.get_end().x / size));
    const int y0 = int(std::floor(bounds.position.y / size)), y1 = int(std::floor(bounds.get_end().y / size));
    for (int y = y0; y <= y1; ++y)
        for (int x = x0; x <= x1; ++x) {
            const int packed = value(Vector2i(x, y));
            if (packed && material(texture(packed)).type == wall_type)
                return y;
        }
    return -1;
}

Dictionary NativeTerrain::trace_beam(Vector2 origin, Vector2 direction, double length, int max_bounces) const {
    PackedVector2Array points, hit_points;
    Array contacts;
    points.push_back(origin);
    auto result = [&]() {
        Dictionary out;
        out["points"] = points;
        out["contacts"] = contacts;
        out["hit_points"] = hit_points;
        return out;
    };
    if (empty()) {
        points.push_back(origin + direction.normalized() * length);
        return result();
    }
    // Keep the established half-tile beam grid and corner tie-breaking. Terrain
    // ownership changes do not silently change the weapon's collision rules.
    const double step = tile_size * .5;
    Vector2 p = origin, d = direction.normalized();
    if (d == Vector2())
        d = Vector2(1, 0);
    double traveled = 0;
    int bounces = 0;
    auto canonical = [](int v, int span) {
        const int n = v % span;
        return n < 0 ? n + span : n;
    };
    for (int guard = 0; guard < 10000; ++guard) {
        const double remaining = length - traveled;
        if (remaining <= 0)
            break;
        const int sx = int(std::floor(p.x / step)), sy = int(std::floor(p.y / step));
        double tx = std::numeric_limits<double>::infinity(), ty = tx;
        if (d.x > 0)
            tx = ((sx + 1) * step - p.x) / d.x;
        else if (d.x < 0)
            tx = (sx * step - p.x) / d.x;
        if (d.y > 0)
            ty = ((sy + 1) * step - p.y) / d.y;
        else if (d.y < 0)
            ty = (sy * step - p.y) / d.y;
        const double t = std::min(tx, ty);
        if (std::isinf(t)) {
            points.push_back(p + d * remaining);
            break;
        }
        if (t <= 1e-9) {
            p += d * .25;
            continue;
        }
        if (t > remaining) {
            points.push_back(p + d * remaining);
            break;
        }
        const Vector2 q = p + d * t;
        const bool cross_x = tx <= ty;
        const int nx = sx + (cross_x ? (d.x > 0 ? 1 : -1) : 0), ny = sy + (!cross_x ? (d.y > 0 ? 1 : -1) : 0);
        const int gx = canonical(nx, columns * 2), gy = canonical(ny, rows * 2);
        const Vector2i cell(gx / 2, gy / 2);
        const int packed = value(cell);
        const bool solid =
            packed && material(texture(packed)).type == wall_type && (packed & (1 << (gy % 2 * 2 + gx % 2)));
        if (!solid) {
            p = q;
            traveled += t;
            continue;
        }
        points.push_back(q);
        contacts.push_back(cell);
        hit_points.push_back(q);
        traveled += t;
        if (bounces >= max_bounces)
            break;
        ++bounces;
        if (cross_x)
            d.x = -d.x;
        else
            d.y = -d.y;
        p = q + d * .5;
    }
    return result();
}
