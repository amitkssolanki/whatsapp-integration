#!/usr/bin/env node
// Unattended recording of one segment of one cut (portfolio or upwork) of the WhatsApp Commerce V2 video.
//
//   node record.mjs --cut portfolio --segment 02-demo [--base-url http://localhost:3021] [--out out/portfolio/scenes]
//        [--durations narration/portfolio/kokoro-af_heart-speed0.95/durations.json] [--pad 0.4] [--keep-frames]
//
// Everything here is read-only: any non-GET request is aborted, and only two origins are reachable: the local app
// (default http://localhost:3021, admin auth disabled, synthetic database) and file:// cards/assets under this directory.
// Any other host is blocked. No credentials are typed or passed anywhere; no Meta/WhatsApp/Facebook host is reachable.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { chromium } from 'playwright';
import { CdpCapture, probeDuration } from './capture.mjs';
import { CUTS } from './segments.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
export const ROOT = HERE;

// 1152x648 CSS px at DSF 2.5 = 2880x1620 frames. Admin text then reads 1.25x larger than at 1440x810 once scaled to
// 1080p; the 1440x810 cards are shown in this viewport at zoom 0.8 (same layout, same pixels).
export const VIEWPORT = { width: 1152, height: 648 };
export const DSF = 2.5;
// Each beat's narration starts this long after the beat starts on screen (assemble.rb uses the same value).
const LEAD = 0.25;

const log = (...a) => console.log(a.join(' '));
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const ease = (t) => (t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2);

function parseArgs(argv) {
  const o = { cut: 'portfolio', baseUrl: 'http://localhost:3021', pad: 0.4, keepFrames: false };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i]; const v = () => argv[++i];
    if (a === '--cut') o.cut = v();
    else if (a === '--segment') o.segment = v();
    else if (a === '--base-url') o.baseUrl = v().replace(/\/$/, '');
    else if (a === '--out') o.out = v();
    else if (a === '--durations') o.durations = v();
    else if (a === '--pad') o.pad = parseFloat(v());
    else if (a === '--keep-frames') o.keepFrames = true;
    else throw new Error(`unknown argument ${a}`);
  }
  if (!CUTS[o.cut]) throw new Error(`--cut must be one of ${Object.keys(CUTS).join(', ')}`);
  const segs = CUTS[o.cut].segments;
  if (!o.segment || !segs[o.segment]) throw new Error(`--segment must be one of ${Object.keys(segs).join(', ')}`);
  o.out ??= `out/${o.cut}/scenes`;
  o.durations ??= `narration/${o.cut}/kokoro-af_heart-speed0.95/durations.json`;
  const u = new URL(o.baseUrl);
  if (!['localhost', '127.0.0.1'].includes(u.hostname)) throw new Error('--base-url must be a localhost address');
  return o;
}

