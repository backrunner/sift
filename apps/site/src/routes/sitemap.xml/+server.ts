import config from 'virtual:svedocs/config';
import pages from 'virtual:svedocs/pages';
import { siteUrl } from '$lib/site';
import { createSitemapXml } from 'svedocs/og';

export const prerender = true;

export function GET() {
  const sitemap = createSitemapXml(config, pages);
  const homepage = `  <url>\n    <loc>${siteUrl}</loc>\n  </url>`;
  const document = sitemap.replace('</urlset>', `${homepage}\n</urlset>`);

  return new Response(document, {
    headers: {
      'content-type': 'application/xml; charset=utf-8'
    }
  });
}
