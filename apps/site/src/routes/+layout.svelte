<script lang="ts">
  import { browser } from '$app/environment';
  import { page } from '$app/stores';
  import '$lib/styles.css';
  import { resolveSiteLocale } from '$lib/locale';
  import config from 'virtual:svedocs/config';

  $: documentLocale = resolveSiteLocale(config, $page.url.pathname);
  $: if (browser) {
    document.documentElement.lang = documentLocale.hreflang ?? documentLocale.code;
    document.documentElement.dir = documentLocale.dir ?? 'ltr';
  }
</script>

<div id="top" aria-hidden="true"></div>
<slot />
