// The seven recorded segments (ids and beat ids from ../beats.json). All read-only: navigation, link clicks, scrolling.
// Visual per beat follows the "visual" field in beats.json. Cue times (b.at(seconds)) line the picture up with the
// narration; a beat is always held at least as long as its narration (see Runtime.beat).

const REAL = 'Real evidence · 6 Oct 2026';
// Pinned to the CI run of the public release commit 33b18a5, not "the newest run": the narration's "1,111" (examples)
// refers to that release, and a later push would otherwise change what this scene shows.
const GH_CI_RUN = 'https://github.com/amitkssolanki/whatsapp-integration/actions/runs/37581433256';

const row = (rt, text) => rt.page.locator('tbody tr', { hasText: text }).first();
const viewLink = (rt, text) => row(rt, text).getByRole('link', { name: /View/ });

const seg01 = {
  async preroll(rt) { await rt.card('01-title.html'); },
  async run(rt) {
    await rt.beat('b01-title', async () => { await rt.see('WhatsApp Commerce V2'); });
    await rt.beat('b02-v1', async () => {
      await rt.card('02-v1-evidence.html');
      await rt.see('status webhooks discarded');
    });
  },
};

const seg02 = {
  async preroll(rt) {
    await rt.card(rt.placeholder ? '03-whatsapp-placeholder.html' : '03-whatsapp.html');
    if (!rt.placeholder) await rt.setLabel('Real WhatsApp captures · cart not sent', 'real');
  },
  async run(rt) {
    const { page } = rt;
    await rt.beat('b03-whatsapp', async () => { await rt.see(rt.placeholder ? 'capture pending' : 'Fresh captures of the live WhatsApp catalog'); });
    await rt.beat('b04-conversation', async (b) => {
      await rt.goto('/admin/conversations');
      await rt.see('Maya Fernandes');
      await rt.pointAt(page.getByRole('row').filter({ hasText: 'Maya Fernandes' }).first().getByRole('link', { name: /View/ }), { highlight: false, ms: 700 });
      await rt.click(viewLink(rt, 'Maya Fernandes'));
      await rt.see('Hi! What');
      await b.at(2.4);
      await rt.pointAt(page.locator('.msg-row', { hasText: "What's on the menu today?" }).first(), { ms: 650 });
      await b.at(4.3);
      await rt.pointAt(page.locator('.msg-row', { hasText: 'Welcome to The Local Table' }).first(), { ms: 650 });
      await b.at(5.7);
      await rt.pointAt(page.locator('.msg-row', { hasText: 'Delivery around 7:30 please' }).first(), { ms: 650 });
    });
  },
};

const seg03 = {
  async preroll(rt) { await rt.goto('/admin/orders'); await rt.see('Maya Fernandes'); },
  async run(rt) {
    const { page } = rt;
    await rt.beat('b05-order', async (b) => {
      await rt.pointAt(row(rt, 'Maya Fernandes'), { fx: 0.9, ms: 700 });
      await b.at(2.7);
      await rt.click(viewLink(rt, 'Maya Fernandes'));
      await rt.see('Catalog price');
      await b.at(3.8);
      await rt.pointAt(page.getByRole('row').filter({ hasText: 'Classic Lasagne' }).first(), { fx: 0.1, ms: 600 });
      await b.at(4.9);
      await rt.pointAt(page.getByRole('columnheader', { name: 'Catalog price' }), { fx: 0.9, ms: 650 });
      await b.at(6.2);
      await rt.pointAt(page.getByText('Total (what the customer saw)'), { fx: 0.8, ms: 600 });
    });
    await rt.beat('b06-notice', async (b) => {
      await rt.pointAt(page.getByText(/Accepted by demo-operator/), { fx: 0.1, ms: 600 });
      await b.at(1.5);
      await rt.scrollTo(page.getByRole('heading', { name: /Customer notifications/ }), { margin: 70, ms: 800 });
      await b.at(3.0);
      const head = page.getByRole('columnheader', { name: 'Queued' });
      await rt.pointAt(head, { fx: 0.1, ms: 600, margin: 70 });
      const r5 = page.getByRole('row').filter({ hasText: 'order accepted' }).first();
      await b.at(5.2);
      await rt.pointAt(r5.getByRole('cell').nth(5), { highlight: r5.getByRole('cell').nth(5), fx: 0.1, ms: 550 }); // Sent
      await b.at(5.9);
      await rt.pointAt(r5.getByRole('cell').nth(6), { fx: 0.1, ms: 450 }); // Delivered
      await b.at(6.5);
      await rt.pointAt(r5.getByRole('cell').nth(7), { fx: 0.1, ms: 450 }); // Read
    });
    await rt.beat('b07-deliveries', async (b) => {
      await rt.goto('/admin/deliveries');
      await rt.see('Webhook deliveries');
      const dup = page.getByRole('row').filter({ hasText: 'duplicate 1' }).first();
      await b.at(0.5);
      await rt.pointAt(dup.getByRole('cell').nth(4), { highlight: dup, fx: 0.1, ms: 650, margin: 150 });
      await b.at(2.3);
      await rt.click(dup.getByRole('link', { name: /View/ }));
      await rt.see('Item results');
      await b.at(3.5);
      await rt.pointAt(page.locator('dd', { hasText: /^duplicate/ }).first(), { fx: 0.1, ms: 500 });
      await b.at(4.3);
      await rt.pointAt(page.locator('td', { hasText: /^duplicate$/ }).first(), { ms: 500 });
    });
  },
};

