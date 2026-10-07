# Assembles the recorded segments and the narration into the portfolio video.
#
#   ruby demo/video/assemble.rb [--scenes out/scenes] [--narration narration/kokoro-af_heart-speed0.95]
#                               [--out out] [--name whatsapp-commerce-v2-demo.mp4]
#
# Inputs: <scenes>/<segment>.mp4 and <segment>.beats.json from record.mjs (each beat's start and end on that video's
# timeline), in the order of beats.json, and one WAV per beat from narrate.py. Each beat's narration starts LEAD seconds
# after the beat starts on screen.
#
# Outputs in --out: master-silent.mp4 (clean cuts, short fade in and out), narration.wav (the whole narration on the
# video's timeline, -16 LUFS), <name> (H.264 1920x1080 CRF 20 + AAC 192k) and timeline.json (each beat's absolute
# start/end and narration start, used by finish.rb for timing.md and captions.srt).
require "json"
require "fileutils"
require "optparse"
require "open3"

LEAD = 0.25
FADE_IN = 0.5
FADE_OUT = 1.0
HERE = __dir__

opts = { scenes: File.join(HERE, "out/scenes"), narration: File.join(HERE, "narration/kokoro-af_heart-speed0.95"),
         out: File.join(HERE, "out"), name: "whatsapp-commerce-v2-demo.mp4" }
OptionParser.new do |o|
  o.on("--scenes DIR") { opts[:scenes] = File.expand_path(_1) }
  o.on("--narration DIR") { opts[:narration] = File.expand_path(_1) }
  o.on("--out DIR") { opts[:out] = File.expand_path(_1) }
  o.on("--name FILE") { opts[:name] = _1 }
end.parse!

def run(*cmd)
  out, status = Open3.capture2e(*cmd)
  abort "failed: #{cmd.join(' ')}\n#{out.lines.last(15).join}" unless status.success?
  out
end

def duration(path) = run("ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", path).to_f

plan = JSON.parse(File.read(File.join(HERE, "beats.json")))
FileUtils.mkdir_p(opts[:out])

segments = plan.fetch("segments").map do |seg|
  video = File.join(opts[:scenes], "#{seg['id']}.mp4")
  log = JSON.parse(File.read(File.join(opts[:scenes], "#{seg['id']}.beats.json")))
  { id: seg["id"], video: video, length: duration(video), beats: log.fetch("beats"), plan: seg["beats"] }
end

# 1. The silent master: segments joined with clean cuts, faded in from and out to black.
total = segments.sum { _1[:length] }
inputs = segments.flat_map { [ "-i", _1[:video] ] }
joined = segments.each_index.map { "[#{_1}:v]" }.join
filter = "#{joined}concat=n=#{segments.size}:v=1:a=0,fade=t=in:st=0:d=#{FADE_IN}," \
         "fade=t=out:st=#{(total - FADE_OUT).round(3)}:d=#{FADE_OUT},format=yuv420p[v]"
master = File.join(opts[:out], "master-silent.mp4")
run("ffmpeg", "-y", "-v", "error", *inputs, "-filter_complex", filter, "-map", "[v]", "-c:v", "libx264", "-preset", "slow",
    "-crf", "18", "-r", "30", "-movflags", "+faststart", master)
puts "master-silent.mp4  #{duration(master).round(2)} s"

# 2. The narration track: each beat's WAV at its beat's start (+ LEAD), per segment, then the segments in order.
offset = 0.0
clips = []
timeline = []
segments.each do |seg|
  seg[:beats].each_with_index do |beat, i|
    wav = File.join(opts[:narration], "#{beat['id']}.wav")
    abort "missing narration: #{wav} (run bin/demo or narrate.py)" unless File.file?(wav)
    at = offset + beat.fetch("start") + LEAD
    room = (seg[:beats][i + 1]&.fetch("start") || seg[:length]) - beat.fetch("start") - LEAD
    len = duration(wav)
    warn "warning: #{beat['id']} narration #{len.round(2)} s overruns its #{room.round(2)} s on screen" if len > room
    clips << [ wav, at ]
    meta = seg[:plan].find { _1["id"] == beat["id"] }
    timeline << { "segment" => seg[:id], "id" => beat["id"], "start" => (offset + beat["start"]).round(3), "end" => (offset + beat["end"]).round(3),
                  "narration_start" => at.round(3), "narration_end" => (at + len).round(3), "visual" => meta["visual"], "text" => meta["text"] }
  end
  offset += seg[:length]
end
mix = clips.each_with_index.map { |(_, at), i| "[#{i}:a]aresample=48000,adelay=#{(at * 1000).round}:all=1[a#{i}]" }.join(";")
mix += ";#{clips.each_index.map { "[a#{_1}]" }.join}amix=inputs=#{clips.size}:normalize=0:dropout_transition=0," \
       "apad,atrim=0:#{total.round(3)},loudnorm=I=-16:TP=-1.5:LRA=11,aresample=48000[a]"
narration = File.join(opts[:out], "narration.wav")
run("ffmpeg", "-y", "-v", "error", *clips.flat_map { [ "-i", _1[0] ] }, "-filter_complex", mix, "-map", "[a]",
    "-ac", "1", "-c:a", "pcm_s24le", narration)

# 3. The final video: the master re-encoded for delivery (H.264 CRF 20) with the narration (AAC 192k).
final = File.join(opts[:out], opts[:name])
run("ffmpeg", "-y", "-v", "error", "-i", master, "-i", narration, "-map", "0:v", "-map", "1:a", "-c:v", "libx264", "-preset", "slow",
    "-crf", "20", "-pix_fmt", "yuv420p", "-r", "30", "-c:a", "aac", "-b:a", "192k", "-ac", "2", "-shortest", "-movflags", "+faststart", final)
File.write(File.join(opts[:out], "timeline.json"), JSON.pretty_generate({ "video" => opts[:name], "duration" => duration(final).round(3), "beats" => timeline }) + "\n")
puts "#{opts[:name]}  #{duration(final).round(2)} s, #{clips.size} narration beats"
