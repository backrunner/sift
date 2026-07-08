<script lang="ts">
  const lanes = [
    [
      { label: 'Verification', text: 'Your login code was recognized locally.', tone: 'mint' },
      { label: 'Delivery', text: 'Pickup and courier messages stay easy to find.', tone: 'blue' },
      { label: 'Promo', text: 'Campaigns move out of the way.', tone: 'amber' }
    ],
    [
      { label: 'Spam', text: 'Suspicious links are kept apart from daily SMS.', tone: 'rose' },
      { label: 'Banking', text: 'Account notices remain visible.', tone: 'mint' },
      { label: 'Travel', text: 'Trips, tickets, and reminders keep their place.', tone: 'blue' }
    ]
  ];
</script>

<div class="inbox-scene" aria-hidden="true">
  <div class="scene-shade"></div>
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
    <span>On-device SMS filtering</span>
  </div>
</div>
