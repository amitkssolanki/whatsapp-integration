# Demo video pipeline

`bin/demo` regenerates both cuts of the WhatsApp Commerce V2 demo video from this repository, end to end, with one command:
the real WhatsApp section is rendered from the author's own phone screen recordings (made once with
`bin/demo capture-whatsapp`), the application demo is a headless Playwright recording with CDP screencast capture, the
narration is local Kokoro TTS, and ffmpeg assembles it all.

| Cut | Script | Output | Length | Quality |
|---|---|---|---|---|
| Portfolio (premium) | `beats.json` | `out/whatsapp-commerce-v2-demo.mp4` | about 95 s | H.264 CRF 12 |
| Upwork | `beats-upwork.json` | `out/whatsapp-commerce-v2-demo-upwork.mp4` | 60 s or less (enforced) | H.264 CRF 14 |

Both are 1920x1080, 30 fps, AAC 256k stereo, narrated. Quality is chosen over file size: every intermediate is encoded at
CRF 10–12 and the portfolio cut at CRF 12, which keeps fine UI text sharp (a 95 s cut is around 13 MB; Upwork allows up
to 100 MB). Credit: voice and pipeline approach reused from the author's vrinda demo (Kokoro-82M `af_heart`, speed 0.95,
Apache-2.0). Suggested credit line: "Narration: AI-generated voice, Kokoro-82M (Apache-2.0)."

## What it produces (all in `demo/video/out/`, not tracked)

| File | What |
|---|---|
| `whatsapp-commerce-v2-demo.mp4`, `whatsapp-commerce-v2-demo-upwork.mp4` | The two videos |
| `<cut>/timing.md` | Scene and timing index: beat, start, end, visual, narration text |
| `<cut>/captions.srt` | Narration timing as SRT, for review only. The videos carry no subtitles (no burned-in text, no subtitle track), and no `.srt` is placed next to an MP4, where players would load it automatically |
| `<cut>/contact-sheet.png` | One labelled frame per beat |
| `<cut>/thumbnail.png` | 1920x1080 cover frame (the title card) |
| `upwork/cover-4x3.png` | 2000x1500 (4:3) project cover for the Upwork catalog (`cards/upwork-cover.html`) |
| `cards/*.png` | Every card rendered at 2x for review |
| `<cut>/scenes/*.mp4`, `*.beats.json` | One video per segment, with each beat's start and end |
| `<cut>/narration.wav`, `master-silent.mp4`, `timeline.json` | Intermediate tracks and the absolute timeline |
| `android/` | Raw phone recordings from `bin/demo capture-whatsapp` (before one is adopted) |
| `db.log`, `server.log`, `<cut>/record-<segment>.log` | Logs |

Narration WAVs are cached per cut in `narration/<cut>/kokoro-af_heart-speed0.95/` (regenerated when the beats file is newer).

## The story

The beats files are the authority for narration and visuals; `segments.mjs` (browser scenes) and `whatsapp-motion.json`
(the phone recordings) say what each beat shows and when.

Portfolio: title → V1's own evidence → **real WhatsApp interaction** (the author's phone: chat → catalog → product →
cart → Place order → the app's receipt → the confirmation after the operator accepted it) → how it works (a
video-specific flow graphic, lit step by step) → **application demo, synthetic data** (an intro card, then the operator's
conversation, order, reply statuses, health) → **real Meta verification** of 6 Oct 2026 and the 131009 diagnosis →
engineering verification → closing card (project, `amitsolanki.com`, stack).

Upwork: what was built → the same real WhatsApp interaction, shorter → how it works → the operator dashboard (synthetic
data, same intro card) → verified and deployed → project closing card. No website, email, phone number, URL or other
contact details, no third-party logos, no evidence file names.

