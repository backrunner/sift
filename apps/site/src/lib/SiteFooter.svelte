<script lang="ts">
  import type { SvedocsPage, SvedocsResolvedConfig } from 'svedocs/core';
  import { resolveSvedocsHref } from 'svedocs/routes';
  import { legalLinks } from './site';

  export let page: SvedocsPage | undefined = undefined;
  export let pages: SvedocsPage[] = [];
  export let config: SvedocsResolvedConfig | undefined = undefined;
  export let localeCode: string | undefined = undefined;

  const footerCopy = {
    'zh-Hans': {
      lang: 'zh-Hans',
      intro: 'Sift 在本地整理短信，也把隐私边界留在本地。',
      navigation: '页脚导航',
      languageNavigation: '网站语言',
      links: ['隐私政策', '服务条款', '技术支持'],
      backToTop: '返回顶部',
      backToTopLabel: '返回页面顶部'
    },
    en: {
      lang: 'en',
      intro: 'Sift organizes messages on device and keeps the privacy boundary there.',
      navigation: 'Footer navigation',
      languageNavigation: 'Site language',
      links: ['Privacy Policy', 'Terms', 'Support'],
      backToTop: 'Back to top',
      backToTopLabel: 'Back to the top of the page'
    },
    ja: {
      lang: 'ja',
      intro: 'Siftは端末上でメッセージを整理し、プライバシーの境界も端末内に保ちます。',
      navigation: 'フッターナビゲーション',
      languageNavigation: 'サイトの言語',
      links: ['プライバシーポリシー', '利用規約', 'サポート'],
      backToTop: 'ページ上部へ',
      backToTopLabel: 'ページ上部へ戻る'
    }
  } as const;

  $: copy = footerCopy[localeCode as keyof typeof footerCopy] ?? footerCopy['zh-Hans'];
  $: pageLocale = localeCode ?? page?.locale ?? config?.i18n.defaultLocale ?? 'zh-Hans';
  $: translations = page
    ? pages.filter((candidate) => (
        !candidate.hidden
        && candidate.kind === page.kind
        && candidate.scopePath === page.scopePath
      ))
    : [];
  $: localeOptions = config
    ? config.i18n.locales.flatMap((candidate) => {
        const translation = translations.find((item) => item.locale === candidate.code);
        return translation ? [{ ...candidate, href: translation.routePath }] : [];
      })
    : [];
  $: localizedLegalLinks = config
    ? legalLinks.map((item, index) => ({
        ...item,
        label: copy.links[index] ?? item.label,
        href: resolveSvedocsHref({ href: item.href, pages, config, page, localeCode }).href
      }))
    : legalLinks.map((item, index) => ({ ...item, label: copy.links[index] ?? item.label }));
</script>

<footer class="site-footer" lang={copy.lang}>
  <div class="footer-intro">
    <img src="/sift-icon-rounded.png" alt="" width="38" height="38" />
    <p>{copy.intro}</p>
  </div>
  <div class="footer-navigation">
    <nav class="footer-links" aria-label={copy.navigation}>
      {#each localizedLegalLinks as item}
        <a href={item.href}>{item.label}</a>
      {/each}
      <a href="https://github.com/backrunner/sift" rel="noreferrer">GitHub</a>
    </nav>
    <div class="footer-utilities">
      {#if localeOptions.length > 1}
        <nav class="footer-language-switcher" aria-label={copy.languageNavigation}>
          {#each localeOptions as option}
            <a
              href={option.href}
              lang={option.hreflang ?? option.code}
              aria-current={pageLocale === option.code ? 'page' : undefined}
            >
              {option.label}
            </a>
          {/each}
        </nav>
      {/if}
      <a class="back-to-top" href="#top" aria-label={copy.backToTopLabel} title={copy.backToTop}>
        <span aria-hidden="true">↑</span>
        <span class="back-to-top-label">{copy.backToTop}</span>
      </a>
    </div>
  </div>
  <small lang="en">© 2026 Alkinum. Sift name and icon are all rights reserved.</small>
</footer>
