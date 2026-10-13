"""Network stalls require a complete combat window with healthy application frames."""
from copy import deepcopy
import unittest
from run_matrix import summarize_network


def measured_case():
    sample = {"start":100, "end":120, "complete":True, "observed_seconds":20,
              "stall_seconds":1, "longest_stall_seconds":0.6, "max_frame_ms":20,
              "baseline_changes":0, "outage_seconds":0, "state_gaps_ms":[33,66], "ping_ms":[50]}
    return {"count":2, "failures":[], "network_sample":{"server":{
        "max_frame_ms":18, "input_ticks":2400, "input_missing_ticks":24}},
        "clients":[{"index":i,"network_sample":deepcopy(sample)} for i in range(2)]}


class NetworkMetricsTests(unittest.TestCase):
    def test_healthy_wall_time_is_the_denominator(self):
        case = measured_case()
        case['clients'][1]['network_sample']['stall_seconds'] = 2
        result = summarize_network(case)
        self.assertEqual(result['valid_clients'], 2)
        self.assertAlmostEqual(result['stall_fraction'], 3/40)
        self.assertAlmostEqual(result['input_missing_fraction'], 0.01)

    def test_client_long_frame_excludes_its_whole_window(self):
        case = measured_case()
        case['clients'][0]['network_sample']['max_frame_ms'] = 80
        result = summarize_network(case)
        self.assertEqual(result['valid_clients'], 1)
        self.assertEqual(result['observed_seconds'], 20)
        self.assertIsNone(result['input_missing_fraction'])
        self.assertEqual(result['excluded'], [{'index':0,'reasons':['client_long_frame']}])

    def test_server_long_frame_is_not_zero_network_stall(self):
        case = measured_case()
        case['network_sample']['server']['max_frame_ms'] = 80
        result = summarize_network(case)
        self.assertEqual(result['valid_clients'], 0)
        self.assertIsNone(result['stall_fraction'])

    def test_rebaseline_and_incomplete_samples_are_separate(self):
        case = measured_case()
        case['clients'][0]['network_sample']['baseline_changes'] = 1
        case['clients'][1]['network_sample']['complete'] = False
        result = summarize_network(case)
        self.assertIsNone(result['stall_fraction'])
        self.assertEqual([r['reasons'] for r in result['excluded']], [['baseline_changed'], ['incomplete_window']])


if __name__ == '__main__':
    unittest.main(verbosity=2)
