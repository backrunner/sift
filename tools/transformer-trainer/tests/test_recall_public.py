from pathlib import Path
import sys
import unittest

sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from recall_public import render,ascii_family
from prepare_recall_signal import split_pool


class PublicRecallTests(unittest.TestCase):
    def test_preserves_public_host_not_path_or_personal_identifiers(self):
        text,hosts=render('Account notice sample.person@domain.com https://bank.notice-check.vip/customer/12345?token=secret update now','en')
        self.assertEqual(hosts,['bank.notice-check.vip'])
        self.assertIn('https://bank.notice-check.vip/r/730821',text)
        self.assertNotIn('secret',text);self.assertNotIn('sample.person',text)

    def test_roles_are_not_all_coerced_to_phone(self):
        text,_=render('Ma OTP 123456. STK [BANK_ACC]. LH 198 ([MONEY]). So tien [MONEY] dong.','vi')
        self.assertIn('OTP 730821',text)
        self.assertIn('120000123456',text)
        self.assertNotIn('VND dong',text)
        self.assertNotIn('198 (',text)

    def test_broken_or_identifier_hosts_and_ambiguous_roles_are_excluded(self):
        for text in ['Bank update https://bank.foo vip now','Bank update https://bank.[MONEY].vip now',
                     'Bank update https://bank.bad- now','Message with [NUMBER] unknown role',
                     'Bank update https://1234567890.bank.vip now']:
            with self.assertRaises(ValueError):render(text,'vi')

    def test_identity_codes_and_claimed_alias_are_replaced(self):
        text,_=render('Tôi là Hùng - công chức. ma so bi mat ABCD42PQ. hoa don so K25VA342415.','vi')
        self.assertNotIn('Hùng',text);self.assertNotIn('ABCD42PQ',text);self.assertNotIn('K25VA342415',text)

    def test_accent_variants_and_attack_campaigns_stay_in_one_split(self):
        self.assertEqual(ascii_family('Nhận tiền tại https://a.top/x'),ascii_family('Nhan tien tai https://b.top/y'))
        rows=[{'text':'A complete first bank warning','label':'spam','hosts':['bank.clone.top'],'originalSHA256':'a'},
              {'text':'A different full credentials request','label':'spam','hosts':['other.clone.top'],'originalSHA256':'b'},
              {'text':'A complete unrelated service confirmation','label':'carrier.service','hosts':['carrier.example'],'originalSHA256':'c'}]
        result=split_pool(rows)
        first=[(side,group) for row,side,group in result if row['originalSHA256'] in ('a','b')]
        self.assertEqual(first[0],first[1])


if __name__=='__main__':unittest.main()
