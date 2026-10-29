#include "performance_stats.h"
#include <godot_cpp/classes/time.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <array>
#include <algorithm>

using namespace godot;

namespace {
using Stats = NativePerformanceStats;
constexpr std::array<int64_t, 10> TIME_BOUNDS = {100, 250, 500, 1000, 2000, 4000, 8000, 16667, 33334, 66667};
constexpr std::array<int64_t, 10> COUNT_BOUNDS = {0, 1, 2, 4, 8, 16, 32, 64, 128, 256};
constexpr std::array<const char *, Stats::COUNT> NAMES = {
    "network_poll", "network_dispatch", "server_tick", "server_simulation",
    "world_capture", "state_prepare", "state_encode_peer", "state_fanout", "transport_send",
    "client_authority", "client_tick", "client_present", "replay",
    "actor_step", "projectile_step", "combat_step", "history_save", "terrain_commit",
    "callback_interval", "physics_ticks_per_frame", "replay_ticks_per_frame"
};
struct Aggregate {
    int64_t count = 0, sum = 0, maximum = 0, max_at = 0, over_budget = 0;
    std::array<int64_t, TIME_BOUNDS.size() + 1> histogram = {};
    void add(int64_t value, bool count_metric, int64_t at) {
        if (!count || value > maximum) max_at = at;
        ++count;
        sum += value;
        maximum = std::max(maximum, value);
        if (!count_metric && value > 16667) ++over_budget;
        const auto &bounds = count_metric ? COUNT_BOUNDS : TIME_BOUNDS;
        const auto bin = std::lower_bound(bounds.begin(), bounds.end(), value) - bounds.begin();
        ++histogram[bin];
    }
};
struct Window {
    int64_t started = 0, ended = 0;
    std::array<Aggregate, Stats::COUNT> metrics = {};
};
struct Storage {
    bool enabled = false;
    int64_t last_frame = 0, physics_ticks = 0, replay_ticks = 0;
    Window pending, published, total;
} data;
static_assert(sizeof(Storage) < 16 * 1024, "Performance aggregates must stay bounded");

int64_t now() { return Time::get_singleton()->get_ticks_usec(); }
bool valid(int metric) { return metric >= 0 && metric < Stats::COUNT; }
}

void NativePerformanceStats::_bind_methods() {
#define BIND(name, ...) ClassDB::bind_static_method("NativePerformanceStats", D_METHOD(#name, __VA_ARGS__), &NativePerformanceStats::name)
#define BIND0(name) ClassDB::bind_static_method("NativePerformanceStats", D_METHOD(#name), &NativePerformanceStats::name)
    BIND(set_enabled, "enabled"); BIND0(is_enabled); BIND0(reset); BIND0(begin);
    BIND(end, "metric", "started"); BIND(observe, "metric", "value");
    BIND0(physics_tick); BIND(replayed, "ticks"); BIND0(frame_boundary); BIND0(publish);
    BIND(read, "metric", "statistic"); BIND(snapshot, "total"); BIND0(storage_bytes);
#undef BIND
#undef BIND0
#define METRIC(name) ClassDB::bind_integer_constant("NativePerformanceStats", "Metric", #name, name)
    METRIC(NETWORK_POLL); METRIC(NETWORK_DISPATCH); METRIC(SERVER_TICK); METRIC(SERVER_SIMULATION);
    METRIC(WORLD_CAPTURE); METRIC(STATE_PREPARE); METRIC(STATE_ENCODE); METRIC(STATE_FANOUT); METRIC(TRANSPORT_SEND);
    METRIC(CLIENT_AUTHORITY); METRIC(CLIENT_TICK); METRIC(CLIENT_PRESENT); METRIC(REPLAY);
    METRIC(ACTOR_STEP); METRIC(PROJECTILE_STEP); METRIC(COMBAT_STEP); METRIC(HISTORY_SAVE); METRIC(TERRAIN_COMMIT);
    METRIC(CALLBACK_INTERVAL); METRIC(PHYSICS_TICKS); METRIC(REPLAY_TICKS); METRIC(COUNT);
#undef METRIC
#define STAT(name) ClassDB::bind_integer_constant("NativePerformanceStats", "Statistic", #name, name)
    STAT(SAMPLES); STAT(MEAN); STAT(MAXIMUM); STAT(TOTAL); STAT(OVER_BUDGET);
#undef STAT
}

