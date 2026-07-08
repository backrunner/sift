<script lang="ts">
  import { legalLinks, supportEmail } from './site';
</script>

<footer class="site-footer">
  <div>
    <img src="/sift-icon-rounded.png" alt="" width="38" height="38" />
    <p>Sift keeps SMS filtering local-first and privacy-forward.</p>
  </div>
  <nav aria-label="Footer navigation">
    {#each legalLinks as item}
      <a href={item.href}>{item.label}</a>
    {/each}
    <a href={`mailto:${supportEmail}`}>{supportEmail}</a>
    <a href="https://github.com/backrunner/sift" rel="noreferrer">GitHub</a>
  </nav>
  <small>© 2026 Alkinum. Sift name and icon are all rights reserved.</small>
</footer>
