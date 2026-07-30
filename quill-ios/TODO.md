# quill-ios · roadmap

## In flight
- [ ] **Model bake-off** (#15) — base/small/large-v3-turbo on-device compare,
      running now; pick default from real numbers.
- [x] **Live Activity** (#16) — lock-screen card + Dynamic Island, both
      phases (recording: mono timer + waveform; transcribing: spinner +
      percentage), all four presentations, stale-card cleanup at launch.
      Still missing the "cute" factor from the original note: feather-drawing
      progress and bracket-chip pulse are not built (a Live Activity can only
      animate what the system redraws, so those need a rethink).

## Worth doing next (proposed)
- [x] **Playback** — mic.caf in the session screen: play/pause, drag scrub,
      seek by tapping a transcript segment, playing segment marked. Stands
      down while a take is recording (shared AVAudioSession). No rate control
      or skip buttons — add if the 1:1 scrub proves not enough.
- [x] **Search** — case/diacritic-insensitive substring over transcript.json
      across sessions; results jump to the segment.
- [x] **Session actions** — rename (title in meta.json), delete (with
      confirmation), share the whole folder as a zip.
- [x] **Auto-title** — FoundationModels one-liner per session replacing
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
