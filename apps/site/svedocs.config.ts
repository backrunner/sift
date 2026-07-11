import { defineConfig } from 'svedocs/config';

export default defineConfig({
  site: {
    name: 'Sift',
    title: 'Sift',
    description: '让短信少打扰一点，隐私留在 iPhone 上。',
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
      { label: '功能', href: '/#features' },
      { label: '数据', href: '/#data' },
      { label: '高级版', href: '/#premium' }
    ],
    footer: {
      text: '© 2026 Alkinum',
      links: [
        { label: '隐私政策', href: '/privacy' },
        { label: '服务条款', href: '/terms' },
        { label: '技术支持', href: '/support' },
        { label: 'GitHub', href: 'https://github.com/backrunner/sift', external: true }
      ]
    }
  },
  search: false,
  ai: false,
  checks: {
    translations: true
  },
  i18n: {
    defaultLocale: 'zh-Hans',
    prefixDefaultLocale: false,
    locales: [
      { code: 'zh-Hans', label: '中文', path: 'zh', hreflang: 'zh-CN', dir: 'ltr' },
      { code: 'en', label: 'English', path: 'en', hreflang: 'en', dir: 'ltr' },
      { code: 'ja', label: '日本語', path: 'ja', hreflang: 'ja', dir: 'ltr' }
    ],
    messages: {
      'zh-Hans': {
        'heading.anchor': '链接到此章节'
      },
      en: {
        'heading.anchor': 'Link to this section'
      },
      ja: {
        'heading.anchor': 'このセクションへのリンク'
      }
    }
  },
  seo: {
    sitemap: true,
    robots: true,
    defaultAuthor: 'Alkinum',
    ogImage: false
  }
});
