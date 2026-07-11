<script lang="ts">
  const lanes = [
    [
      { label: '验证码', text: '登录验证码已在本地识别。', tone: 'mint' },
      { label: '快递', text: '取件和派送短信自动归位。', tone: 'blue' },
      { label: '推广', text: '促销短信不再挤在前面。', tone: 'amber' }
    ],
    [
      { label: '风险', text: '可疑链接和日常短信分开。', tone: 'rose' },
      { label: '银行', text: '账户通知留在显眼的位置。', tone: 'mint' },
      { label: '出行', text: '行程、票务和提醒各有去处。', tone: 'blue' }
    ]
  ];
</script>

<div class="inbox-scene" aria-hidden="true">
  <div class="scene-shade"></div>
  <div class="scene-sweep"></div>
  <div class="scene-thread scene-thread-a">
    {#each lanes[0] as bubble}
      <span data-tone={bubble.tone}>
        <i>{bubble.label}</i>
        <b>{bubble.text}</b>
      </span>
    {/each}
  </div>
  <div class="scene-thread scene-thread-b">
    {#each lanes[1] as bubble}
      <span data-tone={bubble.tone}>
        <i>{bubble.label}</i>
        <b>{bubble.text}</b>
      </span>
    {/each}
  </div>
  <div class="scene-device">
    <img src="/sift-icon-rounded.png" alt="" width="120" height="120" />
    <span>短信本地过滤</span>
  </div>
</div>
