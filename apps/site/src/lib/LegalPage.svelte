<script lang="ts">
  import type { SvedocsPage } from 'svedocs/core';
  import SiteFooter from './SiteFooter.svelte';
  import SiteHeader from './SiteHeader.svelte';

  export let page: SvedocsPage;
</script>

<svelte:head>
  <title>{page.title} · Sift</title>
  {#if page.description}
    <meta name="description" content={page.description} />
  {/if}
</svelte:head>

<SiteHeader />

<main class="legal-page">
  <section class="legal-hero">
    <p>Sift 公开文档</p>
    <h1>{page.title}</h1>
    {#if page.description}
      <span>{page.description}</span>
    {/if}
  </section>
  <article class="legal-body">
    {@html page.html}
  </article>
</main>

<SiteFooter />
