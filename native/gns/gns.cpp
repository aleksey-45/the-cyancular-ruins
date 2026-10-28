#include <steam/steamnetworkingsockets.h>
#include <steam/isteamnetworkingutils.h>
#include <godot_cpp/classes/file_access.hpp>
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/classes/time.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/godot.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include <algorithm>
#include <cstring>
#include <deque>
#include <map>

using namespace godot;

class GnsEndpoint : public RefCounted {
    GDCLASS(GnsEndpoint, RefCounted)
    enum { INPUT, STATE, EVENT };
    enum { MESSAGE, CONNECTED, DISCONNECTED, FAILED };
    static constexpr int SEND_RATE = 64 * 1024;
    static constexpr int EVENT_CHUNK = 128 * 1024;
    static constexpr int MAX_FRAME = 32 * 1024 * 1024;
    static constexpr int MAX_REALTIME = 16 * 1024;
    static constexpr int MAX_POLL_MESSAGES = 256;
    static constexpr int MAX_POLL_BYTES = 512 * 1024;
    static constexpr int MAX_POLL_USEC = 2000;
    struct Connection {
        HSteamNetConnection handle;
        PackedByteArray latest[2];
        PackedByteArray event_buffer;
        std::deque<PackedByteArray> reliable;
        int send_offset = 0;
        int event_size = 0;
        int64_t event_queued = 0;
        int64_t replaced[2] = {};
        bool connected = false;
    };
    static inline int instances = 0;
    static inline bool initialized = false;
    static inline std::map<HSteamNetConnection, GnsEndpoint *> owners;
    static inline std::map<HSteamListenSocket, GnsEndpoint *> listeners;
    HSteamListenSocket listener = k_HSteamListenSocket_Invalid;
    HSteamNetPollGroup group = k_HSteamNetPollGroup_Invalid;
    std::map<int, Connection> connections;
    std::map<HSteamNetConnection, int> peers;
    Array events;
    std::deque<SteamNetworkingMessage_t *> incoming;
    int64_t poll_messages = 0, poll_wire_bytes = 0, poll_decoded_bytes = 0;
    int64_t poll_budget_hits = 0, poll_max_us = 0, receive_age_max_us = 0;
    bool server = false;
    bool compression = true;
    int next_peer = 2;
    int port = 0;

    static void status_changed(SteamNetConnectionStatusChangedCallback_t *change) {
        auto found = owners.find(change->m_hConn);
        if (found != owners.end()) {
            found->second->on_status(*change);
        } else {
            auto listening = listeners.find(change->m_info.m_hListenSocket);
            if (listening != listeners.end()) listening->second->on_status(*change);
        }
    }

    void configure(HSteamNetConnection handle) {
        const int priorities[3] = {1, 1, 1};
        const uint16 weights[3] = {1, 1, 1};
        SteamNetworkingSockets()->ConfigureConnectionLanes(handle, 3, priorities, weights);
        SteamNetworkingSockets()->SetConnectionPollGroup(handle, group);
    }

    void on_status(const SteamNetConnectionStatusChangedCallback_t &change) {
        auto api = SteamNetworkingSockets();
        if (change.m_info.m_eState == k_ESteamNetworkingConnectionState_Connecting && server) {
            if (connections.size() == 8) {
                api->CloseConnection(change.m_hConn, 0, "Room full", false);
                return;
            }
            int peer = next_peer++;
            connections.emplace(peer, Connection{change.m_hConn});
            peers[change.m_hConn] = peer;
            owners[change.m_hConn] = this;
            configure(change.m_hConn);
            api->AcceptConnection(change.m_hConn);
            return;
        }
        auto found = peers.find(change.m_hConn);
        if (found == peers.end()) return;
        int peer = found->second;
        auto &connection = connections.at(peer);
        if (change.m_info.m_eState == k_ESteamNetworkingConnectionState_Connected) {
            connection.connected = true;
            events.push_back(Array::make(CONNECTED, peer));
        } else if (change.m_info.m_eState == k_ESteamNetworkingConnectionState_ClosedByPeer ||
                   change.m_info.m_eState == k_ESteamNetworkingConnectionState_ProblemDetectedLocally) {
            events.push_back(Array::make(connection.connected || server ? DISCONNECTED : FAILED,
                peer, change.m_info.m_eEndReason, String::utf8(change.m_info.m_szEndDebug)));
            api->CloseConnection(change.m_hConn, 0, nullptr, false);
            owners.erase(change.m_hConn);
            peers.erase(found);
            connections.erase(peer);
        }
    }

