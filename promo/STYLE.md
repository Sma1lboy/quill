# quill promo style

The promotional grammar for quill — derived from DESIGN.md (kobe DNA),
applied to motion and marketing surfaces. Reuse this for every future
promo cut, banner, or landing update so the series stays comparable.

## Palette (same tokens as DESIGN.md)

| use | value |
|---|---|
| paper (bg) | `#F6F3EC` + dot field `radial-gradient(rgba(160,140,110,.35) 2px, transparent 2px)` 42px grid |
| ink (display text) | `#3B322A` |
| muted captions | `#8A7F71` |
| accent (brackets, captions, glow) | `#C46B48` |
| glow | radial `rgba(201,113,79,.20)` bottom-right |

## Type

- Display: Fraunces (serif, weight ~350, tight tracking) — system serif fallback ok
- Chrome/captions: JetBrains Mono — captions uppercase + tracked, subs lowercase
- Wordmark: `[ quill ]` — terracotta mono brackets, serif word, typed-in with caret

## Motion (apple-design rules)

- Springs critically damped (`damping: 200` in Remotion) — no bounce anywhere
- Wordmark types in (4 frames/char), brackets slide from outside
- Phones enter bottom-up, staggered 30 frames apart
- Captions fade out before the closing tagline takes the floor

## Audio

- Track family: warm/cinematic tech, beat-driven ok, never corporate EDM
- Grade: trim to length, 0.5-0.8s fade-in, ~1.4s fade-out landing on the tagline
- Loudness: loudnorm I=-17..-18, TP=-1.5 (social autoplay comfort)
- Resolved via media-use (HeyGen catalog); tracks under `.media/audio/bgm/`
- Two tracks resolved; `bgm_002` (19s, beat-driven tech launch) is the one in
  the shipped cut. `bgm_001` (20s, warm ambient) is the quieter alternate —
  keep both, the series may want the calm one.

## Renders

- 1920×1080 @ 30fps, 15s standard cut = 450 frames
- `npm run render` → `out/quill-promo.mp4` (silent), then mux the track below.
  There is no README in this directory; this file is the only promo doc.

```sh
ffmpeg -y -i out/quill-promo.mp4 -i .media/audio/bgm/bgm_002.wav \
  -filter_complex "[1:a]atrim=0:15,afade=t=in:st=0:d=0.5,afade=t=out:st=13.6:d=1.4,loudnorm=I=-17:TP=-1.5[a]" \
  -map 0:v -map "[a]" -c:v copy -c:a aac -b:a 192k -shortest out/quill-promo-music.mp4
```

## Asset inventory

- `src/QuillPromo.tsx` — the 15s three-beat composition (wordmark → 3 phones → tagline)
- `public/{home,transcript,detail}-light-framed.png` — the three device-framed
  screenshots the composition loads by name via `staticFile()`. Copies of the
  same-named files in `../site/framed/`; that directory is the source, and it
  also holds the dark + settings variants this cut doesn't use.
  ponytail: no regeneration script is checked in — the framer was a throwaway
  `/tmp/frame.py`, long gone. Re-shoot in the simulator and re-frame by hand
  if the UI moves; commit the script then if it happens twice.
- `.media/audio/bgm/bgm_00{1,2}.wav` — resolved tracks, with provenance in
  `.media/manifest.jsonl`. `.media/` and `out/` are gitignored.
- `../site/banner.png` — 1500×500 header banner
- `../site/index.html` — landing page (kobe-landing-light grammar)
