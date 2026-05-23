<script lang="ts">
  import "../app.css";
</script>

<svelte:head>
  <meta name="color-scheme" content="light dark" />
  <meta name="theme-color" content="#0e1118" media="(prefers-color-scheme: dark)" />
  <meta name="theme-color" content="#f5f6f8" media="(prefers-color-scheme: light)" />
</svelte:head>

<div class="shell">
  <header class="topbar">
    <a class="brand" href="/" aria-label="Sift home">
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
      <span>Sift</span>
    </a>

    <nav class="nav" aria-label="Legal sections">
      <a href="/privacy">Privacy</a>
      <a href="/tos">TOS</a>
    </nav>
  </header>

  <main>
    <slot />
  </main>
</div>

<style>
  .shell {
    min-height: 100vh;
    padding: 18px 18px 40px;
  }

  .topbar {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 16px;
    max-width: 1160px;
    margin: 0 auto;
    padding: 10px 12px;
    border: 1px solid var(--hairline);
    border-radius: 16px;
    background: color-mix(in srgb, var(--card) 88%, transparent);
    box-shadow: 0 18px 50px var(--shadow);
    backdrop-filter: blur(18px);
    position: sticky;
    top: 12px;
    z-index: 10;
  }

  .brand {
    display: inline-flex;
    align-items: center;
    gap: 10px;
    text-decoration: none;
    font-weight: 700;
    letter-spacing: 0;
  }

  .brand span {
    font-size: 1rem;
  }

  .nav {
    display: inline-flex;
    gap: 8px;
  }

  .nav a {
    text-decoration: none;
    font-size: 0.95rem;
    font-weight: 600;
    color: var(--muted);
    padding: 9px 12px;
    border-radius: 999px;
    border: 1px solid transparent;
    transition:
      color 160ms ease,
      background-color 160ms ease,
      border-color 160ms ease;
  }

  .nav a:hover,
  .nav a:focus-visible {
    color: var(--ink);
    background: var(--inset);
    border-color: var(--hairline);
    outline: none;
  }

  main {
    max-width: 1160px;
    margin: 24px auto 0;
  }

  @media (max-width: 760px) {
    .shell {
      padding-inline: 12px;
    }

    .topbar {
      top: 8px;
      border-radius: 14px;
      padding: 10px;
      align-items: flex-start;
      flex-direction: column;
    }

    .nav {
      width: 100%;
    }

    .nav a {
      flex: 1;
      text-align: center;
    }

    main {
      margin-top: 16px;
    }
  }
</style>
