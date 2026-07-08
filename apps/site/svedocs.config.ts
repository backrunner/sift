import { defineConfig } from 'svedocs/config';

export default defineConfig({
  site: {
    name: 'Sift',
    title: 'Sift',
    description: 'Privacy-first SMS filtering for iPhone.',
    url: 'https://sift.alkinum.io'
  },
  content: {
    root: 'content',
    pages: 'content/pages',
    docs: 'content/docs'
  },
  build: {
    mode: 'edge'
  },
  theme: {
    defaultMode: 'light',
    brand: {
      label: 'Sift',
      href: '/',
      logo: '/sift-icon-rounded.png',
      mark: false
    },
    nav: [
      { label: 'Privacy', href: '/privacy' },
      { label: 'Terms', href: '/terms' },
      { label: 'Support', href: '/support' }
    ],
    footer: {
      text: '© 2026 Alkinum',
      links: [
        { label: 'Privacy', href: '/privacy' },
        { label: 'Terms', href: '/terms' },
        { label: 'Support', href: '/support' },
        { label: 'GitHub', href: 'https://github.com/backrunner/sift', external: true }
      ]
    }
  },
  search: false,
  ai: false,
  i18n: false,
  seo: {
    sitemap: true,
    robots: true,
    defaultAuthor: 'Alkinum',
    ogImage: false
  }
});
