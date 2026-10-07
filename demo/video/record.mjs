#!/usr/bin/env node
// Unattended recording of one segment of the WhatsApp Commerce V2 portfolio video.
//
//   node record.mjs --segment 03-lifecycle [--base-url http://localhost:3021] [--out out/scenes]
//        [--durations narration/kokoro-af_heart-speed0.95/durations.json] [--pad 0.4] [--placeholder-whatsapp] [--keep-frames]
//
// Everything here is read-only: any non-GET request is aborted, and only these origins are reachable:
//   - the local app (default http://localhost:3021, admin auth disabled, synthetic database),
//   - file:// cards from ./cards,
//   - github.com (+ its asset hosts) for the public Actions page, opened without credentials.
// Any other host is blocked. No credentials are typed or passed anywhere; no Meta/WhatsApp/Facebook host is reachable.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { chromium } from 'playwright';
import { CdpCapture, probeDuration } from './capture.mjs';
import { SEGMENTS } from './segments.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
export const ROOT = HERE;

// 1152x648 CSS px at DSF 2.5 = 2880x1620 frames. Admin text then reads 1.25x larger than at 1440x810 once scaled to
// 1080p; the 1440x810 cards are shown in this viewport at zoom 0.8 (same layout, same pixels).
export const VIEWPORT = { width: 1152, height: 648 };
export const DSF = 2.5;
const ARCH_IMAGE = path.resolve(ROOT, '../../docs/portfolio/architecture.png');
const ALLOWED_HOSTS = [/^github\.com$/, /(^|\.)githubassets\.com$/, /(^|\.)githubusercontent\.com$/];

const log = (...a) => console.log(a.join(' '));
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const ease = (t) => (t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2);

