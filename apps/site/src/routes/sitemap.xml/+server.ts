import pages from 'virtual:svedocs/pages';
import { siteUrl } from '$lib/site';

export const prerender = true;

export function GET() {
  const urls = ['/', ...pages.map((page) => page.routePath)]
    .filter((path, index, list) => list.indexOf(path) === index)
    .map((path) => {
      const loc = path === '/' ? siteUrl : `${siteUrl}${path}`;
      return `<url><loc>${loc}</loc></url>`;
    })
    .join('');

  return new Response(`<?xml version="1.0" encoding="UTF-8"?><urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">${urls}</urlset>`, {
    headers: {
      'content-type': 'application/xml; charset=utf-8'
    }
  });
}
