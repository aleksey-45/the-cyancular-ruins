"""Deterministic time-varying UDP link with burst loss and a finite bottleneck queue."""
import ctypes
import heapq
import json
import math
import os
from pathlib import Path
import random
import selectors
import socket
import threading
import time

PROFILES = json.loads(Path(__file__).with_name("link_profiles.json").read_text(encoding="utf-8"))


def quantiles(values):
    if not values:
        return {"mean": 0, "p50": 0, "p95": 0, "p99": 0, "max": 0}
    ordered = sorted(values)
    return {"mean": sum(values) / len(values), "p50": ordered[int((len(ordered)-1)*0.5)],
            "p95": ordered[int((len(ordered)-1)*0.95)], "p99": ordered[int((len(ordered)-1)*0.99)],
            "max": ordered[-1]}


def traffic_rates(packets, seconds):
    """UDP payload plus 28-byte IPv4/UDP headers; peaks use rolling windows."""
    ordered = sorted((t, size + 28) for t, size in packets)
    result = {"packets": len(ordered), "ipv4_bytes": sum(size for _, size in ordered)}
    result["mean_kbps"] = result["ipv4_bytes"] * 8 / seconds / 1000
    for window, key in ((1.0, "peak_1s_kbps"), (0.1, "peak_100ms_kbps")):
        first, total, peak = 0, 0, 0
        for t, size in ordered:
            total += size
            while ordered[first][0] <= t - window:
                total -= ordered[first][1]
                first += 1
            peak = max(peak, total)
        result[key] = peak * 8 / window / 1000
    return result


class Conditions:
    def __init__(self, seed, profile, rtt, jitter, loss, bandwidth_kbps):
        self.profile = PROFILES[profile] if profile else None
        self.rtt, self.jitter, self.loss = rtt, jitter, loss
        self.bandwidth = bandwidth_kbps
        rng = random.Random(seed)
        self.phases = [rng.uniform(0, math.tau) for _ in range(3)]
        self.periods = [rng.uniform(5, 11) for _ in range(3)]

    def at(self, seconds):
        waves = [(1 + math.sin(math.tau*seconds/period + phase))/2
                 for period, phase in zip(self.periods, self.phases)]
        if self.profile:
            low, high = self.profile["rtt_ms"]
            rtt = low + (high-low)*waves[0]
            low, high = self.profile["loss"]
            loss = low + (high-low)*waves[1]
        else:
            rtt, loss = self.rtt, self.loss
        bandwidth = self.bandwidth*(0.5 + 0.5*waves[2]) if self.bandwidth else 0
        return rtt, loss, bandwidth


