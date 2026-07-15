<script lang="ts">
  import InboxScene from '$lib/InboxScene.svelte';
  import SiteFooter from '$lib/SiteFooter.svelte';
  import SiteHeader from '$lib/SiteHeader.svelte';
</script>

<svelte:head>
  <title>Sift · 让短信少打扰一点</title>
  <meta
    name="description"
    content="Sift 在 iPhone 本地整理短信，默认不上传短信内容。垃圾、推广、验证码和重要通知，各归各位。"
  />
  <meta property="og:title" content="Sift" />
  <meta property="og:description" content="让短信少打扰一点，隐私留在 iPhone 上。" />
  <meta property="og:url" content="https://sift.alkinum.io/" />
</svelte:head>

<SiteHeader />

<main>
  <section class="landing-hero">
    <InboxScene />
    <div class="hero-copy">
      <h1>Sift</h1>
      <h2>让短信少打扰一点。</h2>
      <p>
        Sift 在 iPhone 本地整理垃圾短信、推广、验证码和重要通知。
        默认不上传短信内容，收件箱清爽一点，你也少被打断。
      </p>
      <div class="hero-actions">
        <a class="primary-link" href="#features">看功能介绍</a>
        <a class="secondary-link" href="#data">数据和高级版</a>
      </div>
    </div>
  </section>

  <section id="features" class="feature-band" aria-label="Sift 功能介绍">
    <div>
      <span>01</span>
      <h3>短信自动归类</h3>
      <p>垃圾、推广、验证码、快递、银行和出行通知分开放，重要短信更容易找到。</p>
    </div>
    <div>
      <span>02</span>
      <h3>规则可以自己定</h3>
      <p>按发送方或正文关键词设置放行或阻止，白名单和黑名单都由你掌控。</p>
    </div>
    <div>
      <span>03</span>
      <h3>样本贡献由你决定</h3>
      <p>默认不上传短信。只有你主动贡献时，才会先脱敏再通过 iCloud 提交。</p>
    </div>
  </section>

  <section id="data" class="detail-section">
    <div class="section-copy">
      <p class="eyebrow">数据怎么处理</p>
      <h2>默认在本机分类。愿意贡献样本时，也会先让你看清楚。</h2>
      <p>
        日常短信过滤不上传短信内容。你可以选择贡献脱敏样本来帮助改进模型；
        上传前会看到脱敏结果，之后也能导出或删除自己提交过的数据。
      </p>
    </div>
    <dl class="detail-list">
      <div>
        <dt>日常过滤</dt>
        <dd>通过 iOS 短信过滤扩展在 iPhone 上完成，不设置服务器判定通道。</dd>
      </div>
      <div>
        <dt>样本收集</dt>
        <dd>默认关闭；开启后先脱敏、再预览，确认后才上传到 CloudKit。</dd>
      </div>
      <div>
        <dt>删除和导出</dt>
        <dd>可在应用内导出提交记录，也可以删除最近一次或清空全部贡献数据。</dd>
      </div>
    </dl>
  </section>

  <section id="premium" class="premium-section">
    <div>
      <p class="eyebrow">Premium</p>
      <h2>需要更强的多语言识别时，再解锁高级模型。</h2>
    </div>
    <dl class="premium-list">
      <div>
        <dt>一次购买</dt>
        <dd>Premium 是非订阅制内购，购买后可在同一 Apple ID 下恢复。</dd>
      </div>
      <div>
        <dt>实时价格</dt>
        <dd>价格由 App Store 按地区显示，应用内结账页展示的价格就是实际支付价格。</dd>
      </div>
      <div>
        <dt>按需下载</dt>
        <dd>购买或恢复后，再下载 Transformer 多语言模型，不把模型大文件塞进基础安装包。</dd>
      </div>
    </dl>
  </section>
</main>

<SiteFooter />
