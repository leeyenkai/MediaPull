# Spike S1: rewriting video and audio tags without touching their streams (section 45)

Question: can MediaPull change a video's or audio file's date, location, rating, keywords or tags (R-4501) by copying
every stream unchanged (`ffmpeg -map 0 -c copy`), so that nothing is re-encoded and nothing the camera wrote is lost?
Until this is recorded, metadata edits are offered for photos only.

Status: waiting for sample files from the person (real files matter: cameras write tracks a generated file lacks).

## Sample files wanted (copies, in one folder)
- An iPhone video (MOV), ideally HDR, with a location.
- An iPhone Live Photo's clip (the MOV beside a HEIC); it carries a still-image-time metadata track (`mebx`).
- A GoPro (or other action camera) MP4, with its telemetry track (`gpmd`) and timecode.
- Two or three tagged MP3s: with cover art, lyrics, a rating (POPM), private frames (PRIV), and one with an ID3v1 tag.
- An Ogg or Opus file with cover art; an M4A with cover art; a FLAC with tags.

## Method (to run on those copies)
1. `ffprobe -show_streams -show_format` of each, saved as the "before".
2. A rewrite of one tag with the bundled ffmpeg: `-map 0 -c copy -map_metadata 0 -movflags use_metadata_tags`
   (video), `-map 0 -c copy -id3v2_version 3 -write_id3v1 1` (MP3), plus the edited key.
3. Compare: stream count and types; `framemd5` of every stream before and after (must be identical); every tag before
   and after (only the edited one may differ); the location (ISO 6709 `©xyz`) still there; the Live Photo still pairs
   with its HEIC in Photos; the GoPro telemetry still read by its own tools.

## What each result decides
- All identical: video and audio edits use `FFmpeg.rewriteTags` with this check on every write (as photos do).
- A track or tag lost (for example `mebx`, `gpmd`, ID3 PRIV): that format is refused for in-file edits with the reason
  and offered a `.xmp` beside it instead; or, for MOV/MP4, a small Swift atom editor that rewrites only `moov/udta` and
  `moov/meta` is prototyped and tested the same way.
- Ogg with cover art: refused for in-file edits unless the check passes.
