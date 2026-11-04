import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
import run_approved_signal as runner


class FrozenTeacherTests(unittest.TestCase):
    def test_checkpoint_manifest_rejects_teacher_weight_drift(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);checkpoint=root/'weights';checkpoint.mkdir()
            model=checkpoint/'model.safetensors';model.write_bytes(b'frozen weights')
            manifest=root/'manifest.json'
            manifest.write_text(json.dumps({'checkpoint':'weights','filesSHA256':{
                'model.safetensors':hashlib.sha256(model.read_bytes()).hexdigest()}}))
            with patch.object(runner,'ROOT',root):
                self.assertEqual(runner.verify_checkpoint(manifest)['checkpoint'],'weights')
                model.write_bytes(b'changed weights')
                with self.assertRaisesRegex(ValueError,'checkpoint drift'):
                    runner.verify_checkpoint(manifest)
