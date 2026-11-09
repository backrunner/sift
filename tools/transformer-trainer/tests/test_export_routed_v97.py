import base64
from pathlib import Path
import struct
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import export_routed_v97 as export


class GateEncodingTests(unittest.TestCase):
    def test_round_trip_order_is_weights_by_row_then_bias(self):
        weight = [[float(row * 18 + column) for column in range(18)] for row in range(3)]
        values = struct.unpack('<57f', base64.b64decode(export.encode_gate(weight, [54., 55., 56.])))
        self.assertEqual(values, tuple(float(i) for i in range(57)))

    def test_wrong_shape_is_rejected(self):
        with self.assertRaises(ValueError):
            export.encode_gate([[0.] * 18], [0.])


class ManifestTests(unittest.TestCase):
    SOURCE = dict(version='old', releaseSequence=6, minimumAppBuild=32, algorithm='teacher-student-distillation', distillation=dict(a=1),
                  quantizationSource='x', embeddingTransform='y', signature='s', keyID='k', remoteBaseURL='u', sha256='old', runtimeProfile={}, quantizationProfile={})

    def make(self, track='dev'):
        return export.routed_manifest(self.SOURCE, version='new', sequence=7, track=track, gate='g', package_sha='sha', trained_at='t', training_count=9)

    def test_rebuild_drops_teacher_claims_and_any_signature(self):
        manifest = self.make()
        for key in ('distillation', 'signature', 'keyID', 'remoteBaseURL', 'quantizationSource'):
            self.assertNotIn(key, manifest)
        self.assertEqual(manifest['algorithm'], export.ROUTED_ALGORITHM)
        self.assertEqual(manifest['minimumAppBuild'], export.ROUTED_MINIMUM_APP_BUILD)
        self.assertFalse(manifest['releaseEligible'])

    def test_stable_track_is_refused(self):
        with self.assertRaises(ValueError):
            self.make('stable')


if __name__ == '__main__':
    unittest.main()
