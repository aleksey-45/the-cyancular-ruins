#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>

namespace godot {

// Main-thread aggregates only. No entities, packets, strings or per-sample allocation.
class NativePerformanceStats : public RefCounted {
    GDCLASS(NativePerformanceStats, RefCounted)
protected:
    static void _bind_methods();
public:
    enum Metric {
        NETWORK_POLL, NETWORK_DISPATCH, SERVER_TICK, SERVER_SIMULATION,
        WORLD_CAPTURE, STATE_PREPARE, STATE_ENCODE, STATE_FANOUT, TRANSPORT_SEND,
        CLIENT_AUTHORITY, CLIENT_TICK, CLIENT_PRESENT, REPLAY,
        ACTOR_STEP, PROJECTILE_STEP, COMBAT_STEP, HISTORY_SAVE, TERRAIN_COMMIT,
        CALLBACK_INTERVAL, PHYSICS_TICKS, REPLAY_TICKS, COUNT
    };
    enum Statistic { SAMPLES, MEAN, MAXIMUM, TOTAL, OVER_BUDGET };
    static void set_enabled(bool enabled);
    static bool is_enabled();
    static void reset();
    static int64_t begin();
    static void end(int metric, int64_t started);
    static void observe(int metric, int64_t value);
    static void physics_tick();
    static void replayed(int64_t ticks);
    static void frame_boundary();
    static void publish();
    static double read(int metric, int statistic);
    static Dictionary snapshot(bool total);
    static int64_t storage_bytes();
};

class PerformanceScope {
    int metric;
    int64_t started;
public:
    explicit PerformanceScope(int value) : metric(value), started(NativePerformanceStats::begin()) {}
    ~PerformanceScope() { NativePerformanceStats::end(metric, started); }
    PerformanceScope(const PerformanceScope &) = delete;
    PerformanceScope &operator=(const PerformanceScope &) = delete;
};

} // namespace godot
