<script lang="ts">
  import type { SvedocsPage, SvedocsResolvedConfig } from 'svedocs/core';
  import { resolveSvedocsHref } from 'svedocs/routes';
  import { navItems } from './site';

  export let page: SvedocsPage | undefined = undefined;
  export let pages: SvedocsPage[] = [];
  export let config: SvedocsResolvedConfig | undefined = undefined;
  export let localeCode: string | undefined = undefined;

  $: localizedNavItems = config
    ? navItems.map((item) => ({
        ...item,
        href: resolveSvedocsHref({ href: item.href, pages, config, page, localeCode }).href
      }))
    : navItems;
</script>

<header class="site-header" lang="zh-Hans">
  <a class="brand-link" href="/" aria-label="Sift home">
    <img src="/sift-icon-rounded.png" alt="" width="34" height="34" />
    <span>Sift</span>
  </a>
  <nav class="site-nav" aria-label="Primary navigation">
    {#each localizedNavItems as item}
      <a href={item.href}>{item.label}</a>
    {/each}
  </nav>
</header>
