<script lang="ts">
  import { navItems } from './site';
</script>

<header class="site-header">
  <a class="brand-link" href="/" aria-label="Sift home">
    <img src="/sift-icon-rounded.png" alt="" width="34" height="34" />
    <span>Sift</span>
  </a>
  <nav class="site-nav" aria-label="Primary navigation">
    {#each navItems as item}
      <a href={item.href}>{item.label}</a>
    {/each}
  </nav>
</header>