const seg04 = {
  async preroll(rt) { await rt.goto('/admin/health'); await rt.see('Outbound messages by status'); },
  async run(rt) {
    const { page } = rt;
    await rt.beat('b08-health', async (b) => {
      await b.at(0.3);
      await rt.scrollTo(page.getByRole('heading', { name: 'Outbound messages by status' }), { margin: 60, ms: 900 });
      await b.at(1.4);
      await rt.pointAt(page.getByRole('heading', { name: 'Failed sends by category' }), { fx: 0.2, ms: 650, margin: 60 });
      await b.at(2.6);
      await rt.scrollTo(page.getByRole('heading', { name: /Unknown outcome/ }), { margin: 60, ms: 800 });
      await b.at(3.6);
      await rt.pointAt(page.getByText('never resent automatically'), { fx: 0.1, ms: 650, margin: 60 });
      await b.at(5.2);
      await rt.pointAt(page.getByRole('heading', { name: /Blocked by the 24h window/ }), { fx: 0.2, ms: 650, margin: 60 });
      await b.at(6.4);
      await rt.pointAt(page.getByText('blocked: 24h window').first(), { fx: 0.1, ms: 500, margin: 60 });
    });
  },
};

const seg05 = {
  async preroll(rt) { await rt.card('04-real-verification.html'); await rt.setLabel(REAL, 'real'); },
  async run(rt) {
    await rt.beat('b09-real', async () => { await rt.see('10 real webhook deliveries'); });
    await rt.beat('b10-diagnosis', async () => {
      await rt.card('05-error-131009.html');
      await rt.setLabel(REAL, 'real');
      await rt.see('Check if a catalog is linked');
    });
  },
};

const seg06 = {
  // public page, no credentials: the pinned CI run of the release commit (see GH_CI_RUN)
  async preroll(rt) {
    await rt.goto(GH_CI_RUN, { waitUntil: 'domcontentloaded' });
    await rt.see('Total duration');
    await rt.see('Success'); // the green status in the run summary
  },
  async run(rt) {
    const { page } = rt;
    await rt.beat('b11-quality', async (b) => {
      const status = page.getByText('Success', { exact: true }).first();
      await b.at(0.3);
      await rt.pointAt(status, { fx: 0.3, ms: 800, margin: 200 });
      await b.at(1.7);
      await rt.pointAt(page.getByText('security', { exact: true }).first(), { fx: 0.3, ms: 650, margin: 200 });
      await b.at(2.5);
      await rt.pointAt(page.getByText('test', { exact: true }).first(), { fx: 0.3, ms: 500, margin: 200 });
      await b.at(3.4);
      await rt.card('06-quality.html'); // hard cut: card animations are disabled for the recording
    });
  },
};

const seg07 = {
  async preroll(rt) { await rt.card('07-closing.html'); },
  async run(rt) { await rt.beat('b12-close', async () => { await rt.see('github.com/amitkssolanki/whatsapp-integration'); }); },
};

export const SEGMENTS = {
  '01-opening': seg01, '02-journey': seg02, '03-lifecycle': seg03, '04-health': seg04,
  '05-real': seg05, '06-quality': seg06, '07-closing': seg07,
};
