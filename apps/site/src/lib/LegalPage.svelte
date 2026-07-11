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
    {#if page.description}
      <span>{page.description}</span>
    {/if}
  </section>
  <article class="legal-body sd-prose" lang={languageTag} dir={locale?.dir ?? 'ltr'}>
    {@html page.html}
  </article>
</main>

<SiteFooter {page} {pages} {config} localeCode={pageLocale} />
