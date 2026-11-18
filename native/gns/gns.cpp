#include <fast-lzma2.h>
#include <steam/isteamnetworkingutils.h>
#include <steam/steamnetworkingsockets.h>
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/classes/time.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/godot.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include <algorithm>
#include <cstdint>
#include <cstring>
#include <deque>
#include <map>
#include <memory>
#include <set>
#include <utility>
#include <vector>

using namespace godot;

namespace gns {
using Bytes = std::vector<uint8_t>;
using Payload = std::shared_ptr<const Bytes>;
constexpr uint32_t WIRE_TAG = 0x02534e47; // GNS, transport version 2, little endian.
constexpr size_t HEADER = 8;
constexpr size_t MAX_PAYLOAD = 64 * 1024 * 1024;

uint32_t read_u32(const uint8_t *p) {
    return uint32_t(p[0]) | uint32_t(p[1]) << 8 | uint32_t(p[2]) << 16 | uint32_t(p[3]) << 24;
}
void write_u32(uint8_t *p, uint32_t value) {
    for (int i = 0; i < 4; ++i) p[i] = uint8_t(value >> (8 * i));
}
} // namespace gns

class GnsEndpoint : public RefCounted {
    GDCLASS(GnsEndpoint, RefCounted)
    enum { INPUT, STATE, EVENT, LANE_COUNT };
    enum { MESSAGE, CONNECTED, DISCONNECTED, FAILED };
    static constexpr int SERVER_PEER = 1;
    static constexpr int MAX_POLL_MESSAGES = 256;
    static constexpr int MAX_POLL_BYTES = 512 * 1024;
    static constexpr uint64_t MAX_POLL_USEC = 2000;

    struct Connection {
        explicit Connection(HSteamNetConnection handle) : handle(handle) {}
        HSteamNetConnection handle;
        bool connected = false;
        gns::Payload latest[EVENT];
        std::deque<gns::Payload> reliable;
        size_t sent = 0;
        gns::Bytes receiving;
        size_t receiving_size = 0;
    };
    using Connections = std::map<int, Connection>;

    static inline ISteamNetworkingSockets *sockets = nullptr;
    static inline std::set<GnsEndpoint *> endpoints;
    HSteamListenSocket listener = k_HSteamListenSocket_Invalid;
    HSteamNetPollGroup group = k_HSteamNetPollGroup_Invalid;
    Connections connections;
    std::unique_ptr<FL2_CCtx, decltype(&FL2_freeCCtx)> encoder{nullptr, FL2_freeCCtx};
    std::unique_ptr<FL2_DCtx, decltype(&FL2_freeDCtx)> decoder{nullptr, FL2_freeDCtx};
    int next_peer = SERVER_PEER + 1;
    Array events;

