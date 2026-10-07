// Renders every card to out/cards/<name>.png (2x) for review, each WhatsApp shot separately (<name>-shot<n>.png), and
// the Upwork 4:3 cover (out/upwork/cover-4x3.png, 2000x1500). Usage: node render-cards.mjs
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { chromium } from 'playwright';
const ROOT = path.dirname(fileURLToPath(import.meta.url));
const out = path.join(ROOT, 'out', 'cards');
fs.mkdirSync(out, { recursive: true });
fs.mkdirSync(path.join(ROOT, 'out', 'upwork'), { recursive: true });
const browser = await chromium.launch({ headless: true, args: ['--hide-scrollbars', '--force-color-profile=srgb'] });
let bad = 0;
for (const f of fs.readdirSync(path.join(ROOT, 'cards')).filter((n) => n.endsWith('.html')).sort()) {
  const cover = f === 'upwork-cover.html';
  const ctx = await browser.newContext({ viewport: cover ? { width: 1000, height: 750 } : { width: 1440, height: 810 }, deviceScaleFactor: 2, colorScheme: 'light' });
  const page = await ctx.newPage();
  await page.goto('file://' + path.join(ROOT, 'cards', f));
  await page.evaluate(() => document.fonts.ready);
  await page.waitForFunction(() => !window.cropsReady || window.cropsReady(), null, { timeout: 8000 });
  await page.waitForTimeout(800); // fade-in
  const overflow = await page.evaluate(() => document.documentElement.scrollHeight > innerHeight + 1 || document.body.scrollHeight > innerHeight + 1);
  const shots = await page.evaluate(() => document.querySelectorAll('.shot').length);
  if (shots) {
    for (let n = 1; n <= shots; n++) {
      await page.evaluate((k) => window.show(k), n);
      await page.waitForTimeout(400);
      await page.screenshot({ path: path.join(out, f.replace('.html', `-shot${n}.png`)) });
    }
  } else {
    await page.screenshot({ path: cover ? path.join(ROOT, 'out', 'upwork', 'cover-4x3.png') : path.join(out, f.replace('.html', '.png')) });
  }
  if (overflow) bad++;
  console.log(f, overflow ? 'OVERFLOW' : 'ok');
  await ctx.close();
}
await browser.close();
process.exitCode = bad ? 1 : 0;
