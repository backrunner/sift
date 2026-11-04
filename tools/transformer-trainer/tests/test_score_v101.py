from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import score_v101 as score


class ImprovesTests(unittest.TestCase):
    side = dict(serious=5, errors=dict(a=5, b=2))
    fixed = dict(classification=dict(strictAction=486), promotion=dict(tolerantAction=150), **{'billing-card': dict(strictAction=30)})
    comparison = dict(seriousFewerInA=dict(high=4))

    def check(self, candidate=None, fixed=None, comparison=None):
        return score.improves(comparison or self.comparison, candidate or self.side, self.side, fixed or self.fixed, self.fixed)

    def test_equal_passes(self):
        self.assertTrue(self.check())

    def test_more_serious_or_more_errors_fail(self):
        self.assertFalse(self.check(dict(serious=6, errors=self.side['errors'])))
        self.assertFalse(self.check(dict(serious=5, errors=dict(a=8))))

    def test_interval_wholly_against_fails(self):
        self.assertFalse(self.check(comparison=dict(seriousFewerInA=dict(high=-1))))

    def test_floors(self):
        self.assertTrue(self.check(fixed={**self.fixed, 'classification': dict(strictAction=484)}))
        self.assertFalse(self.check(fixed={**self.fixed, 'classification': dict(strictAction=483)}))
        self.assertFalse(self.check(fixed={**self.fixed, 'promotion': dict(tolerantAction=148)}))
        self.assertFalse(self.check(fixed={**self.fixed, 'billing-card': dict(strictAction=29)}))


if __name__ == '__main__':
    unittest.main()
