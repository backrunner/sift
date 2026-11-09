import json
from pathlib import Path
import sys
import tempfile
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from label_mass import preserving_weights


class LabelMassTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name) / 'reference.ndjson'
        self.rows = [{'text': str(i), 'label': 'a' if i < 3 else 'b'} for i in range(5)]
        self.path.write_text(''.join(json.dumps(r)+'\n' for r in self.rows))

    def test_subset_preserves_label_mass_and_collation(self):
        import torch
        from train_mmbert import make_collate
        weights, report = preserving_weights([self.rows[0], self.rows[3]], self.path)
        self.assertEqual(weights, {'a': 3., 'b': 2.})
        tokenize = lambda texts, **kw: {'input_ids': torch.zeros((len(texts), 2))}
        batch = make_collate(tokenize, 2, label_loss_weights={0: weights['a'], 1: weights['b']})(
            [{'text': '0', 'label': 0}, {'text': '3', 'label': 1}])
        self.assertEqual(batch['loss_weights'].tolist(), [3., 2.])
        self.assertEqual(report['referenceCounts'], {'a': 3, 'b': 2})

    def test_rejects_relabel_unknown_duplicate_and_missing_label(self):
        for rows in [[self.rows[0]], [self.rows[0], self.rows[0], self.rows[3]],
                     [{'text': '0', 'label': 'b'}, self.rows[3]],
                     [{'text': 'unreviewed', 'label': 'a'}, self.rows[3]]]:
            with self.subTest(rows=rows), self.assertRaises(ValueError):
                preserving_weights(rows, self.path)

    def test_identity_is_unweighted(self):
        weights, _ = preserving_weights(self.rows, self.path)
        self.assertEqual(weights, {'a': 1., 'b': 1.})
