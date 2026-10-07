// out/contact-sheet.png: one frame per beat, labelled with the beat id and its time. Usage: node contact-sheet.mjs --out out
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import { chromium } from 'playwright';
import { FFMPEG } from './capture.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const i = process.argv.indexOf('--out');
const out = path.resolve(i > 0 ? process.argv[i + 1] : path.join(HERE, 'out'));
const tl = JSON.parse(fs.readFileSync(path.join(out, 'timeline.json'), 'utf8'));
const video = path.join(out, tl.video);
const dir = path.join(out, '.sheet');
fs.rmSync(dir, { recursive: true, force: true });
fs.mkdirSync(dir, { recursive: true });
const mmss = (t) => `${Math.floor(t / 60)}:${(t % 60).toFixed(1).padStart(4, '0')}`;
const cells = tl.beats.map((b, n) => {
  const at = b.start + Math.min((b.end - b.start) * 0.72, 6);
  const file = path.join(dir, `${String(n).padStart(2, '0')}.jpg`);
  const r = spawnSync(FFMPEG, ['-y', '-v', 'error', '-ss', at.toFixed(3), '-i', video, '-frames:v', '1', '-vf', 'scale=640:360', '-q:v', '3', file]);
  if (r.status !== 0) throw new Error('ffmpeg failed: ' + r.stderr);
  return `<figure><img src="file://${file}"><figcaption><b>${b.id}</b> &nbsp;${mmss(at)} &middot; ${b.visual}</figcaption></figure>`;
});
const html = `<!doctype html><meta charset="utf-8"><style>
body{margin:0;padding:14px;background:#22221f;font:15px -apple-system,Helvetica,Arial,sans-serif;width:2620px}
.g{display:grid;grid-template-columns:repeat(4,640px);gap:14px}
figure{margin:0;background:#fff;border-radius:6px;overflow:hidden} img{display:block;width:640px;height:360px}
figcaption{padding:7px 10px;color:#22221f;height:40px;overflow:hidden;white-space:nowrap;text-overflow:ellipsis}</style>
<div class="g">${cells.join('')}</div>`;
const htmlFile = path.join(dir, 'sheet.html');
fs.writeFileSync(htmlFile, html);
const browser = await chromium.launch({ headless: true });
const page = await browser.newPage({ viewport: { width: 2620, height: 400 }, deviceScaleFactor: 1 });
await page.goto('file://' + htmlFile);
await page.waitForFunction(() => [...document.images].every((im) => im.complete));
await page.screenshot({ path: path.join(out, 'contact-sheet.png'), fullPage: true });
await browser.close();
fs.rmSync(dir, { recursive: true, force: true });
