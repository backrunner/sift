"""Unit tests for deterministic semantic corpus pruning."""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from prune_dataset import protected_indices, select_group, source_priority  # noqa: E402


class PruneDatasetTests(unittest.TestCase):
    def test_source_priority_prefers_reviewed_and_observed_rows(self):
        self.assertLess(
            source_priority({"source": "augmentation:boundary:cloud-expiry"}),
            source_priority({"source": "remote-training.ndjson"}),
        )
        self.assertLess(
            source_priority({"source": "github:licensed-corpus"}),
            source_priority({"source": "synthetic:zh"}),
        )

    def test_boundary_rows_and_replacement_anchors_are_protected(self):
        rows = [
            {"label": "work.alert", "language": "zh", "text": "边界样本一", "source": "augmentation:boundary:cloud-expiry"},
            {"label": "spam", "language": "zh", "text": "替换样本一", "source": "augmentation:replacement:advance-fee"},
            {"label": "spam", "language": "zh", "text": "替换样本二", "source": "augmentation:replacement:advance-fee"},
            {"label": "spam", "language": "en", "text": "replacement", "source": "augmentation:replacement:advance-fee"},
        ]

        protected = protected_indices(rows)

        self.assertIn(0, protected)
        self.assertEqual(len(protected & {1, 2}), 1)
        self.assertIn(3, protected)

    def test_same_label_selection_keeps_observed_row_and_protected_anchor(self):
        rows = [
            {"label": "spam", "language": "en", "text": "observed", "source": "public:licensed"},
            {"label": "spam", "language": "en", "text": "replacement", "source": "augmentation:replacement:advance-fee"},
            {"label": "spam", "language": "en", "text": "synthetic", "source": "synthetic:en"},
        ]
        protected = {1}

        def maximum_similarity(index: int, selected: list[int]) -> tuple[float, int | None]:
            return (-1.0, None) if not selected else (0.99, selected[0])

        selected, rejected = select_group(
            [2, 1, 0], rows, protected, 0.96, 1, maximum_similarity,
        )

        self.assertEqual(set(selected), {0, 1})
        self.assertEqual([item[0] for item in rejected], [2])

    def test_minimum_bucket_floor_stops_pruning(self):
        rows = [
            {"label": "life.other", "language": "ja", "text": f"row {index}", "source": "synthetic:ja"}
            for index in range(3)
        ]

        def maximum_similarity(index: int, selected: list[int]) -> tuple[float, int | None]:
            return (-1.0, None) if not selected else (0.99, selected[0])

        selected, rejected = select_group(
            [0, 1, 2], rows, set(), 0.96, 2, maximum_similarity,
        )

        self.assertEqual(len(selected), 2)
        self.assertEqual(len(rejected), 1)


if __name__ == "__main__":
    unittest.main()
