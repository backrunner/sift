import sys
from pathlib import Path
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import rebuild_v89 as study


def arm(fine, action, junk, low_action=90):
    return dict(selection=dict(fineCorrect=fine, policyActionCorrect=action, normalToJunk=junk, actionScored=1000),
                history=dict(lowSimilarity=dict(policyActionCorrect=low_action, actionScored=100)))


class RebuildV89Tests(unittest.TestCase):
    REFERENCE = arm(800, 900, 1)

    def test_data_signal_needs_fine_gain(self):
        self.assertTrue(study.data_signal(arm(805, 900, 1), self.REFERENCE))
        self.assertFalse(study.data_signal(arm(804, 900, 1), self.REFERENCE))

    def test_data_signal_rejects_action_safety_and_history_costs(self):
        self.assertFalse(study.data_signal(arm(810, 899, 1), self.REFERENCE))
        self.assertFalse(study.data_signal(arm(810, 900, 4), self.REFERENCE))
        self.assertFalse(study.data_signal(arm(810, 900, 1, low_action=89), self.REFERENCE))

    def test_weights_reuse_cells_and_refuse_unknown_cells(self):
        cells = {('spam', 'en'): 2.}
        self.assertEqual(study.weights_for([{'label': 'spam', 'language': 'en'}], cells), [2.])
        with self.assertRaises(ValueError):
            study.weights_for([{'label': 'spam', 'language': 'ja'}], cells)

    def test_missing_vietnamese_cell_uses_median_vietnamese_weight(self):
        cells = {('a', 'vi'): 1., ('b', 'vi'): 3., ('c', 'vi'): 5., ('a', 'en'): 9.}
        self.assertEqual(study.weights_for([{'label': 'z', 'language': 'vi'}], cells), [3.])

    def test_budgets_stay_near_v88_update_count(self):
        counts = {'free-v52': 3457, 'free-v89': 5010}
        for name, rows in counts.items():
            updates = study.base.window_plan(rows, 32, 4)['updatesPerEpoch'] * study.ARMS[name]['epochs']
            self.assertLess(abs(updates - 768), 32)


if __name__ == '__main__': unittest.main()
