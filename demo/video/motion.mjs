#!/usr/bin/env node
// Renders the real WhatsApp segment of one cut from the author's phone screen recordings, following
// whatsapp-motion.json. No browser recording and no phone involved: ffmpeg crops each clip of a recording (real speed,
// nothing edited inside a frame), scales it with Lanczos into the panel of a background card (rendered once per step by
// Playwright from cards/03-whatsapp-motion.html), and writes <segment>.mp4 + <segment>.beats.json in the same form as
// record.mjs, so assemble.rb treats it like any other segment.
//
//   node motion.mjs --cut portfolio --segment 02-whatsapp [--out out/portfolio/scenes]
//        [--durations narration/portfolio/kokoro-af_heart-speed0.95/durations.json] [--pad 0.4]
//
// Exit code 3: an approved recording is missing or is not the one the edit list was made for.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { chromium } from 'playwright';
import { FFMPEG, probeDuration } from './capture.mjs';
import { CUTS } from './segments.mjs';

const ROOT = path.dirname(fileURLToPath(import.meta.url));
const FPS = 30;
const SRC_W = 1260;

function args(argv) {
  const o = { cut: 'portfolio', pad: 0.4 };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i]; const v = () => argv[++i];
    if (a === '--cut') o.cut = v(); else if (a === '--segment') o.segment = v(); else if (a === '--out') o.out = v();
    else if (a === '--durations') o.durations = v(); else if (a === '--pad') o.pad = parseFloat(v());
    else throw new Error(`unknown argument ${a}`);
  }
  if (!CUTS[o.cut]) throw new Error(`--cut must be one of ${Object.keys(CUTS).join(', ')}`);
  o.out ??= `out/${o.cut}/scenes`;
  o.durations ??= `narration/${o.cut}/kokoro-af_heart-speed0.95/durations.json`;
  return o;
}

function ffmpeg(a) {
  const r = spawnSync(FFMPEG, ['-hide_banner', '-loglevel', 'error', '-y', ...a], { encoding: 'utf8' });
  if (r.status !== 0) throw new Error(`ffmpeg failed: ${r.stderr}`);
}

// y(t) for a crop: a number, or [[t, y], ...] keyframes (recording seconds, made relative to the clip start t0), eased
// with smoothstep between keyframes
function yExpr(y, t0) {
  if (typeof y === 'number') return String(Math.round(y));
  const k = y.map(([t, v]) => [+(t - t0).toFixed(3), Math.round(v)]);
  let e = String(k[k.length - 1][1]);
  for (let i = k.length - 2; i >= 0; i--) {
    const [ta, ya] = k[i], [tb, yb] = k[i + 1];
    const u = `min(max((t-${ta})/${(tb - ta).toFixed(3)},0),1)`;
    e = `if(lt(t,${tb}),${ya}+(${yb - ya})*(${u})*(${u})*(3-2*(${u})),${e})`;
  }
  return `if(lt(t,${k[0][0]}),${k[0][1]},${e})`;
}

const X264 = ['-c:v', 'libx264', '-preset', 'slow', '-crf', '10', '-pix_fmt', 'yuv420p', '-r', String(FPS),
  '-colorspace', 'bt709', '-color_primaries', 'bt709', '-color_trc', 'bt709', '-color_range', 'tv', '-movflags', '+faststart', '-an'];
const TO_YUV = 'scale=out_color_matrix=bt709:out_range=tv,format=yuv420p';