// ---------------------------------------------------------------------------------------------------------------
// Injected into every page (recording only; the app is never edited).
const PAGE_INIT = ({ localOrigin }) => {
  const isFile = location.protocol === 'file:';
  const isLocal = location.origin === localOrigin;
  // cards are authored at 1440x810; the recording viewport is 1152x648
  const style = document.createElement('style');
  // Presentation only: cards appear with a hard cut (their CSS fade-in starts from off-white, which reads as a washed-out
  // frame when a card follows another page); on the local app, extra bottom padding lets any section scroll to the top,
  // the admin footer's "Signed in as <operator>" is hidden
  // (the local operator name differs from the seeded "Accepted by demo-operator"), and so are the per-record "synthetic"
  // badges: the demo section opens with an "Application demo · synthetic data" card and every local frame carries the
  // DEMO DATA tag below instead.
  style.textContent = (isFile ? 'html{zoom:0.8} body{animation:none !important}' : '') +
    (isLocal ? 'body.admin{padding-bottom:50vh !important} .admin-footer{display:none !important} .badge-synthetic{display:none !important}' : '');
  const addStyle = () => { if (document.head && !style.isConnected) document.head.appendChild(style); };
  addStyle();
  document.addEventListener('DOMContentLoaded', addStyle);

  // A small, fixed DEMO DATA tag in the bottom-right corner of every local (synthetic) page.
  const tag = () => {
    if (!isLocal || document.getElementById('__rec_demo') || !document.documentElement) return;
    const el = document.createElement('div');
    el.id = '__rec_demo'; el.setAttribute('aria-hidden', 'true'); el.textContent = 'DEMO DATA';
    el.style.cssText = ['position:fixed', 'right:14px', 'bottom:12px', 'padding:4px 10px 4px 22px', 'border-radius:999px', 'background:rgba(34,34,31,0.82)',
      'color:#fff', 'font:700 11px -apple-system,BlinkMacSystemFont,Helvetica,Arial,sans-serif', 'letter-spacing:.08em', 'z-index:2147483646',
      'pointer-events:none', 'background-image:radial-gradient(circle at 11px 50%, #e0a91f 0 4px, transparent 4.5px)'].join(';');
    document.documentElement.appendChild(el);
  };
  tag();
  new MutationObserver(tag).observe(document, { childList: true, subtree: false });
  document.addEventListener('DOMContentLoaded', tag);

  // cursor dot (not on file:// cards)
  if (isFile) return;
  const ID = '__rec_cursor', KEY = '__rec_cursor_pos';
  const make = () => {
    if (document.getElementById(ID) || !document.documentElement) return;
    const d = document.createElement('div');
    d.id = ID; d.setAttribute('aria-hidden', 'true');
    d.style.cssText = ['position:fixed', 'left:0', 'top:0', 'width:16px', 'height:16px', 'margin:-8px 0 0 -8px', 'border-radius:50%',
      'background:rgba(27,25,22,0.86)', 'box-shadow:0 0 0 2px rgba(255,255,255,0.85),0 2px 8px rgba(0,0,0,0.32)',
      'pointer-events:none', 'z-index:2147483647', 'opacity:0', 'will-change:transform', 'transition:opacity .2s ease, width .12s ease, height .12s ease, margin .12s ease'].join(';');
    document.documentElement.appendChild(d);
    let p = null;
    try { p = JSON.parse(sessionStorage.getItem(KEY) || 'null'); } catch { /* storage unavailable */ }
    if (p) { d.style.transform = `translate(${p.x}px,${p.y}px)`; d.style.opacity = '1'; }
  };
  make();
  new MutationObserver(make).observe(document, { childList: true, subtree: false });
  document.addEventListener('DOMContentLoaded', make);
  window.addEventListener('mousemove', (e) => {
    make();
    const d = document.getElementById(ID); if (!d) return;
    d.style.transform = `translate(${e.clientX}px,${e.clientY}px)`; d.style.opacity = '1';
    try { sessionStorage.setItem(KEY, JSON.stringify({ x: e.clientX, y: e.clientY })); } catch { /* ignore */ }
  }, true);
};

// ---------------------------------------------------------------------------------------------------------------
export class Runtime {
  constructor({ page, capture, segment, narration, base, pad }) {
    Object.assign(this, { page, capture, segment, narration, base, pad });
    this.pos = { x: 900, y: 420 };
    this.beats = [];
    this.warnings = [];
    this.cursorUsed = false;
  }
  now() { return Date.now() / 1000; }
  async hold(seconds) { if (seconds > 0) await sleep(seconds * 1000); }

  // A beat: run `fn(b)`, then keep the picture on screen until narration + pad has elapsed.
  async beat(id, fn) {
    const def = this.segment.beats.find((b) => b.id === id);
    if (!def) throw new Error(`beat ${id} is not in beats.json`);
    const narr = this.narration(id);
    if (narr == null) throw new Error(`no narration duration for ${id}`);
    const startNode = this.now();
    const start = startNode - this.capture.originNode;
    log(`beat ${id}: start ${start.toFixed(2)}s (narration ${narr.toFixed(2)}s)`);
    const at = async (s) => { await this.hold(startNode + s - this.now()); };
    // word(w): when the narration reaches w, estimated from w's position in the beat's text
    const word = async (w, dt = 0) => {
      const i = def.text.indexOf(w);
      if (i < 0) throw new Error(`beat ${id}: "${w}" is not in its narration`);
      await at(LEAD + narr * (i / def.text.length) + dt);
    };
    const b = { t0: startNode, narr, at, word };
    await fn(b);
    const minEnd = startNode + Math.max(narr + this.pad, def.min_seconds ?? 0);
    const wait = minEnd - this.now();
    if (wait > 0) { await this.restCursor(); await this.hold(wait); }
    else this.warnings.push(`${id}: actions ran ${(-wait).toFixed(2)}s past narration+pad`);
    const endNode = this.now();
    const rec = { id, start: +start.toFixed(3), end: +(endNode - this.capture.originNode).toFixed(3), narration_seconds: narr, min_end: +(minEnd - this.capture.originNode).toFixed(3) };
    this.beats.push(rec);
    log(`beat ${id}: end ${rec.end.toFixed(2)}s (${(rec.end - rec.start).toFixed(1)}s)`);
  }

