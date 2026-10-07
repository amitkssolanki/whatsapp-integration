# Portfolio video pipeline

`bin/demo` regenerates the WhatsApp Commerce V2 portfolio video (about 90 s, 1920x1080, H.264 + AAC, narrated) from this
repository, end to end, with one command: a headless Playwright recording with CDP screencast capture, local Kokoro
narration, ffmpeg assembly.

Credit: voice and pipeline approach reused from the author's vrinda demo (Kokoro-82M `af_heart`, speed 0.95, Apache-2.0).

## What it produces (all in `demo/video/out/`, not tracked)

| File | What |
|---|---|
| `whatsapp-commerce-v2-demo.mp4` | The video |
| `scenes/*.mp4`, `scenes/*.beats.json` | One capture per segment, with each beat's start and end |
| `timing.md` | Scene and timing index: beat, start, end, visual, narration text |
| `captions.srt` | Captions from the narration text and timing |
| `contact-sheet.png` | One labelled frame per beat |
| `thumbnail.png` | 1920x1080 cover frame (the title card) |
| `narration.wav`, `master-silent.mp4`, `timeline.json` | Intermediate tracks and the absolute timeline |

With `--placeholder-whatsapp` **every** artifact (the video as `preview-placeholder.mp4`, `scenes/`, `timing.md`,
`captions.srt`, `contact-sheet.png`, `thumbnail.png`, `timeline.json`, logs) is written under `out/preview/` instead, so a
placeholder run never overwrites or sits next to final-named files.

## The story (see `beats.json`, the authority for narration and visuals)

1. Title card, then V1's own evidence card (what V1 got wrong).
2. Fresh phone captures of the live WhatsApp catalog and cart, then the admin conversation of the synthetic hero customer.
3. The order, its notification lifecycle, the deliveries list with a duplicate.
4. The Health page.
5. Two evidence cards from the real verification session of 6 Oct 2026, including error 131009.
6. The public GitHub Actions run of the release commit `33b18a5` (pinned in `segments.mjs`, because the narration's
   "1,111" refers to that release), then the architecture and quality callouts.
7. Closing card with the limits.

## Data boundaries

- Admin screens come from a **local database** (`whatsapp_integration_demo_video`, rebuilt each run) filled by `demo:seed_integration`:
  fictional customers with fake `+1 555` numbers, flagged `synthetic`, Meta replaced by an in-process fake. The server
  runs on `localhost:3021` with **every key listed in `.env.example` blanked** (Meta token and ids, the business number,
  verify token, app secret, catalog id, admin credentials), `ADMIN_AUTH_DISABLED=1` (local only) and `DEMO_MASK_PII=0`
  (the data is fictional). `SOLID_QUEUE_IN_PUMA` is unset, so no job processes run while recording, and the admin footer's
  "Signed in as ..." line is hidden by injected CSS (presentation only). Every local frame carries the caption "Synthetic demo data · same code · Meta replaced by an
  in-process fake".
- Evidence cards state real facts from `docs/evidence/` and are captioned "Real evidence · 6 Oct 2026". They contain no phone
  numbers, Meta ids, server addresses or private paths.
- The only outside page is the **public** GitHub Actions run page of this repository (pinned run of commit `33b18a5`),
  opened without signing in.
- The recorder is read-only: it aborts every non-GET request and blocks every host except `localhost:3021`, `github.com`
  and its asset hosts. It never contacts Meta, WhatsApp or Facebook, and never types or passes a credential. The
  production admin is never recorded.
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

## The one human step: fresh WhatsApp captures

`bin/demo` stops with exit code 2 until `demo/video/assets/whatsapp/` holds `01-catalog.png`, `02-product.png` and
`03-cart.png` (never old screenshots). On your phone, open the WhatsApp chat with The Local Table (the demo business number).
**Do not send a message or place an order.** Tap the catalog/shop icon in the chat header and screenshot the catalog list
(`01-catalog.png`). Tap Classic Lasagne and screenshot the product page (`02-product.png`). Add 2 × Classic Lasagne,
1 × Baked Salmon with Fennel & Tomatoes and 2 × Apple Berry Smoothie, open the cart, and screenshot it **without tapping
Place order** (`03-cart.png`). No message is sent and no Meta traffic is created.

**Crop out or cover** anything that shows a phone number, a `wa.me` link or any ids (business, catalog or product ids), and
also notifications, the status bar and your own name or number. Each screenshot should show only the business name, the
catalog, the product and the cart. Look at each PNG at full size before running. The video labels this card "Real WhatsApp
captures · cart not sent".

## Run

```bash
bin/demo                           # everything, idempotent
bin/demo --skip-db                 # keep the existing recording database
bin/demo --only 03-lifecycle       # record one segment only (no assembly)
bin/demo --force-narration         # regenerate the narration (also automatic when beats.json is newer)
bin/demo --placeholder-whatsapp    # test the pipeline before the phone captures exist
```

Exit codes: 0 done, 1 a prerequisite or step failed, 2 the phone captures are missing. With `--placeholder-whatsapp`
the output directory is `out/preview/` (see above).

Steps: (a) prerequisites, (b) captures, (c) recreate the database
(guard, then `RAILS_ENV=test DATABASE_URL=postgres:///whatsapp_integration_demo_video bin/rails db:drop db:create db:schema:load db:seed demo:seed_integration CONFIRM=yes`, both with the `.env.example` keys blanked and `SOLID_QUEUE_IN_PUMA` unset),
(d) narration if needed, (e) start the local server, record the seven segments, stop the server, (f) assemble, (g) timing
index, captions, contact sheet and thumbnail. Logs are next to the outputs (`db.log`, `server.log`, `record-<segment>.log`).

## Timing

Every beat is held for its narration length plus a short pad (0.4 s, `--pad` in `record.mjs`); the narration starts 0.25 s
into its beat (`LEAD` in `assemble.rb`), so total length follows the narration (84.5 s) plus about five seconds. If you edit
the narration text, keep the total under about 90 s.

## How to verify privacy before publishing

1. `out/contact-sheet.png` and `ffmpeg -i out/whatsapp-commerce-v2-demo.mp4 -vf fps=1 out/frames/f%03d.png` (or
   `ruby demo/video/finish.rb --frames`): look at the frames. Local admin frames must show only `synthetic`-badged people
   with `+1 555` numbers, no `Customer #` placeholders; no frame may show a real phone number, a Meta id, a server IP or a
   production admin page.
2. Look at the three phone captures at full size (status bar, notifications, contact names).
3. `blocked_hosts` in `out/scenes/*.beats.json` lists what the recorder refused to load (GitHub telemetry); anything else
   there is worth a look.
4. Narration is AI-generated: "Narration: AI-generated voice, Kokoro-82M (Apache-2.0)."

## Files

`record.mjs` (recorder), `segments.mjs` (what each beat shows), `capture.mjs` (CDP screencast to constant-frame-rate video),
`assemble.rb`, `finish.rb`, `contact-sheet.mjs`, `narrate.py`, `render-cards.mjs` (renders the cards to `out/cards/` for
review), `cards/` (the HTML cards), `beats.json`.
