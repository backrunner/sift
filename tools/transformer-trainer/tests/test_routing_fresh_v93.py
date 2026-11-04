import sys
from pathlib import Path
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import routing_fresh_v93 as study


class PathTests(unittest.TestCase):
    def test_v91_paths_survive_replay_redirect(self):
        original = study.v91.OUT
        try:
            study.v91.OUT = study.OUT
            self.assertEqual(study.V91_OUT, original)
            self.assertIn(study.feature_path('sam', 321, 'union').parent, (original, study.OUT))
        finally:
            study.v91.OUT = original


class QualifyTests(unittest.TestCase):
    reference = dict(policyActionCorrect=80, harmfulCaught=20, normalToJunk=1)
    fixed = dict(classification=dict(strictAction=482), promotion=dict(tolerantAction=150), **{'billing-card': dict(strictAction=30)})

    def test_equal_qualifies(self):
        self.assertTrue(study.qualifies(dict(self.reference), self.reference, self.fixed, self.fixed))

    def test_fresh_costs_fail(self):
        for change in (dict(policyActionCorrect=79), dict(harmfulCaught=19), dict(normalToJunk=2)):
            self.assertFalse(study.qualifies({**self.reference, **change}, self.reference, self.fixed, self.fixed), change)

    def test_fixed_suite_costs_fail(self):
        for name, key, value in (('classification', 'strictAction', 481), ('promotion', 'tolerantAction', 148), ('billing-card', 'strictAction', 29)):
            self.assertFalse(study.qualifies(self.reference, self.reference, {**self.fixed, name: {key: value}}, self.fixed), name)

    def test_rank_uses_worst_seed(self):
        a = [dict(policyActionCorrect=90, harmfulCaught=20, normalToJunk=0), dict(policyActionCorrect=70, harmfulCaught=20, normalToJunk=0)]
        b = [dict(policyActionCorrect=80, harmfulCaught=20, normalToJunk=0)] * 2
        self.assertGreater(study.rank(b), study.rank(a))


if __name__ == '__main__':
    unittest.main()
