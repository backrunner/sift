<script lang="ts">
  import type { SvedocsPage, SvedocsResolvedConfig } from 'svedocs/core';
  import { createJsonLdScript, createPageAlternates, createPageMetadata } from 'svedocs/og';
  import SupportForm from './SupportForm.svelte';
  import { supportLocale } from './support';
  import { supportCopy } from './support-copy';
  import SiteFooter from './SiteFooter.svelte';
  import SiteHeader from './SiteHeader.svelte';

  export let page: SvedocsPage;
  export let pages: SvedocsPage[];
  export let config: SvedocsResolvedConfig;

  $: pageLocale = page.locale ?? config.i18n.defaultLocale ?? 'zh-Hans';
  $: isSupport = page.routePath === '/support' || page.routePath.endsWith('/support');
  $: formLocale = supportLocale(pageLocale);
  $: copy = supportCopy[formLocale];
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

<main class="legal-page" class:support-page={isSupport}>
  {#if isSupport}
    <div class="support-surface" lang={languageTag}>
      <section class="support-intro">
        <div class="support-topline">
          <span class="support-eyebrow"><span aria-hidden="true"></span>{copy.eyebrow}</span>
          <nav class="support-languages" aria-label={copy.language}>
            {#each [{code: 'zh-Hans', label: '中文', href: '/support'}, {code: 'en', label: 'EN', href: '/en/support'}, {code: 'ja', label: '日本語', href: '/ja/support'}] as choice}
              <a href={choice.href} lang={choice.code} hreflang={choice.code} aria-current={formLocale === choice.code ? 'page' : undefined}>{choice.label}</a>
            {/each}
          </nav>
        </div>
        <h1>{copy.title}</h1>
        <p>{copy.intro}</p>
      </section>
      <SupportForm locale={formLocale} />
    </div>
    <div class="support-alternative"><p>{copy.emailAlternative} <a href="mailto:support@alkinum.io?subject=Sift%20Support">support@alkinum.io <span aria-hidden="true">↗</span></a></p></div>
    <article class="support-help sd-prose" lang={languageTag}>{@html page.html}</article>
  {:else}
  <section class="legal-hero">
    <h1>{page.title}</h1>
    {#if page.description}
      <span>{page.description}</span>
    {/if}
  </section>
  <article class="legal-body sd-prose" lang={languageTag} dir={locale?.dir ?? 'ltr'}>
    {@html page.html}
  </article>
  {/if}
</main>

<SiteFooter {page} {pages} {config} localeCode={pageLocale} />

<style>
  .support-page { --support-inset: 32px; padding-top: 112px; }
  .support-surface, .support-help, .support-alternative { width: 100%; max-width: 840px; margin-inline: auto; }
  .support-surface { border: 1px solid var(--line); border-radius: 22px; background: var(--paper-soft); box-shadow: 0 12px 40px rgba(42, 38, 27, .04); }
  .support-intro { padding: 20px var(--support-inset) 28px; }
  .support-topline { display: flex; flex-wrap: wrap; align-items: center; justify-content: space-between; gap: 8px 16px; margin-bottom: 14px; }
  .support-eyebrow { display: flex; align-items: center; gap: 8px; color: var(--mint-strong); font-size: .8rem; font-weight: 650; }
  .support-eyebrow > span { width: 7px; height: 7px; border-radius: 50%; background: var(--mint); }
  .support-languages { display: flex; gap: 2px; }
  .support-languages a { display: inline-flex; align-items: center; justify-content: center; min-width: 44px; min-height: 44px; padding: 8px; color: var(--muted); text-decoration: none; font-size: .78rem; border-radius: 8px; }
  .support-languages a[aria-current] { color: var(--mint-strong); background: rgba(18, 138, 117, .07); font-weight: 650; }
  .support-languages a:hover { background: var(--paper); }
  .support-languages a:focus-visible { outline: 2px solid var(--mint); outline-offset: 2px; }
  .support-intro h1 { margin: 0; font-size: clamp(1.7rem, 3.6vw, 2.6rem); line-height: 1.3; letter-spacing: -.035em; text-wrap: balance; }
  .support-intro p { max-width: 640px; margin: 12px 0 0; color: var(--muted); font-size: .95rem; line-height: 1.8; }
  .support-alternative { padding: 16px 0 24px; color: var(--muted); font-size: .85rem; }
  .support-alternative p { margin: 0; display: flex; align-items: center; flex-wrap: wrap; gap: 4px 8px; }
  .support-alternative a { display: inline-flex; align-items: center; min-height: 44px; gap: 6px; color: var(--mint-strong); text-underline-offset: 4px; }
  .support-help { border-top: 1px solid var(--line); padding-top: 20px; }
  .support-help :global(h2) { margin: 0 0 12px; font-size: 1.05rem; }
  .support-help :global(details) { border-bottom: 1px solid var(--line); padding: 8px 0; }
  .support-help :global(summary) { min-height: 44px; align-content: center; font-size: .9rem; font-weight: 600; cursor: pointer; }
  .support-help :global(p), .support-help :global(li) { color: var(--muted); font-size: .875rem; line-height: 1.8; }
  .support-help :global(a) { color: var(--mint-strong); text-underline-offset: 3px; }
  @media (max-width: 600px) {
    .support-page { --support-inset: 20px; padding: 100px 16px 48px; }
    .support-surface { border-radius: 16px; }
    .support-intro { padding-top: 14px; padding-bottom: 24px; }
    .support-topline { margin-bottom: 12px; }
    .support-intro p { font-size: .9rem; }
  }
  @media (max-width: 360px) { .support-page { --support-inset: 16px; } }
</style>