  // ---- page readiness / navigation ----
  async settle() {
    const p = this.page;
    await p.waitForLoadState('load', { timeout: 8000 }).catch(() => {});
    await p.evaluate(() => document.fonts && document.fonts.ready).catch(() => {});
    await p.waitForFunction(() => [...document.images].filter((i) => i.getBoundingClientRect().top < innerHeight).every((i) => i.complete), null, { timeout: 8000 }).catch(() => {});
    await p.evaluate(() => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r))));
  }
  // waitUntil: 'domcontentloaded' for external pages whose load event can hang on slow third-party requests (GitHub)
  async goto(target, { waitUntil = 'load' } = {}) {
    const url = target.startsWith('http') || target.startsWith('file:') ? target : this.base + target;
    const resp = await this.page.goto(url, { waitUntil, timeout: 60000 });
    if (resp && resp.status() >= 400) throw new Error(`${resp.status()} on ${new URL(url).pathname}`);
    await this.settle();
    if (this.cursorUsed) await this.page.mouse.move(this.pos.x, this.pos.y);
  }
  card(name) { return this.goto('file://' + path.join(ROOT, 'cards', name)); }
  // The href of the "View" link in the list row containing `text`, looked up in a separate, unrecorded page.
  async lookupHref(listPath, text) {
    const p = await this.page.context().newPage();
    try {
      await p.goto(this.base + listPath, { waitUntil: 'load' });
      const href = await p.locator('tbody tr', { hasText: text }).first().getByRole('link', { name: /View/ }).getAttribute('href');
      if (!href) throw new Error(`no View link for "${text}" on ${listPath}`);
      return href;
    } finally { await p.close(); }
  }

  // ---- text assertions ----
  async see(text, { scope = this.page, timeout = 15000 } = {}) {
    const loc = scope.getByText(text, { exact: false }).first();
    try { await loc.waitFor({ state: 'attached', timeout }); } catch { throw new Error(`EXPECTED TEXT MISSING: ${text}`); }
    return loc;
  }

  // ---- cursor ----
  async restCursor() {
    await this.page.evaluate(() => { const d = document.getElementById('__rec_cursor'); if (d) d.style.opacity = '0'; }).catch(() => {});
  }
  async glideTo(x, y, ms) {
    const { page } = this;
    this.cursorUsed = true;
    const sx = this.pos.x, sy = this.pos.y, dx = x - sx, dy = y - sy, dist = Math.hypot(dx, dy);
    if (dist < 2) return;
    const dur = ms ?? Math.min(1000, Math.max(450, 380 + dist * 0.5));
    const nx = -dy / dist, ny = dx / dist;
    const bow = Math.min(36, dist * 0.06) * (dx >= 0 ? 1 : -1);
    const t0 = performance.now();
    for (;;) {
      const raw = Math.min(1, (performance.now() - t0) / dur);
      const e = ease(raw), arc = Math.sin(Math.PI * e) * bow;
      const px = sx + dx * e + nx * arc, py = sy + dy * e + ny * arc;
      await page.mouse.move(px, py);
      this.pos = { x: px, y: py };
      if (raw >= 1) break;
      await sleep(8);
    }
    this.pos = { x, y };
    await page.mouse.move(x, y);
  }
  async mark(loc) {
    await this.page.evaluate(() => { const o = document.querySelector('[data-rec-mark]'); if (o) { o.style.boxShadow = ''; o.style.background = ''; o.removeAttribute('data-rec-mark'); } });
    if (!loc) return;
    await loc.evaluate((el) => { el.setAttribute('data-rec-mark', '1'); el.style.boxShadow = '0 0 0 3px rgba(31,138,76,0.55)'; el.style.background = 'rgba(31,138,76,0.07)'; el.style.borderRadius = '4px'; });
  }
  // Glide the cursor to a point in an element (scrolling it into view first) and optionally highlight it.
  async pointAt(loc, { fx = 0.5, fy = 0.5, ms, highlight = null, margin } = {}) {
    await loc.waitFor({ state: 'attached', timeout: 15000 });
    await this.keepInView(loc, margin);
    const b = await loc.boundingBox();
    if (!b) throw new Error('element has no box');
    if (highlight !== false) await this.mark(highlight ?? loc);
    await this.glideTo(b.x + Math.min(b.width * fx, 360), b.y + Math.min(b.height * fy, 20), ms);
  }
  async keepInView(loc, margin) {
    const ok = await loc.evaluate((el) => { const r = el.getBoundingClientRect(); return r.top >= 4 && r.bottom <= innerHeight - 56; });
    if (!ok) await this.scrollTo(loc, { margin: margin ?? Math.round(VIEWPORT.height * 0.25) });
  }
  async scrollTo(loc, { margin = 28, ms } = {}) {
    await loc.waitFor({ state: 'attached' });
    await loc.evaluate(smoothScrollToEl, { margin, ms });
  }
  async scrollBy(dy, { ms = 900 } = {}) { await this.page.evaluate(smoothScrollBy, { dy, ms }); }
  async click(loc) {
    await loc.waitFor({ state: 'visible', timeout: 15000 });
    await this.keepInView(loc);
    const b = await loc.boundingBox();
    await this.glideTo(b.x + b.width / 2, b.y + b.height / 2);
    await this.hold(0.25);
    await loc.click({ delay: 80 });
    await this.page.waitForLoadState('load').catch(() => {});
    await this.settle();
    await this.page.mouse.move(this.pos.x, this.pos.y);
  }
}