class LagLink:
    def __init__(self, port, rtt=0, jitter=0, loss=0, seed=1000, profile=None,
                 bandwidth_kbps=0, queue_ms=100, warmup=False):
        self.front = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.front.bind(("127.0.0.1", 0))
        self.port = self.front.getsockname()[1]
        self.back = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.back.bind(("127.0.0.1", 0))
        if os.name == "nt":
            ctypes.windll.winmm.timeBeginPeriod(1)
            enabled, returned = ctypes.c_ulong(0), ctypes.c_ulong(0)
            for sock in (self.front, self.back):
                ctypes.windll.ws2_32.WSAIoctl(ctypes.c_size_t(sock.fileno()), 0x9800000C,
                    ctypes.byref(enabled), 4, None, 0, ctypes.byref(returned), None, None)
        self.target, self.client = ("127.0.0.1", port), None
        self.profile, self.queue_ms = profile, queue_ms
        self.conditions = Conditions(seed, profile, rtt, jitter, loss, bandwidth_kbps)
        self.rng = [random.Random(seed + 31), random.Random(seed + 79)]
        self.bad = [False, False]
        self.tx_free = [0.0, 0.0]
        self.started = time.perf_counter()
        self.started_wall = time.time()
        self.enabled = not warmup
        self.condition_window = None
        self.stats = [{"received": 0, "received_bytes": 0, "delivered": 0, "bytes": 0, "random_loss": 0,
                       "queue_loss": 0, "blackout_loss": 0, "max_pending": 0,
                       "queue_ms": [], "serialization_ms": [], "propagation_ms": [], "actual_delay_ms": [],
                       "target_loss": [], "trace": [], "packet_trace": []} for _ in range(2)]
        self.stall_until = self.blackout_from = self.blackout_until = 0.0
        self.stalled_packets = self.blackout_packets = 0
        self.error = None
        self.stop = threading.Event()
        self.thread = threading.Thread(target=self.run, daemon=True)
        self.thread.start()

    def disturb(self):
        now = time.perf_counter()
        self.stall_until = now + 0.75
        self.blackout_from, self.blackout_until = now + 1.9, now + 2.15

    def schedule(self, start, end):
        self.condition_window = (start, end)
        self.enabled = True

    def lost(self, direction, probability):
        rng = self.rng[direction]
        if self.profile:
            # Three packets per bad-state visit on average; stationary loss is probability.
            if self.bad[direction]:
                self.bad[direction] = rng.random() >= 1/3
            else:
                self.bad[direction] = rng.random() < probability/(3*(1-probability))
            return self.bad[direction]
        return rng.random() < probability

    def run(self):
        selector = selectors.DefaultSelector()
        pending, serial = [], 0
        counts = [0, 0]
        for sock in (self.front, self.back):
            sock.setblocking(False)
            selector.register(sock, selectors.EVENT_READ)
        try:
            while not self.stop.is_set():
                for key, _ in selector.select(0.001):
                    packet, addr = key.fileobj.recvfrom(65535)
                    direction = 0 if key.fileobj == self.front else 1
                    if direction == 0:
                        self.client = addr
                        out, target = self.back, self.target
                    else:
                        out, target = self.front, self.client
                    if target is None:
                        continue
                    now = time.perf_counter()
                    elapsed = now-self.started
                    wall = self.started_wall + elapsed
                    active = self.enabled and (self.condition_window is None or self.condition_window[0] <= wall < self.condition_window[1])
                    condition_time = wall-self.condition_window[0] if self.condition_window else elapsed
                    rtt, loss, bandwidth = self.conditions.at(condition_time) if active else (0, 0, 0)
                    stats = self.stats[direction]
                    stats["received"] += 1
                    stats["received_bytes"] += len(packet)
                    stats["packet_trace"].append([elapsed, len(packet)])
                    stats["target_loss"].append(loss)
                    if not stats["trace"] or int(stats["trace"][-1]["seconds"]) < int(elapsed):
                        stats["trace"].append({"seconds": round(elapsed, 3), "rtt_ms": rtt,
                                               "loss": loss, "bandwidth_kbps": bandwidth})
                    if self.blackout_from <= now < self.blackout_until:
                        self.blackout_packets += 1
                        stats["blackout_loss"] += 1
                        continue
                    randomly_lost = active and self.lost(direction, loss)
                    queue = max(0, self.tx_free[direction]-now)
                    serialization = (len(packet)+28)*8/(bandwidth*1000) if bandwidth else 0
                    budget = max(self.queue_ms/1000, 2*(1536+28)*8/(bandwidth*1000)) if bandwidth else 0
                    if bandwidth and queue+serialization > budget:
                        stats["queue_loss"] += 1
                        continue
                    departure = max(now, self.tx_free[direction])+serialization
                    self.tx_free[direction] = departure
                    stats["queue_ms"].append(queue*1000)
                    stats["serialization_ms"].append(serialization*1000)
                    if randomly_lost:
                        stats["random_loss"] += 1
                        continue
                    rng = self.rng[direction]
                    if not active:
                        propagation = 0
                    elif self.profile:
                        low, high = PROFILES[self.profile]["rtt_ms"]
                        propagation = min(high/2, max(low/2, rtt/2+rng.uniform(-2, 2))) / 1000
                    else:
                        propagation = max(0, rtt/2+rng.uniform(-self.conditions.jitter, self.conditions.jitter))/1000
                    due = departure+propagation
                    if now < self.stall_until:
                        self.stalled_packets += 1
                        due = max(due, self.stall_until)
                    serial += 1
                    counts[direction] += 1
                    stats["max_pending"] = max(stats["max_pending"], counts[direction])
                    stats["propagation_ms"].append(propagation*1000)
                    heapq.heappush(pending, (due, serial, direction, out, target, packet, now))
                now = time.perf_counter()
                while pending and pending[0][0] <= now and now >= self.stall_until:
                    _, _, direction, out, target, packet, received = heapq.heappop(pending)
                    out.sendto(packet, target)
                    counts[direction] -= 1
                    stats = self.stats[direction]
                    stats["delivered"] += 1
                    stats["bytes"] += len(packet)
                    stats["actual_delay_ms"].append((time.perf_counter()-received)*1000)
        except Exception as error:
            self.error = repr(error)
        finally:
            selector.close()

    def report(self):
        result = []
        for direction, stats in zip(("uplink", "downlink"), self.stats):
            item = {key: value for key, value in stats.items() if not isinstance(value, list)}
            item.update(direction=direction, trace=list(stats["trace"]), packet_trace=list(stats["packet_trace"]))
            for key in ("queue_ms", "serialization_ms", "propagation_ms", "actual_delay_ms", "target_loss"):
                item[key] = quantiles(stats[key])
            item["random_loss_fraction"] = stats["random_loss"]/stats["received"] if stats["received"] else 0
            item["pending"] = stats["received"] - sum(stats[key] for key in ("delivered", "random_loss", "queue_loss", "blackout_loss"))
            result.append(item)
        return {"directions": result, "error": self.error, "started_wall_seconds": self.started_wall,
                "condition_window": self.condition_window}

    def close(self):
        self.stop.set()
        self.thread.join()
        self.front.close()
        self.back.close()
        if os.name == "nt":
            ctypes.windll.winmm.timeEndPeriod(1)


