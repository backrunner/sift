import adapter from "@sveltejs/adapter-static";

/** @type {import('@sveltejs/kit').Config} */
const config = {
  kit: {
    adapter: adapter({
      fallback: undefined
    }),
    prerender: {
      entries: ["/", "/privacy", "/tos"]
    }
  }
};

export default config;