async function main() {
  const o = args(process.argv.slice(2));
  const plan = JSON.parse(fs.readFileSync(path.join(ROOT, CUTS[o.cut].beats), 'utf8'));
  const segment = plan.segments.find((s) => s.id === o.segment);
  if (!segment || segment.where !== 'android') throw new Error(`${o.segment} is not an android segment of ${o.cut}`);
  const edl = JSON.parse(fs.readFileSync(path.join(ROOT, 'whatsapp-motion.json'), 'utf8'));
  const cutEdl = edl.cuts[o.cut];
  const durations = JSON.parse(fs.readFileSync(path.resolve(ROOT, o.durations), 'utf8'));

  // The approved recordings, each checked against the checksum its cut points were made for.
  const sources = {};
  for (const [name, def] of Object.entries(edl.sources)) {
    const file = path.join(ROOT, def.file);
    if (!fs.existsSync(file)) { console.error(`MISSING: ${def.file} (record it with bin/demo capture-whatsapp)`); process.exit(3); }
    const sha = crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
    if (sha !== def.sha256) {
      console.error(`${def.file} is not the recording whatsapp-motion.json was cut for (sha256 ${sha.slice(0, 12)}…, expected ${def.sha256.slice(0, 12)}…).\nSet new cut points (and sha256) for the new recording.`);
      process.exit(3);
    }
    sources[name] = file;
  }

  const outDir = path.resolve(ROOT, o.out);
  const work = path.join(outDir, `.${o.segment}`);
  fs.rmSync(work, { recursive: true, force: true });
  fs.mkdirSync(work, { recursive: true });
  const P = edl.panel;
  if (Math.round(P.rows * P.width / SRC_W) !== P.height) throw new Error('panel rows/height do not match its scale');

  // 1. Backgrounds, one per step, rendered at exactly 1920x1080.
  const browser = await chromium.launch({ headless: true, args: ['--hide-scrollbars', '--force-color-profile=srgb'] });
  const page = await browser.newPage({ viewport: { width: 1440, height: 810 }, deviceScaleFactor: 4 / 3 });
  const bgs = [];
  for (let i = 0; i < edl.steps.length; i++) {
    const file = path.join(work, `bg-step${i}.png`);
    const q = new URLSearchParams({ steps: edl.steps.join('|'), step: i, sub: `${edl.recorded} · Captured on author’s phone`, note: edl.note });
    await page.goto('file://' + path.join(ROOT, 'cards', '03-whatsapp-motion.html') + '?' + q);
    await page.evaluate(() => document.fonts.ready);
    await page.addStyleTag({ content: 'body{animation:none !important}' });
    await page.screenshot({ path: file });
    bgs.push(file);
  }
  await browser.close();

  // 2. Rounded-corner mask for the panel (antialiased edge).
  const mask = path.join(work, 'mask.png');
  const r = P.radius;
  ffmpeg(['-f', 'lavfi', '-i', `color=black:s=${P.width}x${P.height}`, '-frames:v', '1', '-vf',
    `format=gray,geq=lum='255*clip(${r}+0.5-hypot(max(0,abs(X+0.5-W/2)-(W/2-${r})),max(0,abs(Y+0.5-H/2)-(H/2-${r}))),0,1)'`, mask]);

  // 3. One clip per recording piece, composited onto the background of its step.
  const clipFiles = [];
  const beatsOut = [];
  let clock = 0;
  for (const def of segment.beats) {
    const spec = cutEdl[def.id];
    if (!spec?.clips) throw new Error(`whatsapp-motion.json has no clips for ${o.cut}.${def.id}`);
    const narr = durations[def.id];
    if (typeof narr !== 'number') throw new Error(`no narration duration for ${def.id}`);
    const parts = [];
    for (const c of spec.clips) {
      const src = sources[c.src];
      if (!src) throw new Error(`${def.id}: unknown source ${c.src}`);
      const f = path.join(work, `clip${clipFiles.length + parts.length}.mp4`);
      const dur = +(c.to - c.from).toFixed(3);
      ffmpeg(['-ss', String(c.from), '-t', String(dur), '-i', src, '-loop', '1', '-t', String(dur), '-i', bgs[c.step], '-i', mask,
        '-filter_complex',
        `[0:v]setpts=PTS-STARTPTS,fps=${FPS},crop=${SRC_W}:${P.rows}:0:'${yExpr(c.y, c.from)}',` +
        `scale=${P.width}:${P.height}:flags=lanczos+accurate_rnd+full_chroma_int:in_color_matrix=${edl.source_color_matrix}:in_range=tv,format=rgba[ph];` +
        `[2:v]format=gray[m];[ph][m]alphamerge[pm];[1:v]format=rgba[bg];[bg][pm]overlay=${P.x}:${P.y}:shortest=1,${TO_YUV}[v]`,
        '-map', '[v]', '-t', String(dur), ...X264, f]);
      parts.push({ file: f, seconds: dur });
    }

    // the beat lasts as long as its pictures, its narration + pad, or min_seconds, whichever is longest:
    // the last frame is held if the narration needs longer than the pictures
    const pictures = parts.reduce((s, p) => s + p.seconds, 0);
    const length = Math.max(pictures, narr + o.pad, def.min_seconds ?? 0);
    if (length > pictures + 0.01) {
      const last = parts[parts.length - 1];
      const held = last.file.replace('.mp4', '-held.mp4');
      const extra = +(length - pictures).toFixed(3);
      ffmpeg(['-i', last.file, '-vf', `tpad=stop_mode=clone:stop_duration=${extra}`, ...X264, held]);
      last.file = held; last.seconds += extra;
    }
    clipFiles.push(...parts.map((p) => p.file));
    beatsOut.push({ id: def.id, start: +clock.toFixed(3), end: +(clock + length).toFixed(3), narration_seconds: narr, pictures_seconds: +pictures.toFixed(3) });
    clock += length;
    console.log(`beat ${def.id}: ${pictures.toFixed(2)} s of pictures, narration ${narr.toFixed(2)} s -> ${length.toFixed(2)} s`);
  }

  // 4. Join (re-encoded once so timestamps are continuous).
  const list = path.join(work, 'list.txt');
  fs.writeFileSync(list, clipFiles.map((f) => `file '${f}'`).join('\n') + '\n');
  const outFile = path.join(outDir, `${o.segment}.mp4`);
  ffmpeg(['-f', 'concat', '-safe', '0', '-i', list, ...X264, outFile]);
  const duration = probeDuration(outFile);
  fs.writeFileSync(path.join(outDir, `${o.segment}.beats.json`), JSON.stringify({
    cut: o.cut, segment: o.segment, video: path.basename(outFile), video_duration: +duration.toFixed(3),
    spec: '1920x1080 H.264 30fps cfr yuv420p crf10 no audio', sources: edl.sources, pad_seconds: o.pad, beats: beatsOut,
  }, null, 2) + '\n');
  fs.rmSync(work, { recursive: true, force: true });
  console.log(`wrote ${path.relative(ROOT, outFile)} (${duration.toFixed(2)}s)`);
}

main().catch((e) => { console.error(e.stack || e.message); process.exit(1); });
