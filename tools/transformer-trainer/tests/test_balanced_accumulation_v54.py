import copy
from pathlib import Path
import sys
from types import SimpleNamespace
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import torch
import torch.nn.functional as F
from torch.utils.data import DataLoader, RandomSampler, SequentialSampler
from balanced_accumulation_v54 import BalancedAccumulationBatchSampler, install, window_plan
from sharpness_aware import sam_perturbation


class BalancedAccumulationTests(unittest.TestCase):
    def test_all3457_rows_once_with_same_updates_and_no_singleton(self):
        sampler = BalancedAccumulationBatchSampler(SequentialSampler(range(3457)), 32, 4)
        batches = list(sampler)
        self.assertEqual([i for b in batches for i in b], list(range(3457)))
        self.assertEqual(len(batches), 112)
        windows = [sum(map(len, batches[i:i+4])) for i in range(0, len(batches), 4)]
        self.assertEqual(len(windows), 28)
        self.assertEqual(set(windows), {123, 124})
        self.assertEqual(windows.count(124), 13)
        self.assertLessEqual(max(map(len, batches)), 32)

    def test_dataloader_preserves_original_shuffle_and_rng_across_epochs(self):
        data = list(range(3457)); a = torch.Generator().manual_seed(321); b = torch.Generator().manual_seed(321)
        old = DataLoader(data, batch_size=32, shuffle=True, generator=a)
        new = DataLoader(data, batch_sampler=BalancedAccumulationBatchSampler(RandomSampler(data, generator=b), 32, 4), generator=b)
        for _ in range(3):
            self.assertEqual(torch.cat(list(old)).tolist(), torch.cat(list(new)).tolist())
            self.assertTrue(torch.equal(a.get_state(), b.get_state()))

    def test_hook_applies_only_to_training_and_restores(self):
        import torch.utils.data as data
        original = data.DataLoader
        restore, audits = install(expected_rows=3457, microbatch_size=32, accumulation=4)
        try:
            kwargs = {'batch_size': 32, 'generator': torch.Generator().manual_seed(1)}
            training = data.DataLoader(list(range(3457)), shuffle=True, sampler=None, **kwargs)
            validation = data.DataLoader(list(range(493)), shuffle=False, **kwargs)
            self.assertEqual(len(training), 112); self.assertEqual(validation.batch_size, 32)
            self.assertEqual(len(audits), 1)
            with self.assertRaises(ValueError): data.DataLoader(list(range(3457)), shuffle=True, drop_last=True, **kwargs)
        finally: restore()
        self.assertIs(data.DataLoader, original)

    def test_actual_weighted_sam_update_matches_whole_window_oracle(self):
        torch.manual_seed(23); initial = torch.nn.Linear(3, 2).double()
        x = torch.randn(17, 3, dtype=torch.float64); y = torch.arange(17) % 2
        weights = torch.tensor([1., .12, .23, 1., .12, 1., 1., .23, 1., 1., .12, 1., .23, 1., 1., .12, 1.], dtype=torch.float64)
        batches = list(BalancedAccumulationBatchSampler(SequentialSampler(range(17)), 4, 2))

        def update(groups):
            model = copy.deepcopy(initial); opt = torch.optim.AdamW(model.parameters(), lr=.001, weight_decay=.01)
            for group in groups:
                denominator = sum(float(weights[b].sum()) for b in group)
                opt.zero_grad()
                for b in group: (F.cross_entropy(model(x[b]), y[b], reduction='none') * weights[b]).sum().backward()
                for p in model.parameters(): p.grad.div_(denominator)
                with sam_perturbation(list(model.parameters()), .005):
                    opt.zero_grad()
                    for b in group: (F.cross_entropy(model(x[b]), y[b], reduction='none') * weights[b]).sum().backward()
                    for p in model.parameters(): p.grad.div_(denominator)
                torch.nn.utils.clip_grad_norm_(model.parameters(), 5); opt.step()
            return model
        micro = [batches[i:i+2] for i in range(0, len(batches), 2)]
        whole = [[[j for b in group for j in b]] for group in micro]
        a, b = update(micro), update(whole)
        for p, q in zip(a.parameters(), b.parameters()): torch.testing.assert_close(p, q, atol=1e-12, rtol=1e-12)

    def test_real_trainer_consumes_balanced_windows_with_same_update_count(self):
        from train_mmbert import train_model
        class Tiny(torch.nn.Module):
            def __init__(self):
                super().__init__(); self.linear = torch.nn.Linear(1, 2); self.seen = []
            def forward(self, input_ids):
                self.seen.append(input_ids.flatten().tolist())
                return SimpleNamespace(logits=self.linear(input_ids))
        model = Tiny(); rows = [{'text': str(i), 'label': 'a' if i % 2 else 'b'} for i in range(17)]
        tokenizer = lambda texts, **kwargs: {'input_ids': torch.tensor([[float(t)] for t in texts])}
        args = SimpleNamespace(num_epochs=1, seed=7, max_length=2, boundary_loss_weight=1.,
            train_label_rows=[], selected_label_loss_weight=1., batch_size=4, learning_rate=.001,
            weight_decay=.01, label_smoothing=0., warmup_ratio=0., early_stopping_patience=0,
            sam_rho=.005, max_grad_norm=5., gradient_accumulation_steps=2)
        restore, audits = install(expected_rows=17, microbatch_size=4, accumulation=2)
        summary = {}
        try: train_model(model, tokenizer, rows, {'a': 0, 'b': 1}, args, 'cpu', optimization_summary=summary)
        finally: restore()
        self.assertEqual(summary['completedUpdates'], 3)
        self.assertEqual(len(audits), 1)
        self.assertEqual(len(model.seen), 12)  # Three updates, two microbatches, two SAM passes.
        self.assertEqual(min(map(len, model.seen)), 2)
        self.assertEqual(sorted(v for batch in model.seen for v in batch), sorted(list(range(17)) * 2))

    def test_invalid_or_repeating_sampler_rejected(self):
        with self.assertRaises(ValueError): window_plan(5, 1, 4)
        with self.assertRaises(ValueError): window_plan(0, 32, 4)
        class Repeated:
            def __len__(self): return 17
            def __iter__(self): return iter([0] * 17)
        with self.assertRaises(ValueError): list(BalancedAccumulationBatchSampler(Repeated(), 4, 2))

    def test_new_microbatch_shapes_have_cpu_mps_sam_gradient_parity(self):
        from transformers import ModernBertConfig, ModernBertForSequenceClassification
        from training_backend import enable_frozen_boundary_input_gradient
        if not torch.backends.mps.is_available(): self.skipTest('requires MPS')
        torch.manual_seed(54)
        reference = ModernBertForSequenceClassification(ModernBertConfig(vocab_size=32,
            hidden_size=16, intermediate_size=24, num_hidden_layers=3, num_attention_heads=2,
            num_labels=2, pad_token_id=0, bos_token_id=1, eos_token_id=2)).eval()
        reference.model.embeddings.requires_grad_(False); reference.model.layers[0].requires_grad_(False)
        device_model = copy.deepcopy(reference).to('mps')
        enable_frozen_boundary_input_gradient(device_model, 'mps')
        for count in (30, 31):
            tokens = torch.randint(3, 32, (count, 8)); labels = torch.arange(count) % 2
            weights = torch.linspace(.12, 1., count); gradients = {}
            for model, device in ((reference, 'cpu'), (device_model, 'mps')):
                x, y, w = tokens.to(device), labels.to(device), weights.to(device)
                parameters = [p for p in model.parameters() if p.requires_grad]
                def loss(): return (F.cross_entropy(model(x).logits, y, reduction='none') * w).sum() / w.sum()
                model.zero_grad(); loss().backward()
                with sam_perturbation(parameters, .005):
                    model.zero_grad(); loss().backward()
                gradients[device] = {n: p.grad.detach().cpu().clone() for n, p in model.named_parameters() if p.requires_grad}
            for name, grad in gradients['cpu'].items():
                torch.testing.assert_close(gradients['mps'][name], grad, rtol=3e-3, atol=3e-5)


if __name__ == '__main__': unittest.main()
