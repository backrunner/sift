from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from train_mmbert import added_label_ids, evaluate_model, label_row_transfers, row_loss_weight


class TrainMMBertTests(unittest.TestCase):
    def test_empty_evaluation_preserves_result_contract(self) -> None:
        self.assertEqual(
            evaluate_model(None, None, [], {}, [], 96, "cpu"),
            (0.0, {}, [], []),
        )

    def test_label_row_transfers_follow_ids_instead_of_sorted_positions(self) -> None:
        transfers = label_row_transfers(
            {0: "alpha", 1: "gamma"},
            {"alpha": 0, "beta": 1, "gamma": 2},
        )

        self.assertEqual(
            transfers,
            [("alpha", 0, 0), ("gamma", 1, 2)],
        )

    def test_label_row_transfers_reject_removed_checkpoint_label(self) -> None:
        with self.assertRaisesRegex(ValueError, "gamma"):
            label_row_transfers(
                {0: "alpha", 1: "gamma"},
                {"alpha": 0, "beta": 1},
            )

    def test_label_row_transfers_reject_sparse_checkpoint_ids(self) -> None:
        with self.assertRaisesRegex(ValueError, "dense"):
            label_row_transfers(
                {0: "alpha", 2: "beta"},
                {"alpha": 0, "beta": 1},
            )

    def test_added_label_ids_follow_current_contract(self) -> None:
        self.assertEqual(
            added_label_ids(
                {0: "alpha", 1: "gamma"},
                {"alpha": 0, "beta": 1, "gamma": 2, "delta": 3},
            ),
            [1, 3],
        )

    def test_selected_label_and_boundary_weights_are_multiplicative(self) -> None:
        self.assertEqual(
            row_loss_weight(
                label_id=4,
                source="augmentation:boundary:reviewed",
                boundary_loss_weight=3,
                selected_label_ids={4, 8},
                selected_label_loss_weight=7,
            ),
            21,
        )
        self.assertEqual(
            row_loss_weight(
                label_id=2,
                source="synthetic:en",
                boundary_loss_weight=3,
                selected_label_ids={4, 8},
                selected_label_loss_weight=7,
            ),
            1,
        )


if __name__ == "__main__":
    unittest.main()