    bool open_group() {
        close();
        if (!initialized) {
            SteamNetworkingErrMsg error;
            initialized = GameNetworkingSockets_Init(nullptr, error);
            if (!initialized) {
                UtilityFunctions::push_error("GNS initialization: ", String::utf8(error));
                return false;
            }
            SteamNetworkingUtils()->SetDebugOutputFunction(k_ESteamNetworkingSocketsDebugOutputType_Warning,
                [](ESteamNetworkingSocketsDebugOutputType, const char *message) {
                    UtilityFunctions::printerr("GNS: ", String::utf8(message));
                });
        }
        group = SteamNetworkingSockets()->CreatePollGroup();
        return group != k_HSteamNetPollGroup_Invalid;
    }

    int options(SteamNetworkingConfigValue_t *values) {
        values[0].SetPtr(k_ESteamNetworkingConfig_Callback_ConnectionStatusChanged,
                        reinterpret_cast<void *>(status_changed));
        values[1].SetInt32(k_ESteamNetworkingConfig_IP_AllowWithoutAuth, 1);
        values[2].SetInt32(k_ESteamNetworkingConfig_SendRateMin, SEND_RATE);
        values[3].SetInt32(k_ESteamNetworkingConfig_SendRateMax, SEND_RATE);
        values[4].SetInt32(k_ESteamNetworkingConfig_TimeoutInitial, 5000);
        values[5].SetInt32(k_ESteamNetworkingConfig_TimeoutConnected, 5000);
        values[6].SetInt32(k_ESteamNetworkingConfig_SendBufferSize, 1024 * 1024);
        values[7].SetInt32(k_ESteamNetworkingConfig_RecvBufferSize, 4 * 1024 * 1024);
        values[8].SetInt32(k_ESteamNetworkingConfig_RecvBufferMessages, 1024);
        values[9].SetInt32(k_ESteamNetworkingConfig_RecvMaxMessageSize, EVENT_CHUNK + 4);
        return 10;
    }

    PackedByteArray encode(const PackedByteArray &bytes) {
        PackedByteArray body = compression ? bytes.compress(FileAccess::COMPRESSION_ZSTD) : bytes;
        bool compressed = compression && body.size() < bytes.size();
        if (!compressed) body = bytes;
        PackedByteArray wire;
        wire.resize(body.size() + 4);
        wire.encode_u32(0, compressed ? bytes.size() : 0);
        std::memcpy(wire.ptrw() + 4, body.ptr(), body.size());
        return wire;
    }

    int enqueue(int peer, Connection &connection, int flow, const PackedByteArray &wire) {
        if (flow != EVENT) {
            if (wire.size() > MAX_REALTIME) return ERR_INVALID_PARAMETER;
            if (!connection.latest[flow].is_empty()) ++connection.replaced[flow];
            connection.latest[flow] = wire;
        } else {
            connection.reliable.push_back(wire);
            connection.event_queued += wire.size();
        }
        // Keep each peer's existing lane, retry, fragmentation and flush behavior.
        flush_latest(peer);
        return OK;
    }

    void deliver(int peer, const PackedByteArray &wire, int64_t received_us) {
        if (wire.size() < 5) return;
        uint32_t size = wire.decode_u32(0);
        if (size > MAX_FRAME) return;
        PackedByteArray bytes = wire.slice(4);
        if (size) bytes = bytes.decompress(size, FileAccess::COMPRESSION_ZSTD);
        if (!bytes.is_empty()) {
            poll_decoded_bytes += bytes.size();
            events.push_back(Array::make(MESSAGE, peer, bytes, received_us));
        }
    }

    void receive(SteamNetworkingMessage_t *message) {
        int64_t received_us = Time::get_singleton()->get_ticks_usec() -
            (SteamNetworkingUtils()->GetLocalTimestamp() - message->m_usecTimeReceived);
        receive_age_max_us = std::max(receive_age_max_us, int64_t(Time::get_singleton()->get_ticks_usec()) - received_us);
        int peer = peers.at(message->m_conn);
        PackedByteArray bytes;
        bytes.resize(message->m_cbSize);
        std::memcpy(bytes.ptrw(), message->m_pData, message->m_cbSize);
        if (message->m_idxLane != EVENT) {
            deliver(peer, bytes, received_us);
        } else if (bytes.size() >= 4) {
            auto &connection = connections.at(peer);
            int size = bytes.decode_u32(0);
            if (size <= 0 || size > MAX_FRAME ||
                (!connection.event_buffer.is_empty() && size != connection.event_size) ||
                connection.event_buffer.size() + bytes.size() - 4 > size) {
                disconnect_peer(peer, "Invalid reliable message length");
                return;
            }
            if (connection.event_buffer.is_empty()) connection.event_size = size;
            connection.event_buffer.append_array(bytes.slice(4));
            if (connection.event_buffer.size() == connection.event_size) {
                deliver(peer, connection.event_buffer, received_us);
                connection.event_buffer.clear();
            }
        }
    }

