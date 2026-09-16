import unittest
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

try:
    import coremltools as ct
    import numpy as np
    from coremltools.converters.mil.mil import Builder as mb
except ImportError:
    ct = None

from export_mapped_precision import replace_attention_sentinel


@unittest.skipIf(ct is None, "requires trainer Core ML environment")
class MappedPrecisionTests(unittest.TestCase):
    def test_fp16_padding_rows_stay_finite_and_masked_tokens_stay_excluded(self):
        @mb.program(input_specs=[mb.TensorSpec(shape=(2, 3))],
                    opset_version=ct.target.iOS18)
        def program(mask):
            selected = mb.select(cond=mb.cast(x=mask, dtype="bool"),
                                 a=np.float32(np.finfo(np.float32).min),
                                 b=np.zeros((2, 3), dtype=np.float32))
            return mb.softmax(x=selected, axis=-1)

        replace_attention_sentinel(program)
        model = ct.convert(program, source="milinternal", convert_to="mlprogram",
                           minimum_deployment_target=ct.target.iOS18,
                           compute_precision=ct.precision.FLOAT16,
                           compute_units=ct.ComputeUnit.CPU_ONLY)
        output = next(iter(model.predict({"mask": np.array([
            [False, True, True], [True, True, True],
        ], dtype=np.float32)}).values()))
        self.assertTrue(np.isfinite(output).all())
        np.testing.assert_allclose(output[0], [1, 0, 0], atol=0.001)
        np.testing.assert_allclose(output[1], [1 / 3] * 3, atol=0.001)

    def test_non_mask_constants_are_never_rewritten(self):
        @mb.program(input_specs=[mb.TensorSpec(shape=(1,))],
                    opset_version=ct.target.iOS18)
        def program(x):
            return mb.mul(x=x, y=np.float32(np.finfo(np.float32).min))

        with self.assertRaisesRegex(ValueError, "outside mask selection"):
            replace_attention_sentinel(program)

    def test_changed_graph_without_sentinel_is_rejected(self):
        @mb.program(input_specs=[mb.TensorSpec(shape=(1,))],
                    opset_version=ct.target.iOS18)
        def program(x):
            return mb.identity(x=x)

        with self.assertRaisesRegex(ValueError, "exactly one"):
            replace_attention_sentinel(program)
