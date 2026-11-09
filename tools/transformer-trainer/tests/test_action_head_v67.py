import copy
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from action_head_v67 import gated_predictions, per_row_loss, select_epoch, target


class ActionHeadTests(unittest.TestCase):
    def test_head_only_grants_full_distribution_without_editing_fine_output(self):
        row = dict(text='example', label='finance.bank', prediction='life.other', confidence=.35,
                   probabilities={'life.other': .35, 'finance.bank': .65})
        self.assertEqual(gated_predictions([row], [[.91, .03, .03, .03]])[0], row)
        out = gated_predictions([row], [[.4, .2, .2, .2]])[0]
        self.assertNotIn('probabilities', out)
        self.assertEqual(out['prediction'], row['prediction']); self.assertEqual(out['confidence'], row['confidence'])
        for invalid in ([.9, .1, .1, 0], [float('nan'), 0, 0, 0], [.9, .1]):
            with self.assertRaises(ValueError): gated_predictions([row], [invalid])

    def test_commercial_tolerance_does_not_weaken_harmful_target(self):
        import torch
        logits = torch.tensor([[0., 0., 1., 4.], [0., 0., 4., 1.]])
        commercial = per_row_loss(logits, torch.tensor([2, 2]))
        self.assertAlmostEqual(float(commercial[0]), float(commercial[1]), places=6)
        harmful = per_row_loss(logits, torch.tensor([3, 3]))
        self.assertLess(float(harmful[0]), float(harmful[1]))
        self.assertEqual(target('__sift_abstain__', {'__sift_abstain__': 'none'}), 1)

    def test_unsafe_best_score_cannot_select_and_no_gain_keeps_baseline(self):
        rows = [dict(epoch=e, policy=dict(actionCorrect=65, policyActionAccuracy=65/72, harmfulRecall=1.),
            headDevelopmentLoss=1., comparison=dict(recovered=[], introduced=[], newMissToBusiness=[])) for e in range(19)]
        self.assertEqual(select_epoch(rows)['epoch'], 0)
        rows[3]['comparison']['recovered'] = [1]
        rows[3]['policy']['actionCorrect'] = 66
        rows[4]['policy']['actionCorrect'] = 70
        rows[4]['comparison']['introduced'] = [2]
        rows[4]['comparison']['recovered'] = [1, 3]
        self.assertEqual(select_epoch(rows)['epoch'], 3)
        with self.assertRaises(ValueError): select_epoch(rows[:-1])


if __name__ == '__main__': unittest.main()
