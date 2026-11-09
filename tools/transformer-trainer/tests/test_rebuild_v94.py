import sys
from pathlib import Path
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import audit_validation_v94 as audit
import prepare_fresh_v94 as prepare
import rebuild_v94 as study

ACTIONS = dict(spam='junk', promotion='promotion', a='transaction', b='none')


def row(label, kind): return dict(label=label, filterReview=dict(kind=kind))


class ErrorTypeTests(unittest.TestCase):
    def check(self, r, action, expected):
        self.assertEqual(study.error_type(r, dict(engineAction=action), ACTIONS), expected)

    def test_kinds(self):
        self.check(row('spam', 'harmful'), 'junk', None)
        self.check(row('spam', 'harmful'), 'none', 'harmful missed')
        self.check(row('promotion', 'commercial'), 'junk', None)
        self.check(row('promotion', 'commercial'), 'none', 'commercial missed')
        self.check(row('a', 'normal'), 'transaction', None)
        self.check(row('a', 'normal'), 'junk', 'normal to junk')
        self.check(row('a', 'normal'), 'promotion', 'normal to promotion')
        self.check(row('a', 'normal'), 'none', 'transaction vs none')

    def test_filing_errors_are_not_serious(self):
        self.assertEqual(study.serious({'transaction vs none': 9, 'commercial missed': 9, 'normal to junk': 1, 'harmful missed': 2}), 3)


class QualifyTests(unittest.TestCase):
    fresh = dict(errors={'harmful missed': 4}, policyActionCorrect=160, fineCorrect=130)
    fixed = dict(classification=dict(strictAction=480), promotion=dict(tolerantAction=150), **{'billing-card': dict(strictAction=30)})
    real = dict(harmfulCaught=8)

    def passes(self, fresh=None, fixed=None, real=None):
        return study.qualifies(fresh or self.fresh, self.fresh, fixed or self.fixed, self.fixed, real or self.real, self.real)

    def test_equal_passes_and_margin_allows_two_rows(self):
        self.assertTrue(self.passes())
        self.assertTrue(self.passes({**self.fresh, 'policyActionCorrect': 158}))
        self.assertFalse(self.passes({**self.fresh, 'policyActionCorrect': 157}))

    def test_serious_errors_fail(self):
        self.assertFalse(self.passes({**self.fresh, 'errors': {'harmful missed': 5}}))

    def test_regressions_fail(self):
        self.assertTrue(self.passes(fixed={**self.fixed, 'classification': dict(strictAction=478)}))
        self.assertFalse(self.passes(fixed={**self.fixed, 'classification': dict(strictAction=477)}))
        self.assertFalse(self.passes(fixed={**self.fixed, 'promotion': dict(tolerantAction=148)}))
        self.assertFalse(self.passes(fixed={**self.fixed, 'billing-card': dict(strictAction=29)}))
        self.assertFalse(self.passes(real=dict(harmfulCaught=7)))


class JointHeadTests(unittest.TestCase):
    def test_gradient_reaches_head_and_body(self):
        import torch
        class Config: hidden_size = 8
        class Model(torch.nn.Module):
            def __init__(self):
                super().__init__(); self.config = Config(); self.body = torch.nn.Linear(4, 8); self.classifier = torch.nn.Linear(8, 3)
            def forward(self, x): return self.classifier(self.body(x))
        model = study.attach_joint(Model())
        logits = model(torch.ones(2, 4)); self.assertEqual(model.pooled.shape, (2, 8))
        original = lambda l, y, m: torch.nn.functional.cross_entropy(l, y, reduction='none')
        objective = study.joint_objective(original, dict(model=model), torch.tensor([0, 2, 3]))
        objective(logits, torch.tensor([1, 2]), {}).sum().backward()
        self.assertGreater(float(model.action_head.weight.grad.abs().sum()), 0)
        self.assertGreater(float(model.body.weight.grad.abs().sum()), 0)


class HostTests(unittest.TestCase):
    def test_only_invalid_hosts_change(self):
        self.assertEqual(prepare.realistic(dict(text='see https://orvani.invalid/r now', language='ja'))['text'], 'see https://orvani.jp/r now')
        self.assertEqual(prepare.realistic(dict(text='see https://a-b.invalid/x', language='en'))['text'], 'see https://a-b.com/x')
        self.assertEqual(prepare.realistic(dict(text='see https://bidv.xyz/r', language='en'))['text'], 'see https://bidv.xyz/r')


class AuditTests(unittest.TestCase):
    def test_wilson_contains_share(self):
        low, high = audit.wilson(21, 24); self.assertLess(low, .875); self.assertGreater(high, .875)


if __name__ == '__main__':
    unittest.main()
