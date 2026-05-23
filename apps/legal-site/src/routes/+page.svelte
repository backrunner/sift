<script lang="ts">
</script>

<svelte:head>
  <title>Sift legal</title>
  <meta
    name="description"
    content="Privacy policy and terms of service for the Sift iOS app and hosted sample services."
  />
</svelte:head>

<section class="index">
  <div class="intro">
    <div class="brand-row">
      <svg width="28" height="28" viewBox="0 0 28 28" fill="none" aria-hidden="true">
        <rect x="2.25" y="2.25" width="23.5" height="23.5" rx="7.5" stroke="currentColor" stroke-opacity="0.18" />
        <rect x="5.5" y="5.5" width="17" height="17" rx="5.5" fill="var(--mint-soft)" />
        <path
          d="M9.25 14.1c1.7-2.3 5.6-4.1 9.35-4.1"
          stroke="var(--mint)"
          stroke-width="1.8"
          stroke-linecap="round"
        />
        <path
          d="M10.1 18.1c2.7 1.1 5.7 1 8.3-.35"
          stroke="var(--halo)"
          stroke-width="1.6"
          stroke-linecap="round"
          opacity="0.9"
        />
        <circle cx="18.7" cy="9.2" r="1.15" fill="var(--amber)" />
      </svg>
      <span>Sift legal</span>
    </div>

    <h1>Privacy and terms for the Sift app.</h1>
    <p>
      Sift is local-first. These pages cover the optional remote sample pipeline,
      the hosted legal site, and the service terms around them.
    </p>

    <div class="actions">
      <a class="button primary" href="/privacy">Privacy Policy</a>
      <a class="button" href="/tos">Terms of Service</a>
    </div>
  </div>

  <div class="panel">
    <div class="panel-title">Quick links</div>
    <ul>
      <li><a href="/privacy">How sample contribution works and what is stored</a></li>
      <li><a href="/tos">What the hosted service covers and how it may change</a></li>
    </ul>
  </div>
</section>

<style>
  .index {
    display: grid;
    grid-template-columns: minmax(0, 1.3fr) minmax(280px, 0.7fr);
    gap: 18px;
  }

  .intro,
  .panel {
    border: 1px solid var(--hairline);
    border-radius: 16px;
    background: color-mix(in srgb, var(--card) 90%, transparent);
    box-shadow: 0 16px 44px var(--shadow);
    padding: 24px;
  }

  .brand-row {
    display: inline-flex;
    align-items: center;
    gap: 10px;
    font-weight: 700;
    color: var(--muted);
  }

  h1 {
    margin: 18px 0 12px;
    font-size: 2.9rem;
    line-height: 1.04;
    letter-spacing: 0;
  }

  p {
    margin: 0;
    max-width: 56ch;
    font-size: 1.06rem;
    line-height: 1.65;
    color: var(--muted);
  }

  .actions {
    display: flex;
    flex-wrap: wrap;
    gap: 10px;
    margin-top: 22px;
  }

  .button {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    padding: 11px 16px;
    border-radius: 999px;
    border: 1px solid var(--hairline);
    background: var(--inset);
    text-decoration: none;
    font-weight: 700;
    transition:
      transform 160ms ease,
      background-color 160ms ease,
      border-color 160ms ease;
  }

  .button:hover,
  .button:focus-visible {
    outline: none;
    transform: translateY(-1px);
    border-color: color-mix(in srgb, var(--mint) 24%, var(--hairline));
  }

  .primary {
    background: var(--mint-soft);
    border-color: color-mix(in srgb, var(--mint) 28%, transparent);
  }

  .panel-title {
    font-size: 0.75rem;
    font-weight: 700;
    text-transform: uppercase;
    color: var(--muted);
  }

  ul {
    margin: 14px 0 0;
    padding-left: 1.2rem;
  }

  li + li {
    margin-top: 10px;
  }

  a {
    color: var(--mint);
    text-decoration: none;
  }

  a:hover,
  a:focus-visible {
    text-decoration: underline;
  }

  @media (max-width: 920px) {
    .index {
      grid-template-columns: 1fr;
    }
  }

  @media (max-width: 760px) {
    .intro,
    .panel {
      border-radius: 14px;
      padding: 20px;
    }

    h1 {
      font-size: 2.2rem;
    }
  }
</style>
