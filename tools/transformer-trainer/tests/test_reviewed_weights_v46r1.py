import json
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))


class TrainingEvaluationIsolationTests(unittest.TestCase):
    def test_actual_evaluation_ignores_training_lookup_and_restores_it(self):
        import torch
        import train_mmbert as train
        from reviewed_weights_v46r1 import build_spec, install

        class Model(torch.nn.Module):
            def forward(self, input_ids):
                return SimpleNamespace(logits=torch.tensor([[0., 2.]]).repeat(len(input_ids), 1))

        tokenize = lambda texts, **kw: {'input_ids': torch.ones((len(texts), 2), dtype=torch.long)}
        training = [{'text': 'training junk', 'label': 'spam', 'language': 'ja'}]
        evaluation = [{'text': 'unseen legitimate business', 'label': 'transaction'}]
        label_map = {'spam': 0, 'transaction': 1}
        base_collate, base_evaluate = train.make_collate, train.evaluate_model
        expected = train.evaluate_model(Model(), tokenize, evaluation, label_map, list(label_map), 2, 'cpu')
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'weights.json'
            path.write_text(json.dumps(build_spec(training, 'hash')))
            for enabled, weight in ((False, 1.), (True, 2.)):
                restore = install(path, enabled)
                try:
                    item = [{'text': 'training junk', 'label': 0}]
                    self.assertEqual(float(train.make_collate(tokenize, 2)(item)['loss_weights'][0]), weight)
                    actual = train.evaluate_model(Model(), tokenize, evaluation, label_map, list(label_map), 2, 'cpu')
                    self.assertEqual(actual, expected)
                    self.assertEqual(float(train.make_collate(tokenize, 2)(item)['loss_weights'][0]), weight)
                    if enabled:
                        with self.assertRaises(KeyError):
                            train.make_collate(tokenize, 2)([{'text': 'unadmitted training', 'label': 0}])
                finally:
                    restore()
                self.assertIs(train.make_collate, base_collate)
                self.assertIs(train.evaluate_model, base_evaluate)
