import { siteUrl } from '$lib/site';

export const prerender = true;

export function GET() {
  return new Response(
    [
      'User-agent: *',
      'Allow: /',
      `Sitemap: ${siteUrl}/sitemap.xml`,
      ''
    ].join('\n'),
    {
      headers: {
        'content-type': 'text/plain; charset=utf-8'
      }
    }
  );
}
