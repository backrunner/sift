import type { Handle } from '@sveltejs/kit';
import { resolveSiteLocale } from '$lib/locale';
import config from 'virtual:svedocs/config';

export const handle: Handle = async ({ event, resolve }) => {
  const locale = resolveSiteLocale(config, event.url.pathname);
  const languageTag = locale.hreflang ?? locale.code;
  const direction = locale.dir ?? 'ltr';

  return resolve(event, {
    transformPageChunk: ({ html }) => html.replace(
      'lang="zh-CN" dir="ltr" data-sift-locale',
      `lang="${languageTag}" dir="${direction}"`
    )
  });
};
