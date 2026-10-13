"""Behavior checks for fluctuating UDP links and finite bottleneck queues."""
import socket
import time
import unittest
from network_link import Conditions, LagLink, PROFILES, traffic_rates


def free_port():
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


class LinkTests(unittest.TestCase):
    def test_impairment_is_only_active_inside_the_scheduled_window(self):
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as backend, socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as client:
            backend.bind(("127.0.0.1", 0))
            backend.settimeout(2)
            client.settimeout(2)
            link = LagLink(backend.getsockname()[1], rtt=160, warmup=True)
            def echo():
                start = time.perf_counter()
                client.sendto(b"probe", ("127.0.0.1", link.port))
                payload, peer = backend.recvfrom(65535)
                backend.sendto(payload, peer)
                self.assertEqual(client.recv(65535), b"probe")
                return time.perf_counter()-start
            try:
                self.assertLess(echo(), 0.1)
                begin, end = time.time()+0.05, time.time()+0.65
                link.schedule(begin, end)
                time.sleep(0.07)
                self.assertGreaterEqual(echo(), 0.16)
                time.sleep(max(0, end-time.time()+0.02))
                self.assertLess(echo(), 0.1)
            finally:
                link.close()

    def test_bandwidth_separates_short_bursts_from_one_second_peak(self):
        measured = traffic_rates([(0, 1000), (0.02, 1000), (0.12, 1000), (1.5, 1000)], 2)
        self.assertAlmostEqual(measured["mean_kbps"], 16.448)
        self.assertAlmostEqual(measured["peak_1s_kbps"], 24.672)
        self.assertAlmostEqual(measured["peak_100ms_kbps"], 164.48)

    def test_profiles_are_bounded_fluctuating_and_repeatable(self):
        self.assertEqual(len(PROFILES), 6)
        for name, profile in PROFILES.items():
            conditions = Conditions(1000, name, 0, 0, 0, 128)
            repeated = Conditions(1000, name, 0, 0, 0, 128)
            samples = [conditions.at(i/10) for i in range(600)]
            self.assertEqual(samples, [repeated.at(i/10) for i in range(600)])
            for column, bounds in enumerate((profile["rtt_ms"], profile["loss"], [64, 128])):
                values = [s[column] for s in samples]
                self.assertGreaterEqual(min(values), bounds[0])
                self.assertLessEqual(max(values), bounds[1])
                self.assertGreater(max(values)-min(values), (bounds[1]-bounds[0])*0.95)

    def test_loss_rate_and_bursts(self):
        link = LagLink(free_port(), profile="over500ms")
        try:
            losses = [link.lost(0, 0.1) for _ in range(100000)]
            self.assertAlmostEqual(sum(losses)/len(losses), 0.1, delta=0.005)
            adjacent = sum(a and b for a, b in zip(losses, losses[1:]))/sum(losses)
            self.assertGreater(adjacent, 0.6)
            self.assertLess(adjacent, 0.73)
        finally:
            link.close()

    def test_delay_payload_and_finite_queue(self):
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as backend, socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as client:
            backend.bind(("127.0.0.1", 0))
            backend.settimeout(3)
            client.settimeout(3)
            link = LagLink(backend.getsockname()[1], rtt=40, bandwidth_kbps=128)
            try:
                for payload in (b"input", bytes(range(256))*5+b"large"*24):
                    start = time.perf_counter()
                    client.sendto(payload, ("127.0.0.1", link.port))
                    received, peer = backend.recvfrom(65535)
                    self.assertEqual(received, payload)
                    backend.sendto(received, peer)
                    self.assertEqual(client.recv(65535), payload)
                    self.assertGreaterEqual(time.perf_counter()-start, 0.04)
                for direction in link.report()["directions"]:
                    self.assertEqual([size for _, size in direction["packet_trace"]], [5, 1400])
                for _ in range(100):
                    client.sendto(b"x"*1400, ("127.0.0.1", link.port))
                time.sleep(0.3)
                stats = link.report()["directions"][0]
                self.assertGreater(stats["queue_loss"], 80)
                self.assertLess(stats["queue_ms"]["max"], 400)
                self.assertLessEqual(stats["max_pending"], 4)
                self.assertIsNone(link.error)
            finally:
                link.close()



if __name__ == "__main__":
    unittest.main(verbosity=2)
