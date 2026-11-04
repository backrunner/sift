import copy
import csv
import hashlib
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from import_reviewed_public import digest, materialize, render_review, review_template
from public_url_evidence import mask_reviewed_urls, public_urls, restore_existing_render, restore_urls


class PublicURLEvidenceTests(unittest.TestCase):
    def test_preserves_hosts_and_scheme_without_private_paths_or_queries(self):
        text='See http://notice.bank.vn/customer/secret?id=12345678 or app.bank.vn/auth/token.'
        masked,roots=mask_reviewed_urls(text,['notice.bank.vn','app.bank.vn'])
        rendered=restore_urls(masked,roots)
        self.assertEqual(rendered,'See http://notice.bank.vn/ or app.bank.vn/.')
        for private in ['secret','12345678','token','customer']:self.assertNotIn(private,rendered)

    def test_host_review_is_required_and_cannot_substitute_a_trusted_brand(self):
        with self.assertRaisesRegex(ValueError,'review differs'):
            mask_reviewed_urls('Open https://bank-account-verify.xyz/login',['bank.vn'])
        masked,roots=mask_reviewed_urls('Open https://bank-account-verify.xyz/login',['bank-account-verify.xyz'])
        self.assertIn('bank-account-verify.xyz',restore_urls(masked,roots))
        self.assertEqual(public_urls('Open bank.company'), [])
        self.assertEqual(public_urls('Open bank.com.')[0][2], 'bank.com')
        self.assertEqual(public_urls('Open bank.com.evil.xyz')[0][2], 'bank.com.evil.xyz')

    def test_credit_limit_requires_explicit_reviewed_monetary_role(self):
        row={'text':'Han muc [MONEY] đồng. Xem https://bank.vn/offer',
             'language':'vi','key':'fixture-credit-role'}
        review={'publicURLHosts':['bank.vn'],'numberRoles':[],'timeRoles':[],
                'moneyRoles':['credit_limit']}
        template=review_template(row,review,4)
        self.assertIn('{{CREDIT_LIMIT}}',template)
        rendered=render_review(template,row,4)
        self.assertRegex(rendered,r'Han muc [3-9]0000000 đồng|Han muc [12][0-9]0000000 đồng')
        self.assertNotIn('$',rendered)
        with self.assertRaisesRegex(ValueError,'MONEY roles'):
            review_template(row,{**review,'moneyRoles':[]},4)

    def test_redacted_hosts_credentials_and_identifiers_are_rejected(self):
        for text in ['Open https://m.[NUMBER].com/account',
                     'Open https://user:secret@bank.vn/a',
                     'Open https://1234567890.bank.vn/a']:
            with self.assertRaises(ValueError):public_urls(text)

    def test_missing_colon_is_repaired_without_inventing_a_different_host(self):
        self.assertEqual(public_urls('Read https//mathx.vn.')[0][3],'https://mathx.vn/')
        self.assertEqual(public_urls('Read https://timhieuluatphongchongmatuy.vn/')[0][2],
                         'timhieuluatphongchongmatuy.vn')

    def test_existing_repairs_preserved_and_url_count_mismatch_fails(self):
        original='Review https://bank.vn/a and http://notice.vn/b'
        prior='Already corrected invoice and amount 50000 VND: https://example.com/m/123456 https://example.com/m/555555'
        output=restore_existing_render(prior,original,['bank.vn','notice.vn'])
        self.assertEqual(output,'Already corrected invoice and amount 50000 VND: https://bank.vn/ http://notice.vn/')
        with self.assertRaisesRegex(ValueError,'counts differ'):
            restore_existing_render(prior, 'Review https://bank.vn/a',['bank.vn'])

    def test_v4_materialization_keeps_locale_roles_and_external_holdout_gate(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);path=root/'source.csv'
            source='(QC) Uu dai [MONEY] dong. Tu choi soan TC gui [NUMBER]. Xem https://bank.vn/user/abc?token=secret'
            with path.open('w') as f:
                writer=csv.writer(f);writer.writerow(['text','label']);writer.writerow([source,'0'])
            review={'source':'vi','key':digest(source),'label':'promotion','split':'train','language':'vi',
                'reason':'Explicit content and public-host review','numberRoles':['shortcode'],'timeRoles':[],
                'publicURLHosts':['bank.vn']}
            review['sanitizedSHA256']=digest(review_template({'text':source,'language':'vi'},review,4))
            manifest={'schemaVersion':4,'profile':'typed-locale-host-v2','sources':[{
                'id':'vi','file':path.name,'format':'csv','language':'vi',
                'sha256':hashlib.sha256(path.read_bytes()).hexdigest(),'license':'CC-BY-4.0',
                'licenseEvidence':'https://example.com/license'}],'reviews':[review]}
            train,_,_=materialize(manifest,root,[]);out=train[0]
            self.assertEqual(out['label'],'promotion')
            self.assertIn('gui 199',out['text']);self.assertIn('https://bank.vn/',out['text'])
            self.assertNotIn('$',out['text']);self.assertNotIn('secret',out['text'])
            self.assertNotIn('example.com',out['text'])
            with self.assertRaisesRegex(ValueError,'holdout'):
                materialize(manifest,root,[source])
            changed=copy.deepcopy(manifest);changed['reviews'][0]['publicURLHosts']=['attacker.xyz']
            with self.assertRaisesRegex(ValueError,'review differs'):materialize(changed,root,[])


if __name__=='__main__':unittest.main()
