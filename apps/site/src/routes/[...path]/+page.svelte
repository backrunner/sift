<script lang="ts">
  import LegalPage from '$lib/LegalPage.svelte';

  export let data;
</script>

<LegalPage page={data.page} />
