import copy
import hashlib
import json
from pathlib import Path
import random
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import torch
from loss_tail import LossTailScheduler
from training_extension import load_extension
from training_progress import save_state, load_state


class TrainingExtensionTests(unittest.TestCase):
    def setup_parent(self, root):
        torch.manual_seed(41)
        model = torch.nn.Linear(2, 2)
        initial = copy.deepcopy(model)
        optimizer = torch.optim.AdamW(model.parameters(), lr=.01, weight_decay=.01)
        scheduler = torch.optim.lr_scheduler.LinearLR(optimizer, start_factor=1, end_factor=.01, total_iters=4)
        generator = torch.Generator().manual_seed(13)
        for _ in range(4):
            optimizer.zero_grad(); model(torch.ones(1, 2)).square().sum().backward()
            optimizer.step(); scheduler.step()
        contract = {'arguments': {'num_epochs': 2, 'learning_rate': .01, 'sam_rho': .005, 'layer_lr_decay': .9},
            'plan': {'updatesPerEpoch': 2}, 'trainingSHA256': 'training', 'developmentSHA256': 'development',
            'parameterAnchorSHA256': 'original-anchor', 'teacherSHA256': 'teacher',
            'frozenWeightsSHA256': 'frozen', 'labels': {'a': 0, 'b': 1}, 'device': 'cpu'}
        path = root / 'parent.pt'
        save_state(path, model, optimizer, scheduler, generator, contract,
            {'step': 4, 'nextEpoch': 2, 'stopReason': 'max_updates',
             'gradientProbeHistory': [{'step': 4, 'objective': .8}]}, 'cpu')
        return initial, model, optimizer, generator, contract, path

    def child(self, initial, parent, path):
        model = copy.deepcopy(initial)
        optimizer = torch.optim.AdamW(model.parameters(), lr=.001, weight_decay=.01)
        scheduler = LossTailScheduler(optimizer, nominal_epochs=1, updates_per_epoch=2, warmup_updates=0,
            extension_epochs=3, max_extension_epochs=6, tail_ratio=1, patience=3)
        contract = copy.deepcopy(parent)
        contract['arguments'].update(num_epochs=1, learning_rate=.001)
        contract['extensionParent'] = {'sha256': hashlib.sha256(path.read_bytes()).hexdigest()}
        return model, optimizer, scheduler, torch.Generator(), contract

    def test_preserves_adam_moments_next_update_rng_and_original_anchor(self):
        with tempfile.TemporaryDirectory() as d:
            initial, parent, adam, rng, contract, path = self.setup_parent(Path(d))
            child, optimizer, scheduler, gen, new = self.child(initial, contract, path)
            expected_rng = torch.get_rng_state().clone(); expected_python = random.getstate()
            torch.manual_seed(999); random.seed(999)
            receipt = load_extension(path, child, optimizer, scheduler, gen, new, 'cpu')
            self.assertTrue(torch.equal(torch.get_rng_state(), expected_rng))
            self.assertEqual(random.getstate(), expected_python)
            self.assertTrue(torch.equal(gen.get_state(), rng.get_state()))
            self.assertEqual(receipt['parentCompletedUpdates'], 4)
            self.assertEqual(scheduler.get_last_lr(), [.001])
            self.assertEqual(new['parameterAnchorSHA256'], contract['parameterAnchorSHA256'])
            for a, b in zip(child.parameters(), parent.parameters()):
                torch.testing.assert_close(a, b, rtol=0, atol=0)
            for a, b in zip(optimizer.state.values(), adam.state.values()):
                for key in a:
                    torch.testing.assert_close(a[key], b[key], rtol=0, atol=0)
            # A real next Adam update must match a manual schedule switch exactly.
            for group in adam.param_groups: group['lr'] = .001
            for model, opt in ((parent, adam), (child, optimizer)):
                opt.zero_grad(); model(torch.ones(1, 2)).square().sum().backward(); opt.step()
            for a, b in zip(child.parameters(), parent.parameters()):
                torch.testing.assert_close(a, b, rtol=0, atol=0)
            # Child stage remains exactly resumable with its explicit new schedule.
            scheduler.step()
            save_state(Path(d) / 'child.pt', child, optimizer, scheduler, gen, new, {'step': 1}, 'cpu')
            other, opt, sched, g, _ = self.child(initial, contract, path)
            load_state(Path(d) / 'child.pt', other, opt, sched, g, new, 'cpu')
            self.assertEqual(scheduler.state_dict(), sched.state_dict())
            for a, b in zip(child.parameters(), other.parameters()):
                torch.testing.assert_close(a, b, rtol=0, atol=0)

    def test_rejects_data_anchor_teacher_method_and_optimizer_changes_before_mutation(self):
        with tempfile.TemporaryDirectory() as d:
            initial, _, _, _, parent, path = self.setup_parent(Path(d))
            for field in ('trainingSHA256', 'developmentSHA256', 'parameterAnchorSHA256', 'teacherSHA256', 'frozenWeightsSHA256'):
                model, opt, sched, gen, contract = self.child(initial, parent, path)
                contract[field] = 'changed'
                with self.subTest(field=field), self.assertRaisesRegex(ValueError, 'invariant changed'):
                    load_extension(path, model, opt, sched, gen, contract, 'cpu')
                for a, b in zip(model.parameters(), initial.parameters()):
                    torch.testing.assert_close(a, b, rtol=0, atol=0)
            for field in ('sam_rho', 'layer_lr_decay'):
                model, opt, sched, gen, contract = self.child(initial, parent, path)
                contract['arguments'][field] = 42
                with self.subTest(field=field), self.assertRaisesRegex(ValueError, 'method changed'):
                    load_extension(path, model, opt, sched, gen, contract, 'cpu')
            model, opt, sched, gen, contract = self.child(initial, parent, path)
            opt.param_groups[0]['weight_decay'] = .2
            with self.assertRaisesRegex(ValueError, 'optimizer groups'):
                load_extension(path, model, opt, sched, gen, contract, 'cpu')

    def test_rejects_divergent_or_partial_parent_and_missing_terminal_probe(self):
        with tempfile.TemporaryDirectory() as d:
            initial, _, _, _, parent, path = self.setup_parent(Path(d))
            original = torch.load(path, weights_only=True)
            for field, value in (('stopReason', 'development_nll_divergence'), ('step', 3), ('gradientProbeHistory', [])):
                state = copy.deepcopy(original); state['extra'][field] = value; torch.save(state, path)
                model, opt, sched, gen, contract = self.child(initial, parent, path)
                with self.subTest(field=field), self.assertRaises(ValueError):
                    load_extension(path, model, opt, sched, gen, contract, 'cpu')
            torch.save(original, path)
            model, opt, sched, gen, contract = self.child(initial, parent, path)
            contract['extensionParent']['sha256'] = '0' * 64
            with self.assertRaisesRegex(ValueError, 'parent state hash changed'):
                load_extension(path, model, opt, sched, gen, contract, 'cpu')


if __name__ == '__main__':
    unittest.main()
