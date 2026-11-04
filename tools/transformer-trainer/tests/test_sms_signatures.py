import sys
from pathlib import Path
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from sms_signatures import semantic_signature


class SignatureTests(unittest.TestCase):
    def test_currency_decimal_and_phone_rehydration(self):
        a = "Offer! Win over £1000 in our quiz. CustCare:08718720201."
        b = "Offer! Win over $363.05 in our quiz. CustCare:+72 907 818 3989."
        self.assertEqual(semantic_signature(a), semantic_signature(b))

    def test_upstream_redactions_match_fictional_values(self):
        self.assertEqual(semantic_signature("Call <PHONE_NUMBER>. Visit <URL>"),
                         semantic_signature("Call +44 7700 900123. Visit https://example.com/a"))
        self.assertEqual(semantic_signature("Meet in &lt;#&gt; hours"), semantic_signature("Meet in 2.5 hours"))

    def test_negation_and_intent_are_not_erased(self):
        self.assertNotEqual(semantic_signature("You must pay $10 before collection"),
                            semantic_signature("You must not pay $10 before collection"))
        self.assertNotEqual(semantic_signature("The upgrade was completed"),
                            semantic_signature("The upgrade is on sale"))

    def test_scheme_free_links_cannot_hide_same_template(self):
        self.assertEqual(semantic_signature('Plan update. Details: go.app/r/12345'),
                         semantic_signature('Plan update. Details: trk.li/other-token'))
        self.assertEqual(semantic_signature('Plan update. Details: go.app/r/12345'),
                         semantic_signature('Plan update. Details: https://example.com/abc'))
        self.assertEqual(semantic_signature('请查看m.shop.com/i/123，勿转发'),
                         semantic_signature('请查看sale.jp/x/456，勿转发'))

    def test_scheme_free_detection_does_not_swallow_units_emails_or_negation(self):
        self.assertNotEqual(semantic_signature('Data remaining 1.5GB'),
                            semantic_signature('Data remaining 1.5MB'))
        self.assertEqual(semantic_signature('Send to user@example.com'),
                         semantic_signature('Send to other@different.org'))
        self.assertNotEqual(semantic_signature('Do not open go.app/a'),
                            semantic_signature('Do open trk.li/b'))

    def test_typed_locale_values_keep_the_same_dynamic_family(self):
        self.assertEqual(semantic_signature('Gia {{AMOUNT}} dong, ngay {{CODE}}'),
                         semantic_signature('Gia 50000 VND, ngay 12/11/2026'))


if __name__ == "__main__": unittest.main()
