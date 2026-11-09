from pathlib import Path
import sys
import unittest
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from reviewed_public_profile import prepare_template,render_template
from curate_dataset import stable_rng


class ReviewedProfileTests(unittest.TestCase):
    def test_explicit_roles_preserve_units_year_and_duration(self):
        template=prepare_template('Nam [NUMBER], soan [NUMBER] gui [NUMBER]. Gia [MONEY] dong, OTP [NUMBER] trong [TIME].','vi',
            ['year','command','shortcode','code'],['minutes'])
        text=render_template(template,'vi',stable_rng('test'))
        self.assertIn('Nam 2026',text)
        self.assertIn('soan 1 gui 199',text)
        self.assertIn('5 phút',text)
        self.assertNotIn('$',text)
        self.assertNotIn('VND dong',text)
        self.assertNotIn('[NUMBER]',text)

    def test_unknown_or_missing_roles_fail_instead_of_inventing_an_otp(self):
        for roles in [[],['unknown']]:
            with self.assertRaisesRegex(ValueError,'roles'):
                prepare_template('Năm [NUMBER]','vi',roles,[])

    def test_bare_tracking_paths_and_source_names_are_not_rehydrated(self):
        template=prepare_template('Xin chao [NAME], xem yk.vtp.vn/S/source-token. Phi [MONEY].','vi',[],[])
        text=render_template(template,'vi',stable_rng('test'))
        self.assertIn('khách hàng',text)
        self.assertNotIn('source-token',text)
        self.assertIn('example.com',text)
        self.assertIn(' VND',text)

    def test_foreign_square_tokens_need_an_explicit_supported_profile(self):
        with self.assertRaisesRegex(ValueError,'Vietnamese'):
            prepare_template('Code [NUMBER]','en',['code'],[])

    def test_malformed_source_scheme_does_not_survive_as_double_url(self):
        template=prepare_template('Xem https//mathx.vn tai day','vi',[],[])
        text=render_template(template,'vi',stable_rng('test'))
        self.assertNotIn('https//',text)
        self.assertNotIn('https://https://',text)
        self.assertNotIn('mathx.vn',text)