    void flush_latest(int target_peer = 0) {
        for (auto &[peer, connection] : connections) {
            if (target_peer && peer != target_peer) continue;
            if (!connection.connected) continue;
            SteamNetConnectionRealTimeLaneStatus_t lanes[3] = {};
            auto api = SteamNetworkingSockets();
            SteamNetConnectionRealTimeStatus_t status = {};
            api->GetConnectionRealTimeStatus(connection.handle, &status, 0, nullptr);
            if (status.m_eState != k_ESteamNetworkingConnectionState_Connected) continue;
            api->GetConnectionRealTimeStatus(connection.handle, nullptr, 3, lanes);
            for (int flow = INPUT; flow <= STATE; ++flow) {
                auto &bytes = connection.latest[flow];
                if (bytes.is_empty() || lanes[flow].m_cbPendingUnreliable ||
                    lanes[flow].m_cbPendingReliable || lanes[flow].m_usecQueueTime > 16667) continue;
                SteamNetworkingMessage_t *message = SteamNetworkingUtils()->AllocateMessage(bytes.size());
                std::memcpy(message->m_pData, bytes.ptr(), bytes.size());
                message->m_conn = connection.handle;
                message->m_idxLane = flow;
                message->m_nFlags = k_nSteamNetworkingSend_UnreliableNoNagle;
                int64 result;
                api->SendMessages(1, &message, &result, true);
                bytes.clear();
                if (result < 0) events.push_back(Array::make(4, peer, int(-result), "GNS send failed"));
            }
            while (!connection.reliable.empty() && lanes[EVENT].m_cbPendingReliable < 256 * 1024) {
                const auto &wire = connection.reliable.front();
                int length = std::min(EVENT_CHUNK, int(wire.size()) - connection.send_offset);
                auto message = SteamNetworkingUtils()->AllocateMessage(length + 4);
                uint32_t total = wire.size();
                std::memcpy(message->m_pData, &total, 4);
                std::memcpy(static_cast<uint8_t *>(message->m_pData) + 4,
                    wire.ptr() + connection.send_offset, length);
                message->m_conn = connection.handle;
                message->m_idxLane = EVENT;
                message->m_nFlags = k_nSteamNetworkingSend_ReliableNoNagle;
                int64 result;
                api->SendMessages(1, &message, &result, true);
                if (result < 0) {
                    events.push_back(Array::make(4, peer, int(-result), "GNS reliable send failed"));
                    break;
                }
                lanes[EVENT].m_cbPendingReliable += length + 4;
                connection.send_offset += length;
                connection.event_queued -= length;
                if (connection.send_offset == wire.size()) {
                    connection.reliable.pop_front();
                    connection.send_offset = 0;
                }
            }
        }
    }

protected:
    static void _bind_methods() {
        ClassDB::bind_method(D_METHOD("listen", "port"), &GnsEndpoint::listen);
        ClassDB::bind_method(D_METHOD("connect_to", "address", "port"), &GnsEndpoint::connect_to);
        ClassDB::bind_method(D_METHOD("send", "peer", "flow", "bytes"), &GnsEndpoint::send);
        ClassDB::bind_method(D_METHOD("send_many", "peers", "flow", "bytes"), &GnsEndpoint::send_many);
        ClassDB::bind_method(D_METHOD("poll", "max_messages"), &GnsEndpoint::poll, DEFVAL(MAX_POLL_MESSAGES));
        ClassDB::bind_method(D_METHOD("take_poll_statistics"), &GnsEndpoint::take_poll_statistics);
        ClassDB::bind_method(D_METHOD("disconnect_peer", "peer", "reason"), &GnsEndpoint::disconnect_peer);
        ClassDB::bind_method(D_METHOD("close"), &GnsEndpoint::close);
        ClassDB::bind_method(D_METHOD("get_port"), &GnsEndpoint::get_port);
        ClassDB::bind_method(D_METHOD("is_connected"), &GnsEndpoint::is_connected);
        ClassDB::bind_method(D_METHOD("statistics"), &GnsEndpoint::statistics);
        ClassDB::bind_method(D_METHOD("set_compression", "enabled"), &GnsEndpoint::set_compression);
    }

public:
    GnsEndpoint() { ++instances; }
    ~GnsEndpoint() {
        close();
        if (--instances == 0 && initialized) {
            GameNetworkingSockets_Kill();
            initialized = false;
        }
    }

