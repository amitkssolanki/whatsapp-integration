// Renders every card to out/cards/<name>.png (2x) for review and as a source for the thumbnail.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { chromium } from 'playwright';
const ROOT = path.dirname(fileURLToPath(import.meta.url));
const out = path.join(ROOT, 'out', 'cards');
fs.mkdirSync(out, { recursive: true });
const browser = await chromium.launch({ headless: true, args: ['--hide-scrollbars', '--force-color-profile=srgb'] });
const ctx = await browser.newContext({ viewport: { width: 1440, height: 810 }, deviceScaleFactor: 2, colorScheme: 'light' });
const page = await ctx.newPage();
for (const f of fs.readdirSync(path.join(ROOT, 'cards')).filter((n) => n.endsWith('.html')).sort()) {
  await page.goto('file://' + path.join(ROOT, 'cards', f));
  await page.evaluate(() => document.fonts.ready);
  await page.waitForTimeout(800); // fade-in
  const overflow = await page.evaluate(() => document.documentElement.scrollHeight > innerHeight + 1 || document.body.scrollHeight > innerHeight + 1);
  await page.screenshot({ path: path.join(out, f.replace('.html', '.png')) });
  console.log(f, overflow ? 'OVERFLOW' : 'ok');
}
await browser.close();