The engineering card says **1,112** tests: RSpec examples, 0 failures, on the code that records the video
(`bundle exec rspec`). Re-run the suite and update `cards/08-engineering.html`, `cards/u05-verified.html` and the
b15 line in `beats.json` if that number changes. (The public release `33b18a5` had 1,111; the extra example is the
synthetic seed's hero-scenario spec, added after it.)

## Data boundaries

- **Real WhatsApp section** (`motion.mjs`): two screen recordings of the author's own phone, made on 7 Oct 2026 with
  scrcpy at the phone's native 1260x2800 (HEVC, up to 60 fps): `motion-browse.mp4` (chat → catalog → product → cart,
  nothing sent) and `motion-order.mp4` (the same cart → Place order → the app's receipt → the confirmation of real
  order #11 after the author accepted it in the production admin). `whatsapp-motion.json` lists the clips: every clip
  plays at real speed, each frame is cropped (the status and navigation bars are never shown) and scaled into one large
  panel; cuts only skip idle stretches, repeated scrolling, a WhatsApp notification banner and a one-frame flash. Nothing inside a frame is
  edited, and no touch indicator is added (the recordings were made with "Show taps" off; scrcpy ran with
  `--no-control`, so it never touched the phone). The narration describes only what these frames show. The recordings
  are git-ignored (the author's real account) and checked by SHA-256 before use.
- **Application demo** (synthetic): a local database (`whatsapp_integration_demo_video`, rebuilt each run) filled by
  `demo:seed_integration`: fictional customers with fake `+1 555` numbers, Meta replaced by an in-process fake. The hero
  customer (Maya Fernandes, invented) says "Hi" and sends a cart, like the real interaction; her order is #1 in that
  database and is never presented as a real order. The section opens with the "Application demo · synthetic data" card
  and every local frame carries a small DEMO DATA tag; the per-record "synthetic" badges and the footer's "Signed in as
  ..." line are hidden by injected CSS (presentation only). The server runs on `localhost:3021` with **every key listed
  in `.env.example` blanked** (Meta token and ids, the business number, verify token, app secret, catalog id, admin
  credentials), `ADMIN_AUTH_DISABLED=1` (local only) and `DEMO_MASK_PII=0` (the data is fictional).
  `SOLID_QUEUE_IN_PUMA` is unset, so no job processes run while recording.
- **Evidence cards** state real facts from `docs/evidence/` (V1's logs; verification session 1 of 6 Oct 2026) with short
  labels such as "Real Meta verification · 6 Oct 2026". They show no file names, phone numbers, Meta ids, server
  addresses or private paths; the documents in `docs/evidence/` remain the audit trail, and the limits (no long-term
  reliability or production-scale claim) live there and in the case study rather than on a closing card.
- The browser recorder is read-only: it aborts every non-GET request and blocks every host except `localhost:3021`
  (cards load from this directory). It never contacts Meta, WhatsApp, Facebook or GitHub, and never types or passes a
  credential. The production admin is never recorded.
- Only `whatsapp_integration_demo_video` is ever dropped or written; before any drop, `bin/demo` asks Rails which
  database it would really use and aborts unless it is exactly that one.

## Prerequisites

- macOS with `ffmpeg`/`ffprobe`, Node (Playwright 1.62.0 is pinned and installed by `bin/demo` with `npm ci`), Ruby (as for the app) and a running PostgreSQL.
- Chromium for Playwright 1.62.0 (`bin/demo` runs `npx playwright install chromium` if it is missing).
- `ffmpeg`/`ffprobe` are taken from `PATH` (falling back to `/opt/homebrew/bin`).
- Only for `bin/demo capture-whatsapp`: `brew install scrcpy` and `brew install --cask android-platform-tools` (adb).
  The normal build never needs the phone.
- The Kokoro narration venv, needed only when narration has to be (re)generated. It lives at
  `~/.cache/vrinda-tts/kokoro`: that path is historical (it was first installed for the author's vrinda demo) and is kept
  because that is where the venv already exists; `bin/demo` and `narrate.py` expect it there. Install commands:

```bash
brew install espeak-ng
uv venv --python 3.11 ~/.cache/vrinda-tts/kokoro
uv pip install --python ~/.cache/vrinda-tts/kokoro/bin/python "kokoro>=0.9.4" soundfile numpy "transformers>=4.50" "tokenizers>=0.20" pip
~/.cache/vrinda-tts/kokoro/bin/python -m spacy download en_core_web_sm
```

## The human steps: the phone recordings

`bin/demo` stops with exit code 2 unless `demo/video/assets/whatsapp/` holds the recordings named in
`whatsapp-motion.json` with exactly the SHA-256 recorded there (the cut points belong to those files). To make new ones:

1. On the Android phone: enable Developer options (tap Build number 7 times) and USB debugging; leave "Show taps" and
   "Pointer location" off; turn on Do Not Disturb; connect by USB and allow the computer. Unlock the phone and open
   the WhatsApp chat with The Local Table. (Unlock before recording, so no PIN entry is captured.)
2. `bin/demo capture-whatsapp` records the screen (native resolution, `--no-control`) to `out/android/raw-<time>.mp4`
   while you operate the phone; press Ctrl+C to stop. Browsing sends nothing. Placing an order is real traffic (a real
   order in production that you then accept or reject in the admin); only the author does that, by hand.
3. Review the recording, copy it into `assets/whatsapp/`, and point a source in `whatsapp-motion.json` at it with its
   SHA-256 and new cut points (`ffmpeg ... -vf "select='gt(scene,0.01)',metadata=print"` lists the moments the screen
   changes). Check `out/<cut>/contact-sheet.png` and the frames after the next build.

## Run

```bash
bin/demo                                # both cuts, idempotent (no phone needed)
bin/demo portfolio                      # only the portfolio cut
bin/demo upwork                         # only the Upwork cut
bin/demo --skip-db                      # keep the existing recording database
bin/demo portfolio --only 03-demo       # one segment only (no assembly)
bin/demo --force-narration              # regenerate the narration (also automatic when a beats file is newer)
bin/demo capture-whatsapp               # record the phone screen (human-operated; see above)
```

Exit codes: 0 done, 1 a prerequisite or step failed (including an Upwork cut over 60 s), 2 a recording is missing or not
the approved one, or the phone is not ready.

Steps: (a) prerequisites, (b) the approved phone recordings, (c) recreate the database (guard, then
`RAILS_ENV=test DATABASE_URL=postgres:///whatsapp_integration_demo_video bin/rails db:drop db:create db:schema:load db:seed demo:seed_integration CONFIRM=yes`,
with the `.env.example` keys blanked and `SOLID_QUEUE_IN_PUMA` unset), (d) narration per cut if needed, (e) start the
local server, render the phone segment (`motion.mjs`) and record the browser segments (`record.mjs`) of each cut, stop
the server, (f) assemble each cut, write its timing index, captions, contact sheet and thumbnail, check the length
limit, and render the cards and the Upwork cover.

## Timing

Every beat is held for its narration length plus a short pad (0.4 s), or its `min_seconds`, or (phone beats) the length
of its clips, whichever is longest; the narration starts 0.25 s into its beat (`LEAD` in `record.mjs` and
`assemble.rb`). Cues inside a browser beat (`b.word('…')` in `segments.mjs`) are placed where the narration reaches that
word. Keep the portfolio cut around 90–95 s; the Upwork cut must stay at or under 60 s.

## How to verify before publishing

1. `out/<cut>/contact-sheet.png`, and every frame: `ruby demo/video/finish.rb --out demo/video/out/<cut> --frames`
   (one frame per second in `out/<cut>/frames/`). Local admin frames must show only invented people with `+1 555` numbers
   and the DEMO DATA tag; no frame may show a real phone number, a Meta id, a server IP, a private path or a production
   admin page; the phone frames must show no status bar, notification or other chat.
2. The narration of the phone beats against what the frames show (exact wording: order #11, the receipt, the confirmation).
3. `blocked_hosts` in `out/<cut>/scenes/*.beats.json` lists what the recorder refused to load (expected: empty).
4. Upwork: the cut is at most 60 s and an MP4 well under 100 MB; no contact details, URLs or third-party logos on screen.

## Files

`record.mjs` (browser recorder), `segments.mjs` (what each browser beat shows, for both cuts), `motion.mjs` (renders the
phone segment), `whatsapp-motion.json` (its clips and framing), `capture.mjs` (CDP screencast to constant-frame-rate
video), `assemble.rb`, `finish.rb`, `contact-sheet.mjs`, `narrate.py`, `render-cards.mjs`, `cards/` (the HTML cards and
the Upwork cover), `beats.json`, `beats-upwork.json`.
