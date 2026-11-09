import sys
from pathlib import Path
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import rebuild_v88 as study


def record(epoch, action, fine, junk):
    return dict(epoch=epoch, policyActionCorrect=action, fineCorrect=fine, normalToJunk=junk)


class RebuildV88Tests(unittest.TestCase):
    def test_selection_prefers_action_then_fine_then_safety_then_earliest(self):
        records = [record(3, 10, 5, 0), record(1, 11, 4, 2), record(2, 11, 4, 1), record(4, 11, 4, 1)]
        self.assertEqual(study.select_epoch(records)['epoch'], 2)

    def test_overlap_uses_digit_normalized_signature(self):
        leaks = study.overlap([{'text': 'Code 12345'}], {'a': [{'text': 'code 9'}], 'b': [{'text': 'other'}]})
        self.assertEqual(leaks, {'a': 1, 'b': 0})

    def test_learning_rate_warms_up_and_decays_to_zero(self):
        self.assertAlmostEqual(study.lr_at(0, 100, 10), .1)
        self.assertAlmostEqual(study.lr_at(9, 100, 10), 1.)
        self.assertAlmostEqual(study.lr_at(55, 100, 10), .5)
        self.assertEqual(study.lr_at(100, 100, 10), 0.)

    def test_promotion_uses_tolerant_loss_and_spam_stays_strict(self):
        import torch
        ids = {'spam': 0, 'promotion': 1, 'carrier.promotion': 2, 'finance.bank': 3}
        logits = torch.tensor([[5., 0., 0., 0.], [5., 0., 0., 0.]])
        loss = study.commercial_objective(logits, torch.tensor([1, 0]), ids)
        self.assertLess(float(loss[0]), .1)  # Promotion accepts a confident spam output.
        strict = study.commercial_objective(logits[:1], torch.tensor([3]), ids)
        self.assertGreater(float(strict[0]), 4.)

    def test_no_arm_uses_old_trust_region_or_can_release(self):
        self.assertFalse(study.COMMON['knowledgeDistillation'] or study.COMMON['parameterAnchor'])
        self.assertEqual(study.ARMS['cold-full']['layers'], 12)
        self.assertEqual(study.ARMS['warm-free']['init'], 'sam')


if __name__ == '__main__':
    unittest.main()
