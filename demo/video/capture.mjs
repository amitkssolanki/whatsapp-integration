// Two ways to turn a browser page into a video, behind one small interface:
//
//   cdp         Page.startScreencast: jpeg/png frames at device resolution (2880x1620 for a 1152x648 viewport at
//               DSF 2.5) with their own timestamps, assembled by ffmpeg into constant-frame-rate H.264 using the real frame
//               timings.
//   playwright  Playwright's built-in recordVideo (VP8 webm at CSS-pixel size), converted to the same H.264 spec.
//
// Both end as H.264, 1920x1080, 30 fps constant, yuv420p, CRF 18, no audio. See README for the comparison evidence.
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

// ffmpeg/ffprobe: an explicit env override, else the first one on PATH, else Homebrew's default location.
export function resolveBin(name, envVar) {
  if (process.env[envVar]) return process.env[envVar];
  for (const dir of (process.env.PATH || '').split(path.delimiter)) {
    const p = path.join(dir, name);
    try { fs.accessSync(p, fs.constants.X_OK); return p; } catch { /* keep looking */ }
  }
  const brew = `/opt/homebrew/bin/${name}`;
  return fs.existsSync(brew) ? brew : name;
}
export const FFMPEG = resolveBin('ffmpeg', 'FFMPEG');
export const FFPROBE = resolveBin('ffprobe', 'FFPROBE');

const X264 = [
  '-c:v', 'libx264', '-preset', 'slow', '-crf', '18', '-pix_fmt', 'yuv420p', '-r', '30', '-fps_mode', 'cfr',
  '-g', '60', '-colorspace', 'bt709', '-color_primaries', 'bt709', '-color_trc', 'bt709', '-color_range', 'tv',
  '-movflags', '+faststart', '-an',
];
// jpeg frames are full-range; scale with an explicit full -> limited conversion in BT.709, Lanczos downscale.
const SCALE = 'scale=1920:1080:flags=lanczos+accurate_rnd+full_chroma_int:in_range=full:out_range=limited:out_color_matrix=bt709';
const SCALE_LIMITED = 'scale=1920:1080:flags=lanczos+accurate_rnd+full_chroma_int:out_range=limited:out_color_matrix=bt709';

function ffmpeg(args) {
  const r = spawnSync(FFMPEG, ['-hide_banner', '-loglevel', 'error', '-y', ...args], { encoding: 'utf8' });
  if (r.status !== 0) throw new Error(`ffmpeg failed: ${r.stderr}`);
}

export function probeDuration(file) {
  const r = spawnSync(FFPROBE, ['-v', 'error', '-show_entries', 'format=duration', '-of', 'csv=p=0', file], { encoding: 'utf8' });
  return parseFloat(r.stdout);
}

// ---------------------------------------------------------------------------------------------------------------
export class CdpCapture {
  constructor({ framesDir, format = 'jpeg', quality = 100, width, height }) {
    this.framesDir = framesDir;
    this.format = format;
    this.quality = quality;
    this.width = width;
    this.height = height;
    this.frames = []; // { ts, received, file }
    this.originNode = null;
    this.firstFrame = null;
    this.ext = format === 'png' ? 'png' : 'jpg';
  }

  async start(ctx, page) {
    fs.rmSync(this.framesDir, { recursive: true, force: true });
    fs.mkdirSync(this.framesDir, { recursive: true });
    this.cdp = await ctx.newCDPSession(page);
    let n = 0;
    let resolveFirst;
    this.firstFrame = new Promise((r) => { resolveFirst = r; });
    this.cdp.on('Page.screencastFrame', (ev) => {
      const received = Date.now() / 1000;
      const file = path.join(this.framesDir, `f${String(n++).padStart(6, '0')}.${this.ext}`);
      fs.writeFileSync(file, Buffer.from(ev.data, 'base64'));
      this.frames.push({ ts: ev.metadata.timestamp, received, file });
      this.cdp.send('Page.screencastFrameAck', { sessionId: ev.sessionId }).catch(() => {});
      resolveFirst();
    });
    await this.cdp.send('Page.startScreencast', {
      format: this.format, quality: this.quality, maxWidth: this.width, maxHeight: this.height, everyNthFrame: 1,
    });
  }