function smoothScrollToEl(el, { margin, ms }) {
  const sc = document.scrollingElement;
  const maxTop = sc.scrollHeight - innerHeight;
  const from = sc.scrollTop;
  const target = Math.max(0, Math.min(maxTop, from + el.getBoundingClientRect().top - margin));
  const dist = Math.abs(target - from);
  const dur = ms ?? Math.min(900, Math.max(550, dist / 2.2));
  return new Promise((resolve) => {
    if (dist < 2) return resolve();
    const t0 = performance.now();
    const e = (t) => (t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2);
    const step = (now) => { const t = Math.min(1, (now - t0) / dur); sc.scrollTop = from + (target - from) * e(t); if (t < 1) requestAnimationFrame(step); else resolve(); };
    requestAnimationFrame(step);
  });
}
function smoothScrollBy({ dy, ms }) {
  const sc = document.scrollingElement;
  const maxTop = sc.scrollHeight - innerHeight;
  const from = sc.scrollTop, target = Math.max(0, Math.min(maxTop, from + dy));
  return new Promise((resolve) => {
    if (Math.abs(target - from) < 2) return resolve();
    const t0 = performance.now();
    const e = (t) => (t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2);
    const step = (now) => { const t = Math.min(1, (now - t0) / ms); sc.scrollTop = from + (target - from) * e(t); if (t < 1) requestAnimationFrame(step); else resolve(); };
    requestAnimationFrame(step);
  });
}

