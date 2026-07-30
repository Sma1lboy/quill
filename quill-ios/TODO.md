# quill-ios · roadmap

## In flight
- [ ] **Model bake-off** (#15) — base/small/large-v3-turbo on-device compare,
      running now; pick default from real numbers.
- [ ] **Live Activity** (#16) — lock-screen card + Dynamic Island while
      recording: elapsed mono timer, breathing waveform, terracotta on the
      island. Custom quill animations (the "cute" factor): feather-drawing
      progress, bracket-chip pulse. Needs a Widget Extension target.

## Worth doing next (proposed)
- [ ] **Playback** — play mic.caf in the session screen (AVPlayer + seek by
      tapping a transcript segment; segments are timestamped already).
- [x] **Search** — case/diacritic-insensitive substring over transcript.json
      across sessions; results jump to the segment.
- [ ] **Session actions** — rename (title in meta.json), delete (with
      confirmation), share the whole folder as a zip.
- [ ] **Auto-title** — FoundationModels one-liner per session replacing
      "Today 7:05 PM" with a content title ("weekly planning · pricing").
- [ ] **Image understanding** (#14) — Vision/FoundationModels captioning of
      images/, woven into notes.md by the enhance pass.
- [ ] **Onboarding** — first-launch card: what quill is, mic permission ask,
      model download explainer (in brand voice, not a system alert).
- [ ] **App icon** — feather glyph on porcelain/terracotta, light+dark+tinted
      variants.
- [ ] **Mac handoff** — same folder schema as quill-app; sync via iCloud
      Drive folder so desktop `claude -p` can enhance phone sessions.

## Settled decisions
- Whisper (WhisperKit) for STT — multilingual incl. zh, fully local.
- zh-Hans/zh-Hant via ICU transform post-pass (whisper only knows "zh").
- Language setting is a multi-select allow-set; empty = auto.
- Notes structuring: Apple FoundationModels on-device; EnhanceService seam
  for a server backend if quality tops out.
- Recordings are user-owned folders under Documents (Files-visible).
