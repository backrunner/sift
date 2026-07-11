import type { SvedocsLocale, SvedocsResolvedConfig } from 'svedocs/core';

export function resolveSiteLocale(config: SvedocsResolvedConfig, pathname: string): SvedocsLocale {
  const firstSegment = pathname.split('/').find(Boolean);
  const routeLocale = config.i18n.locales.find((locale) => locale.path === firstSegment);
  const defaultLocale = config.i18n.locales.find((locale) => locale.code === config.i18n.defaultLocale);
  return routeLocale ?? defaultLocale ?? {
    code: 'zh-Hans',
    label: '中文',
    path: 'zh',
    hreflang: 'zh-CN',
    dir: 'ltr'
  };
}
