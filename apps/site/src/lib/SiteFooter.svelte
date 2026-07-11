<script lang="ts">
  import { legalLinks } from './site';
</script>

<footer class="site-footer">
  <div>
    <img src="/sift-icon-rounded.png" alt="" width="38" height="38" />
    <p>Sift 在本地整理短信，也把隐私边界留在本地。</p>
  </div>
  <nav aria-label="Footer navigation">
    {#each legalLinks as item}
      <a href={item.href}>{item.label}</a>
    {/each}
    <a href="https://github.com/backrunner/sift" rel="noreferrer">GitHub</a>
  </nav>
  <small>© 2026 Alkinum. Sift name and icon are all rights reserved.</small>
</footer>
