import sys
from pathlib import Path
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import build_real_v90 as real


class RealV90Tests(unittest.TestCase):
    def test_url_keeps_scheme_and_host_only(self):
        self.assertEqual(real.normalize('Track: https://w-mt.co/g/cZc7NG now'), 'Track: https://w-mt.co/ now')
        self.assertEqual(real.normalize('Track at a.co/5mRhmyv'), 'Track at https://a.co/')

    def test_bare_host_and_spacing_and_damage(self):
        self.assertEqual(real.normalize('Log  into  my.mintmobile.com  now'), 'Log into my.mintmobile.com now')
        self.assertEqual(real.normalize('for Â£5'), 'for £5')

    def test_placeholders_and_personal_data_are_refused(self):
        self.assertEqual(real.refusal('Click <URL> now'), 'upstream-placeholder')
        self.assertEqual(real.refusal('Number 6280368198 used'), 'personal-identifier')
        self.assertEqual(real.refusal('Mail a.b@example.org'), 'personal-identifier')
        self.assertIsNone(real.refusal('Your AWS code is 8250'))

    def test_list_rows_split_only_when_marked(self):
        self.assertEqual(real.expand({'splitList': True}, "['a', 'b']"), ['a', 'b'])
        self.assertEqual(real.expand({}, "['a', 'b']"), ["['a', 'b']"])

    def test_test_only_rows_never_reach_training(self):
        self.assertEqual(real.role_of('any', True), 'test')

    def test_role_is_deterministic(self):
        self.assertEqual(real.role_of('real-v90-abc', False), real.role_of('real-v90-abc', False))

    def test_near_duplicates_share_a_component(self):
        group = real.components(['Your parcel 123 is on hold, confirm at https://a.io/x', 'Your parcel 456 is on hold, confirm at https://b.io/y', 'Quarterly meeting moved to Friday afternoon'])
        self.assertEqual(group[0], group[1]); self.assertNotEqual(group[0], group[2])


if __name__ == '__main__': unittest.main()