void NativePerformanceStats::set_enabled(bool enabled) {
    if (data.enabled == enabled) return;
    data.enabled = enabled;
    reset();
}
bool NativePerformanceStats::is_enabled() { return data.enabled; }
void NativePerformanceStats::reset() {
    const bool enabled = data.enabled;
    data = Storage{};
    data.enabled = enabled;
    data.total.started = data.pending.started = now();
}
int64_t NativePerformanceStats::begin() { return data.enabled ? now() : 0; }
void NativePerformanceStats::end(int metric, int64_t started) {
    if (data.enabled && started > 0) observe(metric, std::max<int64_t>(0, now() - started));
}
void NativePerformanceStats::observe(int metric, int64_t value) {
    if (!data.enabled || !valid(metric) || value < 0) return;
    const bool count_metric = metric >= PHYSICS_TICKS;
    Aggregate &pending = data.pending.metrics[metric], &total = data.total.metrics[metric];
    const int64_t at = !pending.count || value > pending.maximum || !total.count || value > total.maximum ? now() : 0;
    pending.add(value, count_metric, at);
    total.add(value, count_metric, at);
}
void NativePerformanceStats::physics_tick() { if (data.enabled) ++data.physics_ticks; }
void NativePerformanceStats::replayed(int64_t ticks) { if (data.enabled) data.replay_ticks += std::max<int64_t>(0, ticks); }
void NativePerformanceStats::frame_boundary() {
    if (!data.enabled) return;
    const int64_t at = now();
    if (data.last_frame > 0) observe(CALLBACK_INTERVAL, at - data.last_frame);
    observe(PHYSICS_TICKS, data.physics_ticks);
    observe(REPLAY_TICKS, data.replay_ticks);
    data.last_frame = at;
    data.physics_ticks = data.replay_ticks = 0;
}
void NativePerformanceStats::publish() {
    if (!data.enabled) return;
    data.pending.ended = now();
    data.published = data.pending;
    data.pending = Window{};
    data.pending.started = data.published.ended;
}
double NativePerformanceStats::read(int metric, int statistic) {
    if (!valid(metric)) return 0;
    const Aggregate &sample = data.published.metrics[metric];
    switch (statistic) {
        case SAMPLES: return double(sample.count);
        case MEAN: return sample.count ? double(sample.sum) / double(sample.count) : 0;
        case MAXIMUM: return double(sample.maximum);
        case TOTAL: return double(sample.sum);
        case OVER_BUDGET: return double(sample.over_budget);
        default: return 0;
    }
}
Dictionary NativePerformanceStats::snapshot(bool total) {
    const Window &window = total ? data.total : data.published;
    Dictionary metrics;
    for (int i = 0; i < COUNT; ++i) {
        const Aggregate &sample = window.metrics[i];
        Dictionary row;
        row["unit"] = i >= PHYSICS_TICKS ? "ticks" : "us";
        row["samples"] = sample.count;
        row["sum"] = sample.sum;
        row["max"] = sample.maximum;
        row["max_at_uptime_us"] = sample.max_at;
        row["over_16667_us"] = sample.over_budget;
        PackedInt64Array bins;
        for (int64_t count : sample.histogram) bins.push_back(count);
        row["histogram"] = bins;
        metrics[NAMES[i]] = row;
    }
    PackedInt64Array time_bounds, count_bounds;
    for (int64_t bound : TIME_BOUNDS) time_bounds.push_back(bound);
    for (int64_t bound : COUNT_BOUNDS) count_bounds.push_back(bound);
    Dictionary result;
    result["enabled"] = data.enabled;
    result["window_us"] = window.started ? std::max<int64_t>(0, (total ? now() : window.ended) - window.started) : 0;
    result["storage_bytes"] = storage_bytes();
    result["time_bucket_upper_us"] = time_bounds;
    result["count_bucket_upper"] = count_bounds;
    result["metrics"] = metrics;
    return result;
}
int64_t NativePerformanceStats::storage_bytes() { return sizeof(Storage); }
