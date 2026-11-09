from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from replay_distillation import correction_loss_weights, is_reviewed_correction, replay_distillation_loss, validate_replay_contract


class ReplayContractTests(unittest.TestCase):
    def test_old_boundary_rows_are_not_treated_as_new_corrections(self):
        prefixes = ["augmentation:boundary:cloudkit-v53:", "augmentation:boundary:cloudkit-v54:"]
        self.assertTrue(is_reviewed_correction("augmentation:boundary:cloudkit-v54:pickup", prefixes))
        self.assertFalse(is_reviewed_correction("augmentation:boundary:older:pickup", prefixes))
        self.assertFalse(is_reviewed_correction("cloudkit:production", prefixes))

    def test_teacher_label_permutation_and_tokenizer_drift_are_rejected(self):
        tokenizer = SimpleNamespace(get_vocab=lambda: {"a": 0, "b": 1}, special_tokens_map={})
        with self.assertRaisesRegex(ValueError, "label order"):
            validate_replay_contract(["allow", "spam"], ["spam", "allow"], tokenizer, tokenizer)
        changed = SimpleNamespace(get_vocab=lambda: {"a": 1, "b": 0}, special_tokens_map={})
        with self.assertRaisesRegex(ValueError, "tokenizer"):
            validate_replay_contract(["allow", "spam"], ["allow", "spam"], tokenizer, changed)
        validate_replay_contract(["allow", "spam"], ["allow", "spam"], tokenizer, tokenizer)