  // The screencast only emits on change; nudge the page so a frame exists at the moment the timeline begins.
  async markOrigin(page) {
    const before = this.frames.length;
    await page.evaluate(() => { window.dispatchEvent(new Event('resize')); });
    const t0 = Date.now();
    while (Date.now() - t0 < 400 && this.frames.length === before) await new Promise((r) => setTimeout(r, 20));
    this.originNode = Date.now() / 1000;
  }

  // seconds on the video timeline for a node wall-clock time (seconds)
  clockOffset() {
    if (!this.frames.length) return 0;
    return Math.min(...this.frames.map((f) => f.received - f.ts));
  }
  timeOf(nodeSeconds) { return nodeSeconds - this.originNode; }

  async stop(outFile) {
    const endNode = Date.now() / 1000;
    await this.cdp.send('Page.stopScreencast').catch(() => {});
    if (!this.frames.length) throw new Error('no screencast frames captured');
    const off = this.clockOffset();
    // frame time on the node clock
    const fr = this.frames.map((f) => ({ file: f.file, t: f.ts + off })).sort((a, b) => a.t - b.t);
    const origin = this.originNode;
    // the frame showing at the origin is the last one at or before it (else the first one after)
    let startIdx = 0;
    for (let i = 0; i < fr.length; i++) if (fr[i].t <= origin) startIdx = i;
    const use = fr.slice(startIdx).map((f) => ({ file: f.file, t: Math.max(f.t, origin) }));
    const lines = [];
    for (let i = 0; i < use.length; i++) {
      const end = i + 1 < use.length ? use[i + 1].t : endNode;
      const d = Math.max(end - use[i].t, 0.001);
      lines.push(`file '${use[i].file.replace(/'/g, "'\\''")}'`, `duration ${d.toFixed(6)}`);
    }
    lines.push(`file '${use[use.length - 1].file}'`);
    const list = path.join(this.framesDir, 'frames.txt');
    fs.writeFileSync(list, lines.join('\n') + '\n');
    // -t: the concat demuxer would otherwise count the last frame's duration a second time
    ffmpeg(['-f', 'concat', '-safe', '0', '-i', list, '-vf', `fps=30:round=near,${SCALE}`, '-t', (endNode - origin).toFixed(3), ...X264, outFile]);
    this.stats = {
      frames: this.frames.length, used: use.length, durationNode: endNode - origin,
      meanFps: use.length / (endNode - origin),
    };
  }

  cleanup() { fs.rmSync(this.framesDir, { recursive: true, force: true }); }
}

// ---------------------------------------------------------------------------------------------------------------
export class PlaywrightCapture {
  constructor({ videoDir }) { this.videoDir = videoDir; this.originNode = null; this.startNode = null; }
  contextOptions(width, height) {
    fs.rmSync(this.videoDir, { recursive: true, force: true });
    fs.mkdirSync(this.videoDir, { recursive: true });
    return { recordVideo: { dir: this.videoDir, size: { width, height } } };
  }
  async start(ctx, page) { this.page = page; this.startNode = Date.now() / 1000; }
  async markOrigin() { this.originNode = Date.now() / 1000; }
  timeOf(nodeSeconds) { return nodeSeconds - this.originNode; }
  async stop(outFile, ctx) {
    const endNode = Date.now() / 1000;
    const video = this.page.video();
    await ctx.close();
    const webm = await video.path();
    // The recording starts at page creation (a little before startNode); trim to the origin. The estimate has a
    // sub-second uncertainty, which is part of why this method is the fallback.
    const ss = Math.max(0, this.originNode - this.startNode);
    ffmpeg(['-ss', ss.toFixed(3), '-i', webm, '-vf', `fps=30,${SCALE_LIMITED}`, ...X264, outFile]);
    this.stats = { durationNode: endNode - this.originNode, trimmed: ss };
    this.webm = webm;
  }
  cleanup() { fs.rmSync(this.videoDir, { recursive: true, force: true }); }
}
