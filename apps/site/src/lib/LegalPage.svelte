<script lang="ts">
  import type { SvedocsPage, SvedocsResolvedConfig } from 'svedocs/core';
  import { createJsonLdScript, createPageAlternates, createPageMetadata } from 'svedocs/og';
  import SiteFooter from './SiteFooter.svelte';
  import SiteHeader from './SiteHeader.svelte';

  export let page: SvedocsPage;
  export let pages: SvedocsPage[];
  export let config: SvedocsResolvedConfig;

  $: pageLocale = page.locale ?? config.i18n.defaultLocale ?? 'zh-Hans';
  $: locale = config.i18n.locales.find((candidate) => candidate.code === pageLocale);
  $: languageTag = locale?.hreflang ?? pageLocale;
  $: translations = pages.filter((candidate) => (
    !candidate.hidden
    && candidate.kind === page.kind
    && candidate.scopePath === page.scopePath
  ));
  $: localeOptions = config.i18n.locales.flatMap((candidate) => {
    const translation = translations.find((item) => item.locale === candidate.code);
    return translation ? [{ ...candidate, href: translation.routePath }] : [];
  });
  $: languageNavigationLabel = ({
    'zh-Hans': '页面语言',
    en: 'Page language',
    ja: 'ページの言語'
  } as Record<string, string>)[pageLocale] ?? 'Page language';
  $: metadata = createPageMetadata(config, page, pages);
  $: alternates = createPageAlternates(config, page, pages);
  $: jsonLdScript = createJsonLdScript(metadata.jsonLd);
</script>

<svelte:head>
  <title>{metadata.title}</title>
  <meta name="description" content={metadata.description} />
  {#if metadata.canonical}
    <link rel="canonical" href={metadata.canonical} />
  {/if}
  {#each alternates as alternate}
    <link rel="alternate" hreflang={alternate.lang} href={alternate.href} />
  {/each}
  <meta property="og:title" content={metadata.openGraph.title} />
  <meta property="og:description" content={metadata.openGraph.description} />
  <meta property="og:type" content={metadata.openGraph.type} />
  <meta property="og:site_name" content={metadata.openGraph.siteName} />
  <meta property="og:locale" content={metadata.openGraph.locale} />
  {#each metadata.openGraph.alternateLocales ?? [] as alternateLocale}
    <meta property="og:locale:alternate" content={alternateLocale} />
  {/each}
  {#if metadata.openGraph.url}
    <meta property="og:url" content={metadata.openGraph.url} />
  {/if}
  <meta name="twitter:card" content={metadata.twitter.card} />
  <meta name="twitter:title" content={metadata.twitter.title} />
  <meta name="twitter:description" content={metadata.twitter.description} />
  {@html jsonLdScript}
</svelte:head>

<SiteHeader {page} {pages} {config} localeCode={pageLocale} />

<main class="legal-page">
  <section class="legal-hero">
    <h1>{page.title}</h1>
    {#if localeOptions.length > 1}
      <nav class="language-switcher" aria-label={languageNavigationLabel}>
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
    {#if page.description}
      <span>{page.description}</span>
    {/if}
  </section>
  <article class="legal-body" lang={languageTag} dir={locale?.dir ?? 'ltr'}>
    {@html page.html}
  </article>
</main>

<SiteFooter {page} {pages} {config} localeCode={pageLocale} />
