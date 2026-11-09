import unittest

import routing_refit_v91 as v91


class FamilyFoldTests(unittest.TestCase):
    def test_same_family_stays_in_one_fold(self):
        rows = [dict(text=f'Your parcel {i} is arriving tomorrow at the depot') for i in range(4)]
        rows += [dict(text='completely different appointment note for the clinic'), dict(text='午後のお支払いについてのご案内です')]
        folds = v91.family_folds(rows, 3)
        self.assertEqual(len(set(folds[:4])), 1)
        self.assertEqual(set(folds), {0, 1, 2})

    def test_folds_are_deterministic(self):
        rows = [dict(text=f'message number {w}') for w in ('alpha', 'bravo', 'charlie', 'delta', 'echo', 'foxtrot')]
        self.assertEqual(v91.family_folds(rows, 2), v91.family_folds(rows, 2))


class PassesTests(unittest.TestCase):
    reference = dict(policyActionCorrect=100, harmfulCaught=10, normalToJunk=2)

    def test_equal_passes(self):
        self.assertTrue(v91.passes(dict(self.reference), self.reference))

    def test_each_metric_can_fail(self):
        for change in (dict(policyActionCorrect=99), dict(harmfulCaught=9), dict(normalToJunk=3)):
            self.assertFalse(v91.passes({**self.reference, **change}, self.reference), change)


class EligibilityTests(unittest.TestCase):
    def test_unresolved_and_scenario_rows_cannot_fit(self):
        self.assertFalse(v91.fit_eligible(dict(filterReview=dict(kind='unresolved', inputForm='sms'))))
        self.assertFalse(v91.fit_eligible(dict(filterReview=dict(kind='normal', inputForm='scenario-description'))))
        self.assertTrue(v91.fit_eligible(dict(filterReview=dict(kind='normal', inputForm='sms'))))


class HoldoutIsolationTests(unittest.TestCase):
    def test_rows_sharing_holdout_family_never_fit(self):
        review = dict(kind='normal', inputForm='sms')
        holdout = [dict(text='Your parcel 12 is arriving tomorrow at the depot')]
        rows = [dict(text='Your parcel 99 is arriving tomorrow at the depot', filterReview=review),
                dict(text='completely different clinic appointment note', filterReview=review)]
        self.assertEqual(v91.fit_indices(rows, v91.protected_keys([holdout])), [1])


class ScheduleTests(unittest.TestCase):
    def test_learning_rates_warm_then_decay_to_floor(self):
        self.assertAlmostEqual(v91.head_lr(50, 504), .001)
        self.assertAlmostEqual(v91.head_lr(504, 504), .0001)
        self.assertAlmostEqual(v91.gate_lr(16, 288), .02)
        self.assertAlmostEqual(v91.gate_lr(288, 288), .002)


if __name__ == '__main__':
    unittest.main()