// ---------------------------------------------------------------------------------------------------------------
async function main() {
  const opts = parseArgs(process.argv.slice(2));
  const plan = JSON.parse(fs.readFileSync(path.join(ROOT, CUTS[opts.cut].beats), 'utf8'));
  const segment = plan.segments.find((s) => s.id === opts.segment);
  if (!segment) throw new Error(`segment ${opts.segment} is not in ${CUTS[opts.cut].beats}`);
  const def = CUTS[opts.cut].segments[opts.segment];
  const durations = JSON.parse(fs.readFileSync(path.resolve(ROOT, opts.durations), 'utf8'));
  const narration = (id) => (typeof durations[id] === 'number' ? durations[id] : null);
  const outDir = path.resolve(ROOT, opts.out);
  fs.mkdirSync(outDir, { recursive: true });
  const outFile = path.join(outDir, `${opts.segment}.mp4`);
  const beatsFile = path.join(outDir, `${opts.segment}.beats.json`);
  const localOrigin = new URL(opts.baseUrl).origin;
  log(`${opts.cut} segment ${segment.id} (local app ${localOrigin}, pad ${opts.pad}s)`);

  const browser = await chromium.launch({ headless: true, args: ['--hide-scrollbars', '--force-color-profile=srgb', '--disable-lcd-text', '--font-render-hinting=none'] });
  const capture = new CdpCapture({ framesDir: path.join(path.dirname(outDir), '.frames', opts.segment), format: 'jpeg', quality: 100, width: VIEWPORT.width * DSF, height: VIEWPORT.height * DSF });
  const ctx = await browser.newContext({ viewport: VIEWPORT, deviceScaleFactor: DSF, colorScheme: 'light', reducedMotion: 'no-preference', locale: 'en-US' }); // no credentials, no tracing, no HAR
  await ctx.addInitScript(PAGE_INIT, { localOrigin });

  const blocked = new Set();
  let violation = null;
  await ctx.route('**/*', async (route) => {
    const req = route.request();
    const u = new URL(req.url());
    const m = req.method();
    if (u.protocol === 'data:' || u.protocol === 'blob:') return route.continue();
    if (u.protocol === 'file:') return u.pathname.startsWith(ROOT + '/') ? route.continue() : route.abort();
    if (u.origin !== localOrigin) { blocked.add(u.hostname); return route.abort(); }
    if (m !== 'GET' && m !== 'HEAD' && m !== 'OPTIONS') { violation = violation ?? `non-GET ${m} to ${u.hostname}${u.pathname}`; return route.abort(); }
    if (u.origin === localOrigin && req.resourceType() === 'document') {
      // the admin pages refresh themselves every 5 s; a refresh mid-beat would reset the scroll, so drop the tag
      const resp = await route.fetch();
      const body = (await resp.text()).replace(/<meta http-equiv="refresh"[^>]*>/gi, '');
      return route.fulfill({ response: resp, body });
    }
    return route.continue();
  });

  const page = await ctx.newPage();
  const rt = new Runtime({ page, capture, segment, narration, base: opts.baseUrl, pad: opts.pad });
  page.on('pageerror', (e) => rt.warnings.push(`page error: ${e.message.split('\n')[0]}`));
  page.on('response', (r) => { if (r.status() >= 400 && r.request().resourceType() === 'document') rt.warnings.push(`${r.status()} ${new URL(r.url()).host}${new URL(r.url()).pathname}`); });

  let failed = null;
  try {
    await def.preroll?.(rt);
    await capture.start(ctx, page);
    if (capture.firstFrame) await Promise.race([capture.firstFrame, sleep(3000)]);
    await capture.markOrigin(page);
    log('timeline origin set');
    await def.run(rt);
    if (violation) throw new Error(violation);
  } catch (e) {
    failed = e;
    log(`FAILED: ${e.stack || e.message}`);
    try { await page.screenshot({ path: path.join(outDir, `${opts.segment}.failure.png`) }); } catch { /* ignore */ }
  }
  try { await capture.stop(outFile, ctx); } catch (e) { log(`capture finalise failed: ${e.message}`); failed = failed ?? e; }
  await ctx.close().catch(() => {});
  await browser.close().catch(() => {});
  if (failed) { process.exitCode = 1; return; }
  const duration = probeDuration(outFile);
  fs.writeFileSync(beatsFile, JSON.stringify({
    cut: opts.cut, segment: segment.id, video: path.basename(outFile), video_duration: +duration.toFixed(3),
    spec: '1920x1080 H.264 30fps cfr yuv420p crf12 no audio', viewport: `${VIEWPORT.width}x${VIEWPORT.height}@${DSF}x`,
    pad_seconds: opts.pad, blocked_hosts: [...blocked], capture_stats: capture.stats ?? null, warnings: rt.warnings, beats: rt.beats,
  }, null, 2) + '\n');
  log(`wrote ${path.relative(ROOT, outFile)} (${duration.toFixed(2)}s)`);
  if (rt.warnings.length) log(`warnings: ${[...new Set(rt.warnings)].join('; ')}`);
  if (blocked.size) log(`blocked hosts: ${[...blocked].join(', ')}`);
  if (!opts.keepFrames) capture.cleanup();
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((e) => { console.error(e.stack || e.message); process.exit(1); });
}
