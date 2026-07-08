import adapterAuto from '@sveltejs/adapter-auto';
import adapterCloudflare from '@sveltejs/adapter-cloudflare';
import adapterStatic from '@sveltejs/adapter-static';
import { vitePreprocess } from '@sveltejs/vite-plugin-svelte';
import { svedocsPreprocess, svedocsSvelteExtensions } from 'svedocs/svelte';

const mode = process.env.SIFT_SITE_BUILD_MODE ?? 'edge';
const adapter =
  mode === 'edge'
    ? adapterCloudflare({ platformProxy: { remoteBindings: false, persist: false } })
    : mode === 'static'
      ? adapterStatic({ strict: false })
      : mode === 'spa'
        ? adapterStatic({ fallback: '200.html' })
        : adapterAuto();

export default {
  extensions: svedocsSvelteExtensions,
  preprocess: [vitePreprocess(), svedocsPreprocess()],
  kit: {
    adapter
  }
};
