// The recorded segments of both cuts (segment and beat ids from beats.json / beats-upwork.json). All read-only:
// navigation, link clicks, scrolling. Cue times line the picture up with the narration: b.at(seconds) from the start of
// the beat, b.word('…') when the narration reaches that word (estimated from its position in the text). A beat is
// always held at least as long as its narration (see Runtime.beat).

const row = (rt, text) => rt.page.locator('tbody tr', { hasText: text }).first();
const viewLink = (rt, text) => row(rt, text).getByRole('link', { name: /View/ });
const HERO = 'Maya Fernandes';

// ---- shared scenes -------------------------------------------------------------------------------------------------

// The author's real WhatsApp screenshots: three shots, switched as the narration reaches "They browse" and "build a
// cart"; the catalog shot stays up at least SHOT2_MIN seconds.
const SHOT2_MIN = 2.6;
async function whatsappShots(rt, b) {
  await rt.whatsappCard();
  await rt.page.evaluate(() => window.show(1));
  await b.word('They browse', -0.15);
  await rt.page.evaluate(() => window.show(2));
  const shot2 = rt.now();
  await b.word('build a cart', -0.15);
  await rt.hold(shot2 + SHOT2_MIN - rt.now());
  await rt.page.evaluate(() => window.show(3));
}

// The flow card, lit step by step with the narration.
async function flow(rt, b, cues) {
  await rt.card('04-flow.html');
  await rt.page.evaluate(() => window.step(1));
  for (const [word, n] of cues) {
    await b.word(word, -0.05);
    await rt.page.evaluate((k) => window.step(k), n);
  }
}

async function heroConversation(rt, b, { hiAt, cartAt }) {
  const { page } = rt;
  const href = await rt.lookupHref('/admin/conversations', HERO);
  await rt.goto(href);
  await rt.see(HERO);
  await b.word(hiAt, -0.1);
  const inbound = page.locator('.msg-row.inbound');
  await rt.pointAt(inbound.first().locator('.msg-body'), { ms: 600 }); // "Hi"
  await b.word(cartAt, -0.1);
  await rt.pointAt(inbound.filter({ hasText: '· order ·' }).first().locator('.msg-meta'), { fx: 0.15, ms: 600 }); // the cart
}

async function orderLines(rt, b) {
  const { page } = rt;
  await rt.pointAt(page.getByRole('row').filter({ hasText: 'Classic Lasagne' }).first(), { fx: 0.1, ms: 550 });
  await b.at(1.3);
  await rt.pointAt(page.getByRole('columnheader', { name: 'Catalog price' }), { fx: 0.9, ms: 550 });
  await b.at(2.6);
  await rt.pointAt(page.getByText('Total (what the customer saw)'), { fx: 0.8, ms: 500 });
}

async function notificationTicks(rt, b, t0 = 0) {
  const { page } = rt;
  await rt.scrollTo(page.getByRole('heading', { name: /Customer notifications/ }), { margin: 70, ms: 750 });
  const r = page.getByRole('row').filter({ hasText: 'order accepted' }).first();
  await b.word('sent', -0.15 + t0);
  await rt.pointAt(r.getByRole('cell').nth(5), { highlight: r.getByRole('cell').nth(5), fx: 0.1, ms: 450 }); // Sent
  await b.word('delivered', -0.15 + t0);
  await rt.pointAt(r.getByRole('cell').nth(6), { fx: 0.1, ms: 400 }); // Delivered
  await b.word('read.', -0.15 + t0);
  await rt.pointAt(r.getByRole('cell').nth(7), { fx: 0.1, ms: 400 }); // Read
}

// ---- portfolio cut -------------------------------------------------------------------------------------------------

const p01 = {
  async preroll(rt) { await rt.card('01-title.html'); },
  async run(rt) {
    await rt.beat('b01-title', async () => { await rt.see('WhatsApp Commerce V2'); });
    await rt.beat('b02-v1', async () => { await rt.card('02-v1-evidence.html'); await rt.see('status webhooks discarded'); });
    await rt.beat('b03-whatsapp', async (b) => whatsappShots(rt, b));
    await rt.beat('b04-flow', async (b) => flow(rt, b, [['verified', 2], ['processed', 3], ['background', 4], ['every reply', 5]]));
  },
};

