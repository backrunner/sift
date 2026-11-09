import sys
from pathlib import Path
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import author_cjk_v96 as author
import rebuild_v96 as study


def side(dev=2, action=60, link=5, real=8, strict=480, promo=150, billing=30):
    return dict(development=dict(errors={'harmful missed': dev}, policyActionCorrect=action), fresh=dict(errors={'harmful missed': link}),
                real=dict(errors={'normal to junk': real}), classification=dict(strictAction=strict), promotion=dict(tolerantAction=promo), **{'billing-card': dict(strictAction=billing)})


class SignalTests(unittest.TestCase):
    def test_equal_passes_with_margins(self):
        self.assertTrue(study.improves(side(), side()))
        self.assertTrue(study.improves(side(action=59, link=6, real=9, strict=478), side()))

    def test_each_cost_fails(self):
        for change in (dict(dev=3), dict(action=58), dict(link=7), dict(real=10), dict(strict=477), dict(promo=148), dict(billing=29)):
            self.assertFalse(study.improves(side(**change), side()), change)

    def test_novelty_bar_and_budget(self):
        self.assertTrue(study.novelty_passes(39, 192)); self.assertFalse(study.novelty_passes(38, 192))
        updates = study.base.window_plan(4486, 32, 4)['updatesPerEpoch'] * study.EPOCHS
        self.assertLess(abs(updates - 768), 32)


class AuthoringTests(unittest.TestCase):
    def test_sizes_and_shape(self):
        counts = {}
        for role, _, _, _, events in author.cases():
            counts[role] = counts.get(role, 0) + 2 * len(events)
            for event in events: self.assertEqual(len(event), 3)
        self.assertEqual(counts, dict(training=192, development=64))


if __name__ == '__main__':
    unittest.main()