    int listen(int requested_port) {
        if (!open_group()) return ERR_CANT_CREATE;
        server = true;
        SteamNetworkingIPAddr address;
        address.Clear();
        address.m_port = requested_port;
        SteamNetworkingConfigValue_t values[10];
        int count = options(values);
        listener = SteamNetworkingSockets()->CreateListenSocketIP(address, count, values);
        if (listener == k_HSteamListenSocket_Invalid) return ERR_CANT_CREATE;
        listeners[listener] = this;
        SteamNetworkingSockets()->GetListenSocketAddress(listener, &address);
        port = address.m_port;
        return OK;
    }

    int connect_to(const String &host, int requested_port) {
        if (!open_group()) return ERR_CANT_CREATE;
        server = false;
        SteamNetworkingIPAddr address;
        if (!address.ParseString(host.utf8().get_data())) return ERR_INVALID_PARAMETER;
        address.m_port = requested_port;
        SteamNetworkingConfigValue_t values[10];
        int count = options(values);
        auto handle = SteamNetworkingSockets()->ConnectByIPAddress(address, count, values);
        if (handle == k_HSteamNetConnection_Invalid) return ERR_CANT_CONNECT;
        connections.emplace(1, Connection{handle});
        peers[handle] = 1;
        owners[handle] = this;
        configure(handle);
        return OK;
    }

    int send(int peer, int flow, const PackedByteArray &bytes) {
        if (flow < INPUT || flow > EVENT || bytes.is_empty() || bytes.size() > MAX_FRAME - 4)
            return ERR_INVALID_PARAMETER;
        auto found = connections.find(peer);
        if (found == connections.end() || !found->second.connected) return ERR_UNCONFIGURED;
        return enqueue(peer, found->second, flow, encode(bytes));
    }

    PackedInt32Array send_many(const PackedInt32Array &targets, int flow, const PackedByteArray &bytes) {
        PackedInt32Array errors;
        errors.resize(targets.size());
        PackedByteArray wire;
        for (int i = 0; i < targets.size(); ++i) {
            if (flow < INPUT || flow > EVENT || bytes.is_empty() || bytes.size() > MAX_FRAME - 4) {
                errors.set(i, ERR_INVALID_PARAMETER);
                continue;
            }
            const int peer = targets[i];
            auto found = connections.find(peer);
            if (found == connections.end() || !found->second.connected) {
                errors.set(i, ERR_UNCONFIGURED);
                continue;
            }
            // PackedByteArray shares immutable storage across peer queues. Compress once per broadcast.
            if (wire.is_empty()) wire = encode(bytes);
            errors.set(i, enqueue(peer, found->second, flow, wire));
        }
        return errors;
    }

    Array poll(int max_messages = MAX_POLL_MESSAGES) {
        if (group == k_HSteamNetPollGroup_Invalid) return {};
        int64_t started = Time::get_singleton()->get_ticks_usec();
        int64_t decoded_before = poll_decoded_bytes;
        auto api = SteamNetworkingSockets();
        api->RunCallbacks();
        int limit = std::clamp(max_messages, 0, MAX_POLL_MESSAGES);
        int processed = 0;
        int64_t wire_bytes = 0;
        while (processed < limit) {
            // Yield only between complete messages. Prefetched messages keep their references.
            if (processed && (wire_bytes >= MAX_POLL_BYTES || poll_decoded_bytes - decoded_before >= MAX_POLL_BYTES ||
                int64_t(Time::get_singleton()->get_ticks_usec()) - started >= MAX_POLL_USEC)) {
                ++poll_budget_hits;
                break;
            }
            if (incoming.empty()) {
                SteamNetworkingMessage_t *messages[64];
                int count = api->ReceiveMessagesOnPollGroup(group, messages, std::min(64, limit - processed));
                if (count <= 0) break;
                for (int i = 0; i < count; ++i) incoming.push_back(messages[i]);
            }
            auto message = incoming.front();
            incoming.pop_front();
            wire_bytes += message->m_cbSize;
            if (peers.count(message->m_conn)) receive(message);
            message->Release();
            ++processed;
        }
        if (limit && processed == limit) ++poll_budget_hits;
        poll_messages += processed;
        poll_wire_bytes += wire_bytes;
        flush_latest();
        poll_max_us = std::max(poll_max_us, int64_t(Time::get_singleton()->get_ticks_usec()) - started);
        Array result = events;
        events = Array();
        return result;
    }

