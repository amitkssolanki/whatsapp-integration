# Demo video pipeline

`bin/demo` regenerates both cuts of the WhatsApp Commerce V2 demo video from this repository, end to end, with one command:
a headless Playwright recording with CDP screencast capture, local Kokoro narration, ffmpeg assembly.

| Cut | Script | Output | Length |
|---|---|---|---|
| Portfolio | `beats.json` | `out/whatsapp-commerce-v2-demo.mp4` | about 90 s (target 85–95 s) |
| Upwork | `beats-upwork.json` | `out/whatsapp-commerce-v2-demo-upwork.mp4` | 60 s or less (enforced: `bin/demo` fails above `max_seconds`) |

Both are 1920x1080, H.264 30 fps + AAC, narrated. Credit: voice and pipeline approach reused from the author's vrinda demo
(Kokoro-82M `af_heart`, speed 0.95, Apache-2.0). Suggested credit line: "Narration: AI-generated voice, Kokoro-82M (Apache-2.0)."

## What it produces (all in `demo/video/out/`, not tracked)

| File | What |
|---|---|
| `whatsapp-commerce-v2-demo.mp4`, `whatsapp-commerce-v2-demo-upwork.mp4` | The two videos |
| `whatsapp-commerce-v2-demo.srt`, `whatsapp-commerce-v2-demo-upwork.srt` | Captions next to each video (from the narration text and timing) |
| `<cut>/timing.md` | Scene and timing index: beat, start, end, visual, narration text |
| `<cut>/captions.srt` | Same captions |
| `<cut>/contact-sheet.png` | One labelled frame per beat |
| `<cut>/thumbnail.png` | 1920x1080 cover frame (the title card) |
| `upwork/cover-4x3.png` | 2000x1500 (4:3) project cover for the Upwork catalog (`cards/upwork-cover.html`) |
| `cards/*.png` | Every card rendered at 2x for review (the WhatsApp card once per shot) |
| `<cut>/scenes/*.mp4`, `*.beats.json` | One capture per segment, with each beat's start and end |
| `<cut>/narration.wav`, `master-silent.mp4`, `timeline.json` | Intermediate tracks and the absolute timeline |
| `db.log`, `server.log`, `<cut>/record-<segment>.log` | Logs |

Narration WAVs are cached per cut in `narration/<cut>/kokoro-af_heart-speed0.95/` (regenerated when the beats file is
newer). With `--placeholder-whatsapp` everything is written under `out/preview/` instead (videos as `preview-<cut>.mp4`), so
a placeholder run never overwrites or sits next to final-named files.

## The story

The beats files are the authority for narration and visuals; `segments.mjs` says what each beat shows and when.

