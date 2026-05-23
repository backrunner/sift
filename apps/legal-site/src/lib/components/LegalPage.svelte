<script lang="ts">
  import type { Section, SummaryStat } from "$lib/content/legal-types";

  export let eyebrow: string;
  export let title: string;
  export let lead: string;
  export let updated: string;
  export let summaryTitle: string;
  export let summary: SummaryStat[];
  export let sections: Section[];
  export let footerNote: string;
</script>

<svelte:head>
  <title>{title}</title>
  <meta name="description" content={lead} />
</svelte:head>

<section class="hero">
  <div class="hero-copy">
    <div class="eyebrow">{eyebrow}</div>
    <h1>{title}</h1>
    <p>{lead}</p>

    <div class="meta-row">
      <span class="chip">Updated {updated}</span>
      <span class="chip">Sift iOS</span>
      <span class="chip chip-alt">sift.alkinum.io</span>
    </div>
  </div>

  <aside class="summary" aria-label={summaryTitle}>
    <div class="summary-title">{summaryTitle}</div>
    <div class="summary-grid">
      {#each summary as stat}
        <div class="stat">
          <div class="stat-label">{stat.label}</div>
          <div class="stat-value">{stat.value}</div>
          <div class="stat-note">{stat.note}</div>
        </div>
      {/each}
    </div>
  </aside>
</section>

<div class="content-grid">
  <div class="content-stack">
    {#each sections as section}
      <section class="panel">
        <h2>{section.title}</h2>

        {#each section.paragraphs as paragraph}
          <p>{paragraph}</p>
        {/each}

        {#if section.callout}
          <div class="callout">{section.callout}</div>
        {/if}

        {#if section.bullets}
          <ul>
            {#each section.bullets as bullet}
              <li>{bullet}</li>
            {/each}
          </ul>
        {/if}
      </section>
    {/each}
  </div>

  <aside class="side-note">
    <div class="side-card">
      <div class="side-label">Contact</div>
      <a href="mailto:privacy@sift.alkinum.io">privacy@sift.alkinum.io</a>
      <p>{footerNote}</p>
    </div>
  </aside>
</div>

<style>
  .hero {
    display: grid;
    grid-template-columns: minmax(0, 1.4fr) minmax(280px, 0.8fr);
    gap: 18px;
    align-items: start;
    margin-bottom: 18px;
  }

  .hero-copy,
  .summary,
  .panel,
  .side-card {
    border: 1px solid var(--hairline);
    border-radius: 16px;
    background: color-mix(in srgb, var(--card) 90%, transparent);
    box-shadow: 0 16px 44px var(--shadow);
    backdrop-filter: blur(16px);
  }

  .hero-copy {
    padding: 28px 24px;
  }

  .eyebrow,
  .summary-title,
  .side-label {
    font-size: 0.75rem;
    font-weight: 700;
    letter-spacing: 0;
    text-transform: uppercase;
    color: var(--muted);
  }

  h1 {
    margin: 12px 0 12px;
    font-size: 3rem;
    line-height: 1.02;
    letter-spacing: 0;
  }

  .hero-copy > p {
    margin: 0;
    max-width: 54ch;
    font-size: 1.08rem;
    line-height: 1.6;
    color: var(--muted);
  }

  .meta-row {
    display: flex;
    flex-wrap: wrap;
    gap: 8px;
    margin-top: 18px;
  }

  .chip {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    padding: 8px 11px;
    border-radius: 999px;
    background: var(--mint-soft);
    border: 1px solid color-mix(in srgb, var(--mint) 20%, transparent);
    color: var(--ink);
    font-size: 0.9rem;
    font-weight: 600;
  }

  .chip-alt {
    background: var(--halo-soft);
    border-color: color-mix(in srgb, var(--halo) 22%, transparent);
  }

  .summary {
    padding: 18px;
  }

  .summary-grid {
    display: grid;
    grid-template-columns: repeat(2, minmax(0, 1fr));
    gap: 12px;
    margin-top: 14px;
  }

  .stat {
    padding: 14px;
    border-radius: 14px;
    background: var(--inset);
    border: 1px solid var(--hairline);
  }

  .stat-label {
    font-size: 0.75rem;
    color: var(--muted);
    text-transform: uppercase;
    letter-spacing: 0;
  }

  .stat-value {
    margin-top: 8px;
    font-size: 1.05rem;
    font-weight: 700;
  }

  .stat-note {
    margin-top: 6px;
    font-size: 0.92rem;
    line-height: 1.45;
    color: var(--muted);
  }

  .content-grid {
    display: grid;
    grid-template-columns: minmax(0, 1.4fr) minmax(240px, 0.65fr);
    gap: 18px;
  }

  .content-stack {
    display: grid;
    gap: 14px;
  }

  .panel {
    padding: 20px 20px 18px;
  }

  .panel h2 {
    margin: 0 0 12px;
    font-size: 1.15rem;
    line-height: 1.25;
  }

  .panel p {
    margin: 0 0 12px;
    font-size: 1rem;
    line-height: 1.68;
    color: var(--ink);
  }

  .panel p:last-child {
    margin-bottom: 0;
  }

  .panel ul {
    margin: 12px 0 0;
    padding-left: 1.2rem;
    color: var(--ink);
  }

  .panel li + li {
    margin-top: 8px;
  }

  .callout {
    margin: 14px 0 0;
    padding: 14px 15px;
    border-radius: 14px;
    background: var(--mint-soft);
    border: 1px solid color-mix(in srgb, var(--mint) 20%, transparent);
    font-size: 0.96rem;
    line-height: 1.55;
  }

  .side-note {
    position: relative;
  }

  .side-card {
    padding: 18px;
    position: sticky;
    top: 92px;
  }

  .side-card a {
    display: inline-block;
    margin-top: 12px;
    font-weight: 700;
    color: var(--mint);
    text-decoration: none;
    word-break: break-word;
  }

  .side-card p {
    margin: 12px 0 0;
    color: var(--muted);
    font-size: 0.95rem;
    line-height: 1.55;
  }

  @media (max-width: 980px) {
    .hero,
    .content-grid {
      grid-template-columns: 1fr;
    }

    .side-card {
      position: static;
    }
  }

  @media (max-width: 760px) {
    .hero-copy {
      padding: 22px 18px;
    }

    h1 {
      font-size: 2.3rem;
    }

    .summary-grid {
      grid-template-columns: 1fr;
    }

    .panel,
    .summary,
    .side-card {
      border-radius: 14px;
    }
  }
</style>