@unittest.skipUnless(importlib.util.find_spec("torch"), "torch requires the trainer environment")
class ReplayLossTests(unittest.TestCase):
    def test_uniform_ce_equalizes_initial_hard_gradients_without_distilling_wrong_teacher(self):
        import torch
        import torch.nn.functional as F
        # Identical logits and teacher, different reviewed gold: one agreement
        # and one disagreement. At initialization the KL gradient is zero.
        student=torch.tensor([[2.,-1.],[2.,-1.]],requires_grad=True)
        teacher=student.detach().clone().requires_grad_()
        labels=torch.tensor([0,1]);mask=torch.zeros(2,dtype=torch.bool)
        hard=F.cross_entropy(student,labels,reduction='none')
        expected=torch.autograd.grad(hard.sum(),student,retain_graph=True)[0]
        loss=replay_distillation_loss(student,teacher,labels,mask,.9,2.,
            only_correct_teacher=True,agreement_all_rows=True,hard_label_mode='uniform')
        loss.sum().backward()
        torch.testing.assert_close(student.grad,expected,rtol=1e-5,atol=1e-7)
        self.assertIsNone(teacher.grad)

    def test_uniform_ce_changes_only_agreement_hard_coefficient(self):
        import torch
        import torch.nn.functional as F
        student=torch.tensor([[.5,-.2],[.1,.9]],requires_grad=True)
        teacher=torch.tensor([[4.,-4.],[4.,-4.]])
        gold=torch.tensor([0,1]);mask=torch.zeros(2,dtype=torch.bool)
        old=replay_distillation_loss(student,teacher,gold,mask,.9,2.,only_correct_teacher=True)
        new=replay_distillation_loss(student,teacher,gold,mask,.9,2.,only_correct_teacher=True,hard_label_mode='uniform')
        hard=F.cross_entropy(student,gold,reduction='none')
        torch.testing.assert_close(new-old,torch.stack([.9*hard[0],hard[1]*0]))
        with self.assertRaisesRegex(ValueError,'correct-teacher'):
            replay_distillation_loss(student,teacher,gold,mask,.9,2.,hard_label_mode='uniform')

    def test_wrong_replay_teacher_is_ignored_when_gold_gate_is_enabled(self):
        import torch
        import torch.nn.functional as functional

        student = torch.tensor([[3., -3.], [-3., 3.]])
        teacher = torch.tensor([[8., -8.], [-8., 8.]])
        labels = torch.tensor([1, 1])
        loss = replay_distillation_loss(student, teacher, labels,
            torch.tensor([False, False]), .9, 2., only_correct_teacher=True)
        hard = functional.cross_entropy(student, labels, reduction="none")
        self.assertAlmostEqual(loss[0].item(), hard[0].item(), places=6)
        self.assertNotAlmostEqual(loss[1].item(), hard[1].item(), places=6)

    def test_adamw_cannot_decay_protected_output_rows(self):
        import torch
        from train_mmbert import restore_locked_classifier_rows, train_only_classifier_rows

        torch.manual_seed(4)
        model = torch.nn.Module()
        model.classifier = torch.nn.Linear(2, 3)
        initial_weight = model.classifier.weight.detach().clone()
        initial_bias = model.classifier.bias.detach().clone()
        locked = train_only_classifier_rows(
            model, ["classifier.weight", "classifier.bias"], {"a": 0, "b": 1, "c": 2}, ["b"]
        )
        optimizer = torch.optim.AdamW(model.parameters(), lr=.1, weight_decay=.2)
        for _ in range(3):
            optimizer.zero_grad(set_to_none=True)
            torch.nn.functional.cross_entropy(model.classifier(torch.ones(4, 2)), torch.ones(4, dtype=torch.long)).backward()
            optimizer.step()
            restore_locked_classifier_rows(locked)
        self.assertTrue(torch.equal(model.classifier.weight[[0, 2]], initial_weight[[0, 2]]))
        self.assertTrue(torch.equal(model.classifier.bias[[0, 2]], initial_bias[[0, 2]]))
        self.assertFalse(torch.equal(model.classifier.weight[1], initial_weight[1]))

    def test_priority_weight_changes_only_reviewed_corrections(self):
        import torch

        weights = torch.tensor([16., 16., 1.])
        result = correction_loss_weights(weights, torch.tensor([True, False, False]), 4.)
        torch.testing.assert_close(result, torch.tensor([64., 16., 1.]))
        torch.testing.assert_close(weights, torch.tensor([16., 16., 1.]))

    def test_last_layer_tuning_preserves_embeddings_and_lower_layers(self):
        import torch
        from train_mmbert import train_last_encoder_layers

        model = torch.nn.Module()
        model.model = torch.nn.Module()
        model.model.embeddings = torch.nn.Embedding(5, 2)
        model.model.layers = torch.nn.ModuleList([torch.nn.Linear(2, 2) for _ in range(3)])
        model.model.final_norm = torch.nn.LayerNorm(2)
        model.classifier = torch.nn.Linear(2, 2)
        train_last_encoder_layers(model, 1)
        self.assertFalse(model.model.embeddings.weight.requires_grad)
        self.assertFalse(model.model.layers[1].weight.requires_grad)
        self.assertTrue(model.model.layers[2].weight.requires_grad)
        self.assertTrue(model.model.final_norm.weight.requires_grad)
        self.assertTrue(model.classifier.weight.requires_grad)
        with self.assertRaises(ValueError):
            train_last_encoder_layers(model, 4)

    def test_wrong_teacher_cannot_veto_reviewed_correction(self):
        import torch
        import torch.nn.functional as functional

        student = torch.tensor([[3., -3.], [3., -3.]], requires_grad=True)
        teacher = torch.tensor([[8., -8.], [8., -8.]], requires_grad=True)
        labels = torch.tensor([1, 1])
        mask = torch.tensor([True, False])
        loss = replay_distillation_loss(student, teacher, labels, mask, 0.9, 2.)
        hard = functional.cross_entropy(student, labels, reduction="none")
        self.assertAlmostEqual(loss[0].item(), hard[0].item(), places=6)
        self.assertLess(loss[1].item(), loss[0].item())
        loss.sum().backward()
        self.assertLess(student.grad[0, 1].item(), -0.99)
        self.assertIsNone(teacher.grad)

    def test_zero_alpha_matches_supervised_loss_and_rejects_invalid_parameters(self):
        import torch
        import torch.nn.functional as functional

        student = torch.tensor([[1., -1.], [-1., 1.]])
        labels = torch.tensor([0, 1])
        mask = torch.tensor([False, True])
        losses = replay_distillation_loss(student, -student, labels, mask, 0., 2.)
        torch.testing.assert_close(losses, functional.cross_entropy(student, labels, reduction="none"))
        with self.assertRaises(ValueError):
            replay_distillation_loss(student, -student, labels, mask, 1.1, 2.)


if __name__ == "__main__":
    unittest.main()