Portfolio: title → V1's own evidence (what V1 got wrong) → **real WhatsApp interaction** (the author's screenshots, three
shots) → how it works (a video-specific flow graphic, lit step by step) → **application demo, synthetic data** (an intro
card, then the operator's conversation, order, reply statuses, deliveries, health) → **real Meta verification** of
6 Oct 2026 and the 131009 diagnosis → engineering verification card → closing card with the limits and the repository.

Upwork: what was built → the real WhatsApp interaction → how it works → the operator dashboard (synthetic data, same
intro card) → verified and deployed → closing line. No URL, no contact details, no logos, no evidence file names.

The engineering card says **1,112** tests: the number of RSpec examples, 0 failures, on the code that records the video
(`bundle exec rspec`). Re-run the suite and update `cards/08-engineering.html`, `cards/u05-verified.html` and the b12 line
in `beats.json` if that number changes. (The public release `33b18a5` had 1,111; the extra example is the
synthetic seed's hero-scenario spec, added after it.)

## Data boundaries

- **Real WhatsApp screenshots** (`assets/whatsapp/`, git-ignored, see below) are shown as plain crops of the original
  images at their native 1260 px width (`cards/03-whatsapp.html` sets the crop rows): nothing in them is edited,
  redrawn, retyped or upscaled. The card says "Real WhatsApp interaction · 7 Oct 2026 / Author's test account". The
  narration describes only what the screenshots show (the customer's message is "Hi").
- **Admin screens are synthetic**: a local database (`whatsapp_integration_demo_video`, rebuilt each run) filled by
  `demo:seed_integration`: fictional customers with fake `+1 555` numbers, Meta replaced by an in-process fake. The hero
  customer (Maya Fernandes, invented) mirrors the real interaction: "Hi", the catalog card, the same cart, no note. The
  section opens with the "Application demo · synthetic data" card and every local frame carries a small DEMO DATA tag;
  the per-record "synthetic" badges and the footer's "Signed in as ..." line are hidden by injected CSS (presentation
  only). The server runs on `localhost:3021` with **every key listed in `.env.example` blanked** (Meta token and ids, the
  business number, verify token, app secret, catalog id, admin credentials), `ADMIN_AUTH_DISABLED=1` (local only) and
  `DEMO_MASK_PII=0` (the data is fictional). `SOLID_QUEUE_IN_PUMA` is unset, so no job processes run while recording.
- **Evidence cards** state real facts from `docs/evidence/` (V1's logs; verification session 1 of 6 Oct 2026) with short
  labels such as "Real Meta verification · 6 Oct 2026". They show no file names, phone numbers, Meta ids, server
  addresses or private paths; the documents in `docs/evidence/` remain the audit trail.
- The recorder is read-only: it aborts every non-GET request and blocks every host except `localhost:3021` (cards and
  screenshots load from this directory). It never contacts Meta, WhatsApp, Facebook or GitHub, and never types or passes
  a credential. The production admin is never recorded.
- Only `whatsapp_integration_demo_video` is ever dropped or written; before any drop, `bin/demo` asks Rails which
  database it would really use and aborts unless it is exactly that one.

## Prerequisites

- macOS with `ffmpeg`/`ffprobe`, Node (Playwright 1.62.0 is pinned and installed by `bin/demo` with `npm ci`), Ruby (as for the app) and a running PostgreSQL.
- Chromium for Playwright 1.62.0 (`bin/demo` runs `npx playwright install chromium` if it is missing).
- `ffmpeg`/`ffprobe` are taken from `PATH` (falling back to `/opt/homebrew/bin`).
- The Kokoro narration venv, needed only when narration has to be (re)generated. It lives at
  `~/.cache/vrinda-tts/kokoro`: that path is historical (it was first installed for the author's vrinda demo) and is kept
  because that is where the venv already exists; `bin/demo` and `narrate.py` expect it there. Install commands:

```bash
brew install espeak-ng
uv venv --python 3.11 ~/.cache/vrinda-tts/kokoro
uv pip install --python ~/.cache/vrinda-tts/kokoro/bin/python "kokoro>=0.9.4" soundfile numpy "transformers>=4.50" "tokenizers>=0.20" pip
~/.cache/vrinda-tts/kokoro/bin/python -m spacy download en_core_web_sm
```

## The one human step: the WhatsApp screenshots

`bin/demo` stops with exit code 2 until `demo/video/assets/whatsapp/` holds five PNGs, screenshots from the author's own
phone at its native resolution (1260x2800 for the current set, taken 7 Oct 2026), with only the status bar cropped off
(the top 135 px):

| File | Screen |
|---|---|
| `00-chat-greeting.png` | the chat after sending "Hi": the "Hi" and the catalog card |
| `01-catalog.png` | the catalog list (catalog/shop icon in the chat header) |
| `02-product.png` | the Classic Lasagne product page |
| `03-cart.png` | the cart: 2 × Classic Lasagne, 1 × Baked Salmon with Fennel & Tomatoes, 2 × Apple Berry Smoothie |
| `04-order-sent.png` | the chat after placing the order: the sent cart and the receipt |

Sending "Hi" and placing the order are real traffic to the production app (the 7 Oct set produced real order #10, which
the operator accepts or rejects in the admin). Nothing in Meta is changed. Look at each PNG at full size for phone
numbers, names or ids before running. The crops in `cards/03-whatsapp.html` are tuned to this set: with new screenshots,
check `out/cards/03-whatsapp-shot*.png` and adjust the `--y0`/`--y1` rows if the layout moved.

The screenshots are git-ignored on purpose (they are the author's real account); keep them in this directory to
regenerate.

## Run

```bash
bin/demo                                # both cuts, idempotent
bin/demo portfolio                      # only the portfolio cut
bin/demo upwork                         # only the Upwork cut
bin/demo --skip-db                      # keep the existing recording database
bin/demo portfolio --only 02-demo       # record one segment only (no assembly)
bin/demo --force-narration              # regenerate the narration (also automatic when a beats file is newer)
bin/demo --placeholder-whatsapp         # test the pipeline without the screenshots (out/preview/ only)
```

Exit codes: 0 done, 1 a prerequisite or step failed (including an Upwork cut over 60 s), 2 the screenshots are missing.

Steps: (a) prerequisites, (b) screenshots, (c) recreate the database (guard, then
`RAILS_ENV=test DATABASE_URL=postgres:///whatsapp_integration_demo_video bin/rails db:drop db:create db:schema:load db:seed demo:seed_integration CONFIRM=yes`,
with the `.env.example` keys blanked and `SOLID_QUEUE_IN_PUMA` unset), (d) narration per cut if needed, (e) start the
local server, record each cut's segments, stop the server, (f) assemble each cut, write its timing index, captions,
contact sheet and thumbnail, check the length limit, and render the cards and the Upwork cover.

## Timing

Every beat is held for its narration length plus a short pad (0.4 s, `--pad` in `record.mjs`), or its `min_seconds` if
longer; the narration starts 0.25 s into its beat (`LEAD` in `record.mjs` and `assemble.rb`). Cues inside a beat
(`b.word('…')` in `segments.mjs`) are placed where the narration reaches that word, so they follow edits to the text. If you
edit the narration, keep the portfolio cut within 85–95 s; the Upwork cut must stay at or under 60 s.

## How to verify before publishing

1. `out/<cut>/contact-sheet.png`, and every frame: `ruby demo/video/finish.rb --out demo/video/out/<cut> --frames`
   (one frame per second in `out/<cut>/frames/`). Local admin frames must show only invented people with `+1 555` numbers
   and the DEMO DATA tag; no frame may show a real phone number, a Meta id, a server IP, a private path or a production
   admin page.
2. The WhatsApp shots: `out/cards/03-whatsapp-shot1..3.png` against the original screenshots.
3. `blocked_hosts` in `out/<cut>/scenes/*.beats.json` lists what the recorder refused to load (expected: empty).
4. Upwork: the cut is at most 60 s and an MP4 well under 100 MB; no contact details, URLs or third-party logos on screen.

## Files

`record.mjs` (recorder), `segments.mjs` (what each beat shows, for both cuts), `capture.mjs` (CDP screencast to
constant-frame-rate video), `assemble.rb`, `finish.rb`, `contact-sheet.mjs`, `narrate.py`, `render-cards.mjs`, `cards/`
(the HTML cards and the Upwork cover), `beats.json`, `beats-upwork.json`.