def summarize_network(case):
    measurement = case.get("network_sample")
    if not measurement:
        return None
    server = measurement["server"]
    valid, excluded = [], []
    for client in case["clients"]:
        sample = client.get("network_sample")
        reasons = []
        if case["failures"]: reasons.append("run_failed")
        if server is None: reasons.append("server_sample_missing")
        elif server["max_frame_ms"] > 50: reasons.append("server_long_frame")
        if sample is None:
            reasons.append("client_sample_missing")
        else:
            if not sample["complete"] or sample["observed_seconds"] < sample["end"]-sample["start"]-0.1:
                reasons.append("incomplete_window")
            if sample["max_frame_ms"] > 50: reasons.append("client_long_frame")
            if sample["baseline_changes"]: reasons.append("baseline_changed")
            if sample["outage_seconds"]: reasons.append("disconnected")
        if reasons: excluded.append({"index":client["index"], "reasons":reasons})
        else: valid.append(sample)
    seconds = sum(s["observed_seconds"] for s in valid)
    stalls = sum(s["stall_seconds"] for s in valid)
    return {"valid_clients":len(valid), "expected_clients":case["count"], "excluded":excluded,
            "observed_seconds":seconds, "stall_seconds":stalls,
            "stall_fraction":stalls/seconds if seconds else None,
            "longest_stall_seconds":max((s["longest_stall_seconds"] for s in valid), default=None),
            "server_max_frame_ms":server["max_frame_ms"] if server else None,
            "client_max_frame_ms":[c["network_sample"]["max_frame_ms"] for c in case["clients"] if "network_sample" in c],
            "input_missing_fraction":server["input_missing_ticks"]/server["input_ticks"] if server and server["input_ticks"] and len(valid) == case["count"] else None,
            "state_gap_ms":quantiles([g for s in valid for g in s["state_gaps_ms"]]) if valid else None,
            "ping_ms":quantiles([p for s in valid for p in s["ping_ms"]]) if valid else None}



def summarize(case):
    settings = (case.get("network_sample") or {}).get("settings")
    duration = settings["end"]-settings["start"] if settings else case["elapsed_seconds"]
    traffic = {"server_upload":[], "server_download":[]}
    for link in case["links"]:
        for direction in link["directions"]:
            key = "server_upload" if direction["direction"] == "downlink" else "server_download"
            traffic[key].extend((link["started_wall_seconds"]+t,size) for t,size in direction["packet_trace"]
                                if not settings or settings["start"] <= link["started_wall_seconds"]+t < settings["end"])
    return {"count":case["count"], "profile":case["profile"], "seed":case["seed"],
            "bandwidth_kbps":case["bandwidth_kbps"],
            "failures":case["failures"], "stop_reason":case["stop_reason"],
            "elapsed_seconds":case["elapsed_seconds"], "network":summarize_network(case),
            "sender_offered_ipv4_kbps":{key:traffic_rates(packets,duration) for key,packets in traffic.items()}}