function parseArgs(argv) {
  const o = { out: 'out/scenes', placeholder: false, baseUrl: 'http://localhost:3021', pad: 0.4, keepFrames: false, durations: 'narration/kokoro-af_heart-speed0.95/durations.json' };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i]; const v = () => argv[++i];
    if (a === '--segment') o.segment = v();
    else if (a === '--base-url') o.baseUrl = v().replace(/\/$/, '');
    else if (a === '--out') o.out = v();
    else if (a === '--durations') o.durations = v();
    else if (a === '--pad') o.pad = parseFloat(v());
    else if (a === '--keep-frames') o.keepFrames = true;
    else if (a === '--placeholder-whatsapp') o.placeholder = true;
    else throw new Error(`unknown argument ${a}`);
  }
  if (!o.segment || !SEGMENTS[o.segment]) throw new Error(`--segment must be one of ${Object.keys(SEGMENTS).join(', ')}`);
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
  // frame when a card follows another page), and the admin footer's "Signed in as <operator>" is hidden because the
  // local operator name differs from the seeded "Accepted by demo-operator".
  style.textContent = (isFile ? 'html{zoom:0.8} body{animation:none !important}' : '') + (isLocal ? 'body.admin{padding-bottom:64px !important} .admin-footer{display:none !important}' : '');
  const addStyle = () => { if (document.head && !style.isConnected) document.head.appendChild(style); };
  addStyle();
  document.addEventListener('DOMContentLoaded', addStyle);

  // persistent corner label (a caption bar along the bottom edge)
  window.__recSetLabel = (text, tone) => {
    let el = document.getElementById('__rec_label');
    if (!text) { if (el) el.remove(); return; }
    if (!el) { if (!document.documentElement) return; el = document.createElement('div'); el.id = '__rec_label'; el.setAttribute('aria-hidden', 'true'); document.documentElement.appendChild(el); }
    const dot = tone === 'real' ? '#1f8a4c' : '#d9a21b';
    el.style.cssText = ['position:fixed', 'left:0', 'right:0', 'bottom:0', 'height:34px', 'display:flex', 'align-items:center', 'justify-content:center', 'gap:10px',
      'background:rgba(34,34,31,0.94)', 'color:#fff', 'font:600 15px -apple-system,BlinkMacSystemFont,Helvetica,Arial,sans-serif', 'letter-spacing:.01em',
      'z-index:2147483646', 'pointer-events:none', isFile ? 'zoom:1.25' : ''].join(';');
    el.textContent = '';
    const d = document.createElement('span');
    d.style.cssText = `width:10px;height:10px;border-radius:50%;background:${dot};display:inline-block`;
    el.appendChild(d); el.appendChild(document.createTextNode(text));
  };
  const autoLabel = () => { if (isLocal) window.__recSetLabel('Synthetic demo data · same code · Meta replaced by an in-process fake', 'synthetic'); };
  autoLabel();
  new MutationObserver(() => { if (isLocal && !document.getElementById('__rec_label') && document.documentElement) autoLabel(); }).observe(document, { childList: true, subtree: false });
  document.addEventListener('DOMContentLoaded', autoLabel);

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
  constructor({ page, capture, segment, narration, base, pad, placeholder }) {
    Object.assign(this, { page, capture, segment, narration, base, pad, placeholder });
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
    const b = { t0: startNode, narr, at: async (s) => { await this.hold(startNode + s - this.now()); } };
    await fn(b);
    const minEnd = startNode + narr + this.pad;
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
  async setLabel(text, tone) { await this.page.evaluate(([t, k]) => window.__recSetLabel(t, k), [text, tone]); }

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
    const ok = await loc.evaluate((el) => { const r = el.getBoundingClientRect(); return r.top >= 40 && r.bottom <= innerHeight - 56; });
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
  const plan = JSON.parse(fs.readFileSync(path.join(ROOT, 'beats.json'), 'utf8'));
  const segment = plan.segments.find((s) => s.id === opts.segment);
  const def = SEGMENTS[opts.segment];
  const durations = JSON.parse(fs.readFileSync(path.resolve(ROOT, opts.durations), 'utf8'));
  const narration = (id) => (typeof durations[id] === 'number' ? durations[id] : null);
  const outDir = path.resolve(ROOT, opts.out);
  fs.mkdirSync(outDir, { recursive: true });
  const outFile = path.join(outDir, `${opts.segment}.mp4`);
  const beatsFile = path.join(outDir, `${opts.segment}.beats.json`);
  const localOrigin = new URL(opts.baseUrl).origin;
  log(`segment ${segment.id} (local app ${localOrigin}, pad ${opts.pad}s)`);

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
    if (u.protocol === 'file:') return (u.pathname.startsWith(ROOT + '/') || u.pathname === ARCH_IMAGE) ? route.continue() : route.abort();
    const allowed = u.origin === localOrigin || ALLOWED_HOSTS.some((r) => r.test(u.hostname));
    if (!allowed) { blocked.add(u.hostname); return route.abort(); }
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
  const rt = new Runtime({ page, capture, segment, narration, base: opts.baseUrl, pad: opts.pad, placeholder: opts.placeholder });
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
    segment: segment.id, video: path.basename(outFile), video_duration: +duration.toFixed(3),
    spec: '1920x1080 H.264 30fps cfr yuv420p crf18 no audio', viewport: `${VIEWPORT.width}x${VIEWPORT.height}@${DSF}x`,
    pad_seconds: opts.pad, blocked_hosts: [...blocked], placeholder_whatsapp: opts.placeholder, capture_stats: capture.stats ?? null, warnings: rt.warnings, beats: rt.beats,
  }, null, 2) + '\n');
  log(`wrote ${path.relative(ROOT, outFile)} (${duration.toFixed(2)}s)`);
  if (rt.warnings.length) log(`warnings: ${[...new Set(rt.warnings)].join('; ')}`);
  if (blocked.size) log(`blocked hosts: ${[...blocked].join(', ')}`);
  if (!opts.keepFrames) capture.cleanup();
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((e) => { console.error(e.stack || e.message); process.exit(1); });
}