    static void status_changed(SteamNetConnectionStatusChangedCallback_t *change) {
        const auto handle = change->m_hConn;
        const auto &info = change->m_info;
        // Callback snapshots can contain stale user data; query the live connection instead.
        const int peer = int(sockets->GetConnectionUserData(handle));
        for (auto *endpoint : endpoints) {
            auto found = endpoint->connections.find(peer);
            if (found != endpoint->connections.end() && found->second.handle == handle) {
                endpoint->update_peer(found, info);
                return;
            }
            if (info.m_eState == k_ESteamNetworkingConnectionState_Connecting &&
                info.m_hListenSocket != k_HSteamListenSocket_Invalid && endpoint->listener == info.m_hListenSocket) {
                const int peer = endpoint->next_peer++;
                endpoint->add_peer(peer, handle);
                if (sockets->AcceptConnection(handle) != k_EResultOK)
                    endpoint->disconnect_peer(peer, "Connection acceptance failed");
                return;
            }
        }
    }
    void update_peer(Connections::iterator peer, const SteamNetConnectionInfo_t &info) {
        auto &[id, connection] = *peer;
        if (info.m_eState == k_ESteamNetworkingConnectionState_Connected && !connection.connected) {
            connection.connected = true;
            events.push_back(Array::make(CONNECTED, id));
        } else if (info.m_eState == k_ESteamNetworkingConnectionState_ClosedByPeer ||
                   info.m_eState == k_ESteamNetworkingConnectionState_ProblemDetectedLocally) {
            const int kind = id == SERVER_PEER && !connection.connected ? FAILED : DISCONNECTED;
            events.push_back(Array::make(kind, id, info.m_eEndReason, String::utf8(info.m_szEndDebug)));
            close_peer(peer);
        }
    }
    void add_peer(int peer, HSteamNetConnection handle) {
        connections.try_emplace(peer, handle);
        sockets->SetConnectionUserData(handle, peer);
        sockets->ConfigureConnectionLanes(handle, LANE_COUNT, nullptr, nullptr);
        sockets->SetConnectionPollGroup(handle, group);
    }
    void close_peer(Connections::iterator peer, const char *reason = nullptr) {
        sockets->CloseConnection(peer->second.handle, 0, reason, false);
        connections.erase(peer);
    }
    bool open_group() {
        if (!encoder) {
            encoder.reset(FL2_createCCtxMt(4));
            if (encoder) {
                FL2_CCtx_setParameter(encoder.get(), FL2_p_compressionLevel, 5);
                FL2_CCtx_setParameter(encoder.get(), FL2_p_dictionarySize, 1024 * 1024);
            }
        }
        if (!decoder) decoder.reset(FL2_createDCtx());
        if (!encoder || !decoder) return false;
        if (!sockets) {
            SteamNetworkingErrMsg error;
            if (!GameNetworkingSockets_Init(nullptr, error)) {
                UtilityFunctions::push_error("GNS initialization: ", String::utf8(error));
                return false;
            }
            sockets = SteamNetworkingSockets();
            auto utils = SteamNetworkingUtils();
            utils->SetGlobalCallback_SteamNetConnectionStatusChanged(status_changed);
            utils->SetDebugOutputFunction(k_ESteamNetworkingSocketsDebugOutputType_Warning,
                [](ESteamNetworkingSocketsDebugOutputType, const char *message) {
                    UtilityFunctions::printerr("GNS: ", String::utf8(message));
                });
        }
        group = sockets->CreatePollGroup();
        return group != k_HSteamNetPollGroup_Invalid;
    }
    static EResult transmit(HSteamNetConnection handle, int lane, const uint8_t *bytes,
                            size_t length, uint32_t frame_length = 0) {
        const size_t header = lane == EVENT ? gns::HEADER : 0;
        if (length + header > size_t(k_cbMaxSteamNetworkingSocketsMessageSizeSend)) return k_EResultInvalidParam;
        auto *message = SteamNetworkingUtils()->AllocateMessage(int(length + header));
        if (!message) return k_EResultFail;
        auto *payload = static_cast<uint8_t *>(message->m_pData);
        if (header) {
            gns::write_u32(payload, gns::WIRE_TAG);
            gns::write_u32(payload + 4, frame_length);
        }
        std::memcpy(payload + header, bytes, length);
        message->m_conn = handle;
        message->m_idxLane = lane;
        message->m_nFlags = lane == EVENT ? k_nSteamNetworkingSend_ReliableNoNagle : k_nSteamNetworkingSend_UnreliableNoNagle;
        int64 result;
        sockets->SendMessages(1, &message, &result, true);
        return result > 0 ? k_EResultOK : result < 0 ? EResult(-result) : k_EResultFail;
    }
    void service(int peer, Connection &connection) {
        // A full-size EVENT fragment needs the default send buffer empty.
        // Try it before adding new realtime data so small packets cannot starve it.
        while (!connection.reliable.empty()) {
            const auto &wire = *connection.reliable.front();
            const size_t length = std::min(size_t(k_cbMaxSteamNetworkingSocketsMessageSizeSend) - gns::HEADER,
                                           wire.size() - connection.sent);
            const auto result = transmit(connection.handle, EVENT, wire.data() + connection.sent, length, uint32_t(wire.size()));
            if (result == k_EResultLimitExceeded) break;
            if (result != k_EResultOK) {
                disconnect_peer(peer, "Reliable frame submission failed");
                return;
            }
            connection.sent += length;
            if (connection.sent == wire.size()) {
                connection.reliable.pop_front();
                connection.sent = 0;
            }
        }
        for (int lane = INPUT; lane < EVENT; ++lane) {
            auto &pending = connection.latest[lane];
            if (!pending) continue;
            const auto result = transmit(connection.handle, lane, pending->data(), pending->size());
            if (result == k_EResultLimitExceeded) continue;
            if (result != k_EResultOK) {
                disconnect_peer(peer, "Realtime frame submission failed");
                return;
            }
            pending.reset();
        }
    }
    gns::Bytes encode(const PackedByteArray &bytes) {
        const size_t size = bytes.size();
        gns::Bytes wire(gns::HEADER + FL2_compressBound(size));
        const size_t compressed = FL2_compressCCtx(encoder.get(), wire.data() + gns::HEADER,
            wire.size() - gns::HEADER, bytes.ptr(), size, 0);
        if (FL2_isError(compressed)) return {};
        gns::write_u32(wire.data(), gns::WIRE_TAG);
        gns::write_u32(wire.data() + 4, compressed < size ? uint32_t(size) : 0);
        if (compressed >= size) std::memcpy(wire.data() + gns::HEADER, bytes.ptr(), size);
        wire.resize(gns::HEADER + std::min(compressed, size));
        return wire;
    }
    int send_to(int peer, int flow, const PackedByteArray &bytes, gns::Payload &payload) {
        if (flow < INPUT || flow >= LANE_COUNT || bytes.is_empty() || size_t(bytes.size()) > gns::MAX_PAYLOAD)
            return ERR_INVALID_PARAMETER;
        auto found = connections.find(peer);
        if (found == connections.end() || !found->second.connected) return ERR_UNCONFIGURED;
        auto &connection = found->second;
        if (!payload) payload = std::make_shared<gns::Bytes>(encode(bytes));
        if (payload->empty()) return godot::FAILED;
        if (flow == EVENT) {
            const bool waiting = !connection.reliable.empty();
            connection.reliable.push_back(payload);
            if (waiting) return OK;
        } else {
            connection.latest[flow] = payload;
        }
        service(peer, connection);
        return connections.count(peer) ? OK : ERR_CONNECTION_ERROR;
    }
    PackedByteArray decode(const uint8_t *wire, size_t size) {
        if (size <= gns::HEADER || gns::read_u32(wire) != gns::WIRE_TAG) return {};
        const size_t length = gns::read_u32(wire + 4);
        wire += gns::HEADER;
        size -= gns::HEADER;
        if (length > gns::MAX_PAYLOAD || size > gns::MAX_PAYLOAD) return {};
        PackedByteArray bytes;
        if (bytes.resize(length ? length : size) != OK) return {};
        if (length) {
            if (FL2_decompressDCtx(decoder.get(), bytes.ptrw(), length, wire, size) != length) return {};
        } else {
            std::memcpy(bytes.ptrw(), wire, size);
        }
        return bytes;
    }
    size_t receive(const SteamNetworkingMessage_t &message) {
        const int peer = int(message.m_nConnUserData);
        auto found = connections.find(peer);
        if (found == connections.end() || found->second.handle != message.m_conn) return 0;
        const auto *data = static_cast<const uint8_t *>(message.m_pData);
        if (message.m_idxLane >= LANE_COUNT || message.m_cbSize <= int(gns::HEADER) ||
            gns::read_u32(data) != gns::WIRE_TAG) {
            disconnect_peer(peer, "Invalid transport version or message header");
            return 0;
        }
        PackedByteArray bytes;
        if (message.m_idxLane == EVENT) {
            auto &connection = found->second;
            const size_t length = gns::read_u32(data + 4);
            const size_t chunk = message.m_cbSize - gns::HEADER;
            if (length <= gns::HEADER || length > gns::HEADER + gns::MAX_PAYLOAD ||
                connection.receiving.size() + chunk > length ||
                (!connection.receiving.empty() && length != connection.receiving_size)) {
                disconnect_peer(peer, "Invalid reliable message length");
                return 0;
            }
            connection.receiving_size = length;
            connection.receiving.insert(connection.receiving.end(), data + gns::HEADER, data + message.m_cbSize);
            if (connection.receiving.size() < length) return 0;
            bytes = decode(connection.receiving.data(), length);
            connection.receiving = gns::Bytes();
        } else {
            bytes = decode(data, message.m_cbSize);
        }
        if (bytes.is_empty()) {
            disconnect_peer(peer, "Invalid compressed frame");
            return 0;
        }
        const int64_t received_us = int64_t(Time::get_singleton()->get_ticks_usec()) -
            (SteamNetworkingUtils()->GetLocalTimestamp() - message.m_usecTimeReceived);
        events.push_back(Array::make(MESSAGE, peer, bytes, received_us));
        return bytes.size();
    }

protected:
    static void _bind_methods() {
        ClassDB::bind_method(D_METHOD("listen", "port"), &GnsEndpoint::listen);
        ClassDB::bind_method(D_METHOD("connect_to", "address", "port"), &GnsEndpoint::connect_to);
        ClassDB::bind_method(D_METHOD("send", "peer", "flow", "bytes"), &GnsEndpoint::send);
        ClassDB::bind_method(D_METHOD("send_many", "peers", "flow", "bytes"), &GnsEndpoint::send_many);
        ClassDB::bind_method(D_METHOD("flush"), &GnsEndpoint::flush);
        ClassDB::bind_method(D_METHOD("poll", "max_messages"), &GnsEndpoint::poll, DEFVAL(MAX_POLL_MESSAGES));
        ClassDB::bind_method(D_METHOD("disconnect_peer", "peer", "reason"), &GnsEndpoint::disconnect_peer);
        ClassDB::bind_method(D_METHOD("close"), &GnsEndpoint::close);
        ClassDB::bind_method(D_METHOD("get_port"), &GnsEndpoint::get_port);
        ClassDB::bind_method(D_METHOD("is_connected"), &GnsEndpoint::is_connected);
        ClassDB::bind_method(D_METHOD("get_ping"), &GnsEndpoint::get_ping);
    }
public:
    GnsEndpoint() { endpoints.insert(this); }
    ~GnsEndpoint() {
        close();
        endpoints.erase(this);
        if (endpoints.empty() && sockets) {
            GameNetworkingSockets_Kill();
            sockets = nullptr;
        }
    }
    int listen(int requested_port) {
        close();
        if (requested_port < 0 || requested_port > 65535) return ERR_INVALID_PARAMETER;
        if (!open_group()) return ERR_CANT_CREATE;
        SteamNetworkingIPAddr address{};
        address.m_port = requested_port;
        listener = sockets->CreateListenSocketIP(address, 0, nullptr);
        if (listener != k_HSteamListenSocket_Invalid) return OK;
        close();
        return ERR_CANT_CREATE;
    }
    int connect_to(const String &host, int requested_port) {
        close();
        SteamNetworkingIPAddr address;
        if (requested_port <= 0 || requested_port > 65535 || !address.ParseString(host.utf8().get_data())) return ERR_INVALID_PARAMETER;
        address.m_port = requested_port;
        if (!open_group()) return ERR_CANT_CREATE;
        auto handle = sockets->ConnectByIPAddress(address, 0, nullptr);
        if (handle == k_HSteamNetConnection_Invalid) {
            close();
            return ERR_CANT_CONNECT;
        }
        add_peer(SERVER_PEER, handle);
        return OK;
    }
    int send(int peer, int flow, const PackedByteArray &bytes) {
        gns::Payload payload;
        return send_to(peer, flow, bytes, payload);
    }
    PackedInt32Array send_many(const PackedInt32Array &targets, int flow, const PackedByteArray &bytes) {
        PackedInt32Array errors;
        errors.resize(targets.size());
        gns::Payload payload;
        for (int64_t i = 0; i < targets.size(); ++i) errors.set(i, send_to(targets[i], flow, bytes, payload));
        return errors;
    }
    void flush() {
        for (auto next = connections.begin(); next != connections.end();) {
            auto current = next++;
            service(current->first, current->second);
        }
    }
    Array poll(int max_messages = MAX_POLL_MESSAGES) {
        if (group == k_HSteamNetPollGroup_Invalid) return {};
        const auto started = Time::get_singleton()->get_ticks_usec();
        sockets->RunCallbacks();
        const int limit = std::clamp(max_messages, 0, MAX_POLL_MESSAGES);
        size_t wire_bytes = 0, payload_bytes = 0;
        for (int processed = 0; processed < limit; ++processed) {
            SteamNetworkingMessage_t *message;
            if (sockets->ReceiveMessagesOnPollGroup(group, &message, 1) <= 0) break;
            wire_bytes += message->m_cbSize;
            payload_bytes += receive(*message);
            message->Release();
            if (wire_bytes >= MAX_POLL_BYTES || payload_bytes >= MAX_POLL_BYTES ||
                Time::get_singleton()->get_ticks_usec() - started >= MAX_POLL_USEC) break;
        }
        flush();
        return std::exchange(events, Array());
    }
    void disconnect_peer(int peer, const String &reason) {
        auto found = connections.find(peer);
        if (found == connections.end()) return;
        close_peer(found, reason.utf8().get_data());
        events.push_back(Array::make(DISCONNECTED, peer, 0, reason));
    }
    void close() {
        while (!connections.empty()) close_peer(connections.begin());
        if (listener != k_HSteamListenSocket_Invalid) {
            sockets->CloseListenSocket(listener);
            listener = k_HSteamListenSocket_Invalid;
        }
        if (group != k_HSteamNetPollGroup_Invalid) sockets->DestroyPollGroup(group);
        group = k_HSteamNetPollGroup_Invalid;
        events.clear();
    }
    int get_port() const {
        SteamNetworkingIPAddr address;
        return listener != k_HSteamListenSocket_Invalid &&
            sockets->GetListenSocketAddress(listener, &address) ? address.m_port : 0;
    }
    bool is_connected() const {
        auto peer = connections.find(SERVER_PEER);
        return peer != connections.end() && peer->second.connected;
    }
    int get_ping() const {
        auto peer = connections.find(SERVER_PEER);
        if (peer == connections.end() || !peer->second.connected) return -1;
        SteamNetConnectionRealTimeStatus_t state;
        return sockets->GetConnectionRealTimeStatus(peer->second.handle, &state, 0, nullptr) == k_EResultOK &&
            state.m_eState == k_ESteamNetworkingConnectionState_Connected ? state.m_nPing : -1;
    }
};

static void initialize_gns(ModuleInitializationLevel level) {
    if (level == MODULE_INITIALIZATION_LEVEL_SCENE) ClassDB::register_class<GnsEndpoint>();
}
extern "C" GDExtensionBool GDE_EXPORT gns_init(GDExtensionInterfaceGetProcAddress get_proc_address,
        GDExtensionClassLibraryPtr library, GDExtensionInitialization *initialization) {
    GDExtensionBinding::InitObject init(get_proc_address, library, initialization);
    init.register_initializer(initialize_gns);
    init.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);
    return init.init();
}
