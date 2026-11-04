from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import rebuild_v98 as study


class TeacherRuleTests(unittest.TestCase):
    def test_needs_action_and_fine(self):
        ref = dict(policyActionCorrect=1080, fineCorrect=970)
        self.assertTrue(study.teacher_passes(dict(ref), ref))
        self.assertFalse(study.teacher_passes({**ref, 'fineCorrect': 969}, ref))
        self.assertFalse(study.teacher_passes({**ref, 'policyActionCorrect': 1079}, ref))

    def test_contract_values_match_the_app(self):
        self.assertEqual((study.ALPHA, study.TEMPERATURE), (.7, 2.))

    def test_budget_stays_near_earlier_studies(self):
        updates = study.base.window_plan(4294, 32, 4)['updatesPerEpoch'] * study.EPOCHS
        self.assertLess(abs(updates - 768), 32)


class SoftTargetTests(unittest.TestCase):
    def test_wrong_teacher_leaves_only_the_hard_loss(self):
        import torch
        student = torch.tensor([[2., 0., 0.]]); teacher = torch.tensor([[0., 5., 0.]]); labels = torch.tensor([0]); hard = torch.tensor([.4])
        self.assertAlmostEqual(float(study.soft_targets((student, teacher), labels, hard)), .4, places=5)

    def test_correct_teacher_mixes_in_kl(self):
        import torch
        student = torch.tensor([[0., 2., 0.]]); teacher = torch.tensor([[5., 0., 0.]]); labels = torch.tensor([0]); hard = torch.tensor([.4])
        self.assertGreater(float(study.soft_targets((student, teacher), labels, hard)), .4 * .3)

    def test_matching_student_has_no_kl(self):
        import torch
        logits = torch.tensor([[5., 0., 0.]]); labels = torch.tensor([0]); hard = torch.tensor([.4])
        self.assertAlmostEqual(float(study.soft_targets((logits, logits.clone()), labels, hard)), .4 * .3, places=5)


if __name__ == '__main__':
    unittest.main()
