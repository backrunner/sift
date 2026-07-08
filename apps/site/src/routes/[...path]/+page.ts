import { loadSvedocsRoute } from '$lib/loadPage';
import pages from 'virtual:svedocs/page-index';
import type { PageLoad } from './$types';

export function entries() {
  return pages
    .filter((page) => page.routePath !== '/')
    .map((page) => ({ path: page.routePath.replace(/^\//, '') }));
}

export const load: PageLoad = ({ params }) => {
  return loadSvedocsRoute(params.path);
};
