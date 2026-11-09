import unittest
import sys
from pathlib import Path

sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from public_group_isolation import Groups,Suffixes,family,links,shingles,similar


class PublicGroupIsolationTests(unittest.TestCase):
    def setUp(self):
        self.psl=Suffixes('com\nuk\nco.uk\njp\n*.kawasaki.jp\n!city.kawasaki.jp\nvc\ntk\nnl\napp\nweb.app\n')

    def test_private_suffix_and_wildcard_exception(self):
        for host,expected in [('a.bank.co.uk','bank.co.uk'),('a.tenant.web.app','tenant.web.app'),
                              ('foo.city.kawasaki.jp','city.kawasaki.jp'),('a.b.kawasaki.jp','a.b.kawasaki.jp')]:
            with self.subTest(host=host):self.assertEqual(self.psl.registrable(host),expected)

    def test_shortener_tlds_and_email_exclusion(self):
        text='Visit tx.vc/a or bill.tk/pay and www.post.nl/now. Do not use me@company.com.'
        self.assertEqual([h for _,_,h in links(text,self.psl)],['tx.vc','bill.tk','www.post.nl'])
        self.assertEqual(family('Your item 123: tx.vc/a',self.psl),family('Your item 456: bill.tk/b',self.psl))

    def test_transitive_source_connections_ignore_row_ids(self):
        g=Groups()
        g.union(['message:1','host:one.com'])
        g.union(['message:2','host:two.com'])
        g.union(['campaign:unrelated-77','host:one.com','host:two.com'])
        self.assertEqual(g.find('message:1'),g.find('message:2'))
        self.assertNotEqual(g.find('campaign:1'),g.find('message:1'))

    def test_similarity_removes_tracking_and_amount_variants(self):
        a=shingles('Your payment of 32 is ready: tx.vc/a',self.psl)
        b=shingles('Your payment of 46 is ready: bill.tk/b',self.psl)
        self.assertTrue(similar(a,b))
        self.assertFalse(similar(a,shingles('Lets meet for lunch after work',self.psl)))
