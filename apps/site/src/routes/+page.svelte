<script lang="ts">
  import InboxScene from '$lib/InboxScene.svelte';
  import SiteFooter from '$lib/SiteFooter.svelte';
  import SiteHeader from '$lib/SiteHeader.svelte';
</script>

<svelte:head>
  <title>Sift · Privacy-first SMS filtering for iPhone</title>
  <meta
    name="description"
    content="Sift filters SMS on iPhone with local-first classification, optional sanitized contribution, and a Premium multilingual model."
  />
  <meta property="og:title" content="Sift" />
  <meta property="og:description" content="Privacy-first SMS filtering for iPhone." />
  <meta property="og:url" content="https://sift.alkinum.io/" />
</svelte:head>

<SiteHeader />

<main>
  <section class="landing-hero">
    <InboxScene />
    <div class="hero-copy">
      <p class="eyebrow">Privacy-first SMS filtering for iPhone</p>
      <h1>Sift</h1>
      <h2>短信安静下来，隐私留在 iPhone 上。</h2>
      <p>
        Sift 在本地分类垃圾、推广和重要通知。默认不把短信内容发往服务器，
        也不给收件箱增加新的负担。
      </p>
      <div class="hero-actions">
        <a class="primary-link" href="/privacy">Read Privacy Policy</a>
        <a class="secondary-link" href="/support">Get Support</a>
      </div>
    </div>
  </section>

  <section class="quiet-band" aria-label="Sift principles">
    <div>
      <span>01</span>
      <h3>Local-first filtering</h3>
      <p>Incoming SMS is classified on the iPhone through the iOS filtering extension.</p>
    </div>
    <div>
      <span>02</span>
      <h3>Review before sharing</h3>
      <p>Optional contribution shows a redaction preview before anything reaches CloudKit.</p>
    </div>
    <div>
      <span>03</span>
      <h3>Premium without a subscription</h3>
      <p>A one-time purchase unlocks the on-demand multilingual Transformer model.</p>
    </div>
  </section>

  <section class="privacy-section">
    <div class="section-copy">
      <p class="eyebrow">Built for reviewable trust</p>
      <h2>No analytics SDKs. No ad tracking. No server-side SMS classifier.</h2>
      <p>
        Sift keeps its promises narrow and inspectable: local rules, local counts,
        optional sanitized samples, and in-app export or deletion controls.
      </p>
    </div>
    <dl class="assurance-list">
      <div>
        <dt>Filtering path</dt>
        <dd>On device by default, without a network defer classifier.</dd>
      </div>
      <div>
        <dt>Contribution</dt>
        <dd>Opt-in, sanitized, previewed, exportable, and erasable.</dd>
      </div>
      <div>
        <dt>Purchases</dt>
        <dd>StoreKit handles payment. Sift only checks entitlement on device.</dd>
      </div>
    </dl>
  </section>

  <section class="final-cta">
    <p class="eyebrow">Public documents</p>
    <h2>Everything App Store review needs is here.</h2>
    <div>
      <a href="/privacy">Privacy Policy</a>
      <a href="/terms">Terms of Service</a>
      <a href="/support">Technical Support</a>
    </div>
  </section>
</main>

<SiteFooter />
