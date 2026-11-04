from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from curate_dataset import canonicalize_carrier_billing


class CarrierBalanceLabelTests(unittest.TestCase):
    def test_money_balance_is_billing_in_all_core_languages(self):
        for text in ["账户余额已低于18.25元，请及时充值。",
                     "Your balance is $8.40. Please top up.",
                     "Low balance: under $625.85. Top up to stay connected.",
                     "残高が549.06円を下回りました。チャージをお願いします。"]:
            with self.subTest(text=text):
                self.assertEqual(canonicalize_carrier_billing(text, "carrier.data_reminder"),
                                 ("carrier.billing", True))

    def test_data_and_voice_quantity_remain_usage(self):
        for text in ["本月流量余额还有2GB，有效期到月底。", "Your remaining voice balance is 40 minutes.",
                     "データ残量は1.5GBで、通話は20分利用できます。",
                     "Usage notice: 63GB is available in this billing cycle and resets next month.",
                     "本账期可用流量20GB，下个账期重新计算。"]:
            with self.subTest(text=text):
                self.assertEqual(canonicalize_carrier_billing(text, "carrier.data_reminder"),
                                 ("carrier.data_reminder", False))

    def test_bank_balance_does_not_become_carrier_billing(self):
        self.assertEqual(canonicalize_carrier_billing("Your balance is $8.40.", "finance.bank"),
                         ("finance.bank", False))


if __name__ == "__main__":
    unittest.main()
