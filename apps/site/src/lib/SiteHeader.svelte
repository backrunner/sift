<script lang="ts">
  import type { SvedocsPage, SvedocsResolvedConfig } from 'svedocs/core';
  import { resolveSvedocsHref } from 'svedocs/routes';
  import { navItems } from './site';

  export let page: SvedocsPage | undefined = undefined;
  export let pages: SvedocsPage[] = [];
  export let config: SvedocsResolvedConfig | undefined = undefined;
  export let localeCode: string | undefined = undefined;

  const headerCopy = {
    'zh-Hans': {
      lang: 'zh-Hans',
      home: 'Sift 首页',
      navigation: '主导航',
      links: ['功能', '数据', '高级版']
    },
    en: {
      lang: 'en',
      home: 'Sift home',
      navigation: 'Primary navigation',
      links: ['Features', 'Data', 'Premium']
    },
    ja: {
      lang: 'ja',
      home: 'Sift ホーム',
      navigation: 'メインナビゲーション',
      links: ['機能', 'データ', 'Premium']
    }
  } as const;

  $: copy = headerCopy[localeCode as keyof typeof headerCopy] ?? headerCopy['zh-Hans'];
  $: localizedNavItems = config
    ? navItems.map((item, index) => ({
        ...item,
        label: copy.links[index] ?? item.label,
        href: resolveSvedocsHref({ href: item.href, pages, config, page, localeCode }).href
      }))
    : navItems.map((item, index) => ({ ...item, label: copy.links[index] ?? item.label }));
</script>

<header class="site-header" lang={copy.lang}>
  <a class="brand-link" href="/" aria-label={copy.home}>
    <img src="/sift-icon-rounded.png" alt="" width="34" height="34" />
    <span>Sift</span>
  </a>
  <nav class="site-nav" aria-label={copy.navigation}>
    {#each localizedNavItems as item}
      <a href={item.href}>{item.label}</a>
    {/each}
  </nav>
</header>