    Dictionary take_poll_statistics() {
        Dictionary result;
        result["messages"] = poll_messages;
        result["wire_bytes"] = poll_wire_bytes;
        result["decoded_bytes"] = poll_decoded_bytes;
        result["budget_hits"] = poll_budget_hits;
        result["buffered_messages"] = int64_t(incoming.size());
        result["max_poll_ms"] = poll_max_us / 1000.0;
        result["queue_age_max_ms"] = receive_age_max_us / 1000.0;
        poll_messages = poll_wire_bytes = poll_decoded_bytes = poll_budget_hits = poll_max_us = receive_age_max_us = 0;
        return result;
    }

    void disconnect_peer(int peer, const String &reason) {
        auto found = connections.find(peer);
        if (found == connections.end()) return;
        auto handle = found->second.handle;
        SteamNetworkingSockets()->CloseConnection(handle, 0, reason.utf8().get_data(), false);
        owners.erase(handle);
        peers.erase(handle);
        connections.erase(found);
        events.push_back(Array::make(DISCONNECTED, peer, 0, reason));
    }

    void close() {
        if (!initialized) return;
        for (auto message : incoming) message->Release();
        incoming.clear();
        auto api = SteamNetworkingSockets();
        for (auto &[peer, connection] : connections) {
            owners.erase(connection.handle);
            api->CloseConnection(connection.handle, 0, nullptr, false);
        }
        connections.clear();
        peers.clear();
        if (listener != k_HSteamListenSocket_Invalid) {
            listeners.erase(listener);
            api->CloseListenSocket(listener);
            listener = k_HSteamListenSocket_Invalid;
        }
        if (group != k_HSteamNetPollGroup_Invalid) {
            api->DestroyPollGroup(group);
            group = k_HSteamNetPollGroup_Invalid;
        }
        events.clear();
    }

    int get_port() const { return port; }
    bool is_connected() const { return connections.count(1) && connections.at(1).connected; }
    void set_compression(bool enabled) { compression = enabled; }
    Array statistics() const {
        Array result;
        for (auto &[peer, connection] : connections) {
            if (!connection.connected) continue;
            SteamNetConnectionRealTimeStatus_t status = {};
            SteamNetConnectionRealTimeLaneStatus_t lanes[3] = {};
            SteamNetworkingSockets()->GetConnectionRealTimeStatus(connection.handle, &status, 0, nullptr);
            if (status.m_eState != k_ESteamNetworkingConnectionState_Connected) continue;
            SteamNetworkingSockets()->GetConnectionRealTimeStatus(connection.handle, nullptr, 3, lanes);
            Dictionary row;
            row["peer"] = peer;
            row["rtt_ms"] = status.m_nPing;
            row["send_rate_bytes_s"] = status.m_nSendRateBytesPerSecond;
            row["tx_bytes_s"] = status.m_flOutBytesPerSec;
            row["rx_bytes_s"] = status.m_flInBytesPerSec;
            row["tx_packets_s"] = status.m_flOutPacketsPerSec;
            row["rx_packets_s"] = status.m_flInPacketsPerSec;
            row["quality_local"] = status.m_flConnectionQualityLocal;
            row["quality_remote"] = status.m_flConnectionQualityRemote;
            Array queues;
            for (int i = 0; i < 3; ++i) {
                Dictionary queue;
                queue["pending_unreliable"] = lanes[i].m_cbPendingUnreliable;
                queue["pending_reliable"] = lanes[i].m_cbPendingReliable;
                queue["unacked_reliable"] = lanes[i].m_cbSentUnackedReliable;
                queue["queue_us"] = lanes[i].m_usecQueueTime;
                queues.push_back(queue);
            }
            row["lanes"] = queues;
            row["replaced_input"] = connection.replaced[INPUT];
            row["replaced_state"] = connection.replaced[STATE];
            row["pending_event_bytes"] = connection.event_queued;
            result.push_back(row);
        }
        return result;
    }
};

static void initialize_gns(ModuleInitializationLevel level) {
    if (level == MODULE_INITIALIZATION_LEVEL_SCENE) ClassDB::register_class<GnsEndpoint>();
}
static void terminate_gns(ModuleInitializationLevel) {}
extern "C" GDExtensionBool GDE_EXPORT gns_init(GDExtensionInterfaceGetProcAddress get_proc_address,
        GDExtensionClassLibraryPtr library, GDExtensionInitialization *initialization) {
    GDExtensionBinding::InitObject init(get_proc_address, library, initialization);
    init.register_initializer(initialize_gns);
    init.register_terminator(terminate_gns);
    init.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);
    return init.init();
}
