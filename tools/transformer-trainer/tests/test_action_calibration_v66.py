import copy
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from action_calibration_v66 import FLOORS, SEEDS, changes, qualify, select_floor, validate_design
from author_action_calibration_v66 import cases


def comparison(recovered=(), introduced=(), new_business=()):
    return dict(recovered=list(recovered), introduced=list(introduced),
                newMissToBusiness=list(new_business), unscoredChanges=[])


def records():
    return [dict(floor=f, calibration={str(s): dict(actionCorrect=65, scored=72,
        comparison=comparison(recovered=[0])) for s in SEEDS}) for f in FLOORS]


class ActionCalibrationTests(unittest.TestCase):
    def test_grouped_design_and_duplicate_family_rejected(self):
        validate_design(cases())
        bad = copy.deepcopy(cases()); bad[-1] = (bad[-1][0], bad[0][1], *bad[-1][2:])
        with self.assertRaises(ValueError): validate_design(bad)

    def test_shared_floor_protects_weaker_seed_and_breaks_ties_conservatively(self):
        r = records()
        self.assertEqual(select_floor(r), .995)
        r[0]['calibration']['321']['actionCorrect'] = 72
        r[0]['calibration']['322']['actionCorrect'] = 64
        self.assertEqual(select_floor(r), .995)
        r[1]['calibration']['321']['actionCorrect'] = 66
        r[1]['calibration']['322']['actionCorrect'] = 66
        self.assertEqual(select_floor(r), .95)

    def test_new_error_or_missed_harm_to_business_is_not_hidden_by_gain(self):
        r = records()
        r[-1]['calibration']['322']['comparison']['introduced'] = [9]
        self.assertEqual(select_floor(r), .99)
        for row in r:
            row['calibration']['321']['comparison']['newMissToBusiness'] = [8]
        self.assertIsNone(select_floor(r))

    def test_missing_grid_or_noncalibration_scores_cannot_select(self):
        with self.assertRaises(ValueError): select_floor(records()[:-1])
        r = records(); r[0]['development'] = {'accuracy': .99}
        with self.assertRaises(ValueError): select_floor(r)
        r = records(); r[0]['calibration']['323'] = r[0]['calibration']['321']
        with self.assertRaises(ValueError): select_floor(r)

    def test_no_gain_keeps_leaf(self):
        r = records()
        for candidate in r:
            for seed in candidate['calibration'].values(): seed['comparison']['recovered'] = []
        self.assertIsNone(select_floor(r))

    def test_runtime_change_contract_distinguishes_rescue_and_false_routing(self):
        rows = [dict(label='__sift_abstain__', filterReview=dict(kind='normal', inputForm='sms-text')),
                dict(label='spam', filterReview=dict(kind='harmful', inputForm='sms-text'))]
        old = [dict(index=i, label=r['label'], rawPrediction='finance.bank', confidence=.4,
                    engineAction='none', expectedAction=('none' if i == 0 else 'junk'),
                    fallbackReason='none') for i, r in enumerate(rows)]
        new = [{**p, 'engineAction': 'transaction'} for p in old]
        c = changes(rows, old, new)
        self.assertEqual(c['introduced'], [0]); self.assertEqual(c['newMissToBusiness'], [1])
        new[0]['confidence'] = .8
        with self.assertRaises(ValueError): changes(rows, old, new)

    def test_fresh_score_alone_does_not_override_historical_veto(self):
        good = dict(policy=dict(policyActionAccuracy=.95, harmfulRecall=1., normalToJunk=0,
                                normalToPromotion=0), comparison=comparison(recovered=[1]))
        self.assertTrue(qualify([good, good], [good]))
        bad = {**good, 'comparison': comparison(introduced=[4])}
        self.assertFalse(qualify([good, good], [bad]))
        low = {**good, 'policy': {**good['policy'], 'policyActionAccuracy': .89}}
        self.assertFalse(qualify([good, low], [good]))


if __name__ == '__main__': unittest.main()
