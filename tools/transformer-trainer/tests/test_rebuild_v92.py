import sys
from pathlib import Path
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import author_contrast_v92 as author
import rebuild_v92 as study


class RebuildV92Tests(unittest.TestCase):
    def test_novelty_bar(self):
        self.assertTrue(study.novelty_passes(58, 288))
        self.assertFalse(study.novelty_passes(57, 288))

    def test_development_signal_rejects_each_cost(self):
        ref = dict(policyActionCorrect=80, fineCorrect=70, normalToJunk=1)
        self.assertTrue(study.development_signal(dict(ref), ref))
        for change in (dict(policyActionCorrect=79), dict(fineCorrect=69), dict(normalToJunk=2)):
            self.assertFalse(study.development_signal({**ref, **change}, ref), change)

    def test_budget_stays_near_v88_update_count(self):
        updates = study.base.window_plan(4294, 32, 4)['updatesPerEpoch'] * study.SPEC['epochs']
        self.assertLess(abs(updates - 768), 32)


class AuthoringTests(unittest.TestCase):
    def test_families_are_unique_and_trilingual(self):
        cases = author.cases()
        self.assertEqual(len({c[1] for c in cases}), len(cases))
        for _, _, _, _, events in cases:
            for event in events:
                self.assertEqual(len(event), 4)

    def test_roles_keep_expected_sizes(self):
        counts = {}
        for role, _, _, _, events in author.cases(): counts[role] = counts.get(role, 0) + 3 * len(events)
        self.assertEqual(counts, dict(training=288, development=96))

    def test_each_family_contrasts_more_than_one_label(self):
        for _, name, _, _, events in author.cases():
            self.assertGreater(len({e[0] for e in events}), 1, name)


if __name__ == '__main__':
    unittest.main()