const p02 = {
  async preroll(rt) { await rt.card('05-demo-intro.html'); },
  async run(rt) {
    const { page } = rt;
    await rt.beat('b05-demo', async (b) => {
      await rt.see('Application demo');
      await b.word('Maya', -0.6);
      await heroConversation(rt, b, { hiAt: 'says hi', cartAt: 'sends her cart' });
    });
    await rt.beat('b06-order', async (b) => {
      await rt.click(page.locator('.msg-row').getByRole('link', { name: /order #\d+/ }).first());
      await rt.see('Catalog price');
      await orderLines(rt, b);
    });
    await rt.beat('b07-notice', async (b) => {
      await rt.pointAt(page.getByText(/Accepted by demo-operator/), { fx: 0.1, ms: 550 });
      await b.at(1.2);
      await notificationTicks(rt, b);
    });
    await rt.beat('b08-deliveries', async (b) => {
      await rt.goto('/admin/deliveries');
      await rt.see('Webhook deliveries');
      const dup = page.getByRole('row').filter({ hasText: 'duplicate 1' }).first();
      await rt.pointAt(dup.getByRole('cell').nth(4), { highlight: dup, fx: 0.1, ms: 600, margin: 150 });
      await b.word('replayed', -0.4);
      const replays = page.locator('tbody tr td:nth-child(7)').filter({ hasText: /^\s*1\s*$/ }).first(); // the Replays column
      await rt.pointAt(replays, { highlight: replays.locator('xpath=..'), fx: 0.3, ms: 500, margin: 150 });
    });
    await rt.beat('b09-health', async (b) => {
      await rt.goto('/admin/health');
      await rt.see('Outbound messages by status');
      await rt.scrollTo(page.getByRole('heading', { name: 'Webhook deliveries' }), { margin: 12, ms: 800 }); // the health cards, from the top
      await b.word('Failures', 0.6);
      await rt.pointAt(page.getByRole('heading', { name: 'Failed sends by category' }), { fx: 0.2, ms: 550, margin: 12 });
      await b.word('ambiguous', -0.1);
      await rt.pointAt(page.getByText('never resent automatically'), { fx: 0.1, ms: 550, margin: 12 });
    });
  },
};

const p03 = {
  async preroll(rt) { await rt.card('06-real-verification.html'); },
  async run(rt) {
    await rt.beat('b10-real', async () => { await rt.see('10 real webhook deliveries'); });
    await rt.beat('b11-diagnosis', async () => { await rt.card('07-error-131009.html'); await rt.see('commerce configuration issue'); });
    await rt.beat('b12-engineering', async () => { await rt.card('08-engineering.html'); await rt.see('1,112 tests'); });
    await rt.beat('b13-close', async () => { await rt.card('09-closing.html'); await rt.see('Long-term production reliability not demonstrated'); });
  },
};

// ---- Upwork cut ----------------------------------------------------------------------------------------------------

const u1 = {
  async preroll(rt) { await rt.card('u01-title.html'); },
  async run(rt) {
    await rt.beat('u01-title', async () => { await rt.see('Order inside WhatsApp'); });
    await rt.beat('u02-whatsapp', async (b) => whatsappShots(rt, b));
    await rt.beat('u03-flow', async (b) => flow(rt, b, [['verified', 2], ['processed', 3], ['Orders', 4], ['every reply', 5]]));
  },
};

const u2 = {
  async preroll(rt) { await rt.card('05-demo-intro.html'); },
  async run(rt) {
    const { page } = rt;
    await rt.beat('u04-dashboard', async (b) => {
      await rt.see('Application demo');
      const href = await rt.lookupHref('/admin/orders', HERO);
      await b.word('dashboard', 0.1);
      await rt.goto(href);
      await rt.see('Catalog price');
      await rt.pointAt(page.getByRole('row').filter({ hasText: 'Classic Lasagne' }).first(), { fx: 0.1, ms: 500 });
      await b.word('each reply', -0.3);
      await rt.scrollTo(page.getByRole('heading', { name: /Customer notifications/ }), { margin: 70, ms: 700 });
      const r = page.getByRole('row').filter({ hasText: 'order accepted' }).first();
      await rt.pointAt(r.getByRole('cell').nth(7), { highlight: r, fx: 0.1, ms: 500 });
      await b.word('anything', -0.3);
      await rt.goto('/admin/health');
      await rt.see('Outbound messages by status');
      await rt.scrollTo(page.getByRole('heading', { name: 'Webhook deliveries' }), { margin: 12, ms: 700 }); // the health cards, from the top
      await rt.pointAt(page.getByRole('heading', { name: 'Failed sends by category' }), { fx: 0.2, ms: 500, margin: 12 });
    });
  },
};

const u3 = {
  async preroll(rt) { await rt.card('u05-verified.html'); },
  async run(rt) {
    await rt.beat('u05-verified', async () => { await rt.see('Verified and deployed'); });
    await rt.beat('u06-close', async () => { await rt.card('u06-closing.html'); await rt.see('built to be operated'); });
  },
};

export const CUTS = {
  portfolio: { beats: 'beats.json', segments: { '01-opening': p01, '02-demo': p02, '03-evidence': p03 } },
  upwork: { beats: 'beats-upwork.json', segments: { 'u1-story': u1, 'u2-dashboard': u2, 'u3-close': u3 } },
};
