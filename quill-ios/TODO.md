# quill-ios · roadmap

## Shipped
- [x] **Model bake-off** (#15) — base/small/large-v3-turbo compared on device
      (`benchmark.md`); large-v3 turbo won on zh accuracy and punctuation and
      is the default.
- [x] **Live Activity** (#16) — lock-screen card + Dynamic Island, both
      phases (recording: mono timer + waveform; transcribing: spinner +
      percentage), all four presentations, stale-card cleanup at launch.
      Still missing the "cute" factor from the original note: feather-drawing
      progress and bracket-chip pulse are not built (a Live Activity can only
      animate what the system redraws, so those need a rethink).
- [x] **Playback** — mic.caf in the session screen: play/pause, drag scrub,
      seek by tapping a transcript segment, playing segment marked. Stands
      down while a take is recording (shared AVAudioSession). No rate control
      or skip buttons — add if the 1:1 scrub proves not enough.
- [x] **Search** — case/diacritic-insensitive substring over transcript.json
      across sessions; results jump to the segment.
- [x] **Session actions** — rename (title in meta.json), delete (with
      confirmation), share the whole folder as a zip, export the audio alone
      as m4a (Voice Memos, a DAW, AirDrop to the Mac — CAF opens almost
      nowhere), re-transcribe from the audio, re-run the notes pass.
- [x] **Auto-title** — FoundationModels one-liner per session replacing
      "Today 7:05 PM" with a content title ("weekly planning · pricing").
- [x] **Image understanding** (#14) — Vision OCR over images/, cached in the
      session folder as ocr.json, fed to the enhance prompt as context (never
      dumped into notes.md). No FoundationModels captioning of textless
      photos — Vision covers the whiteboard/slide case that matters.
- [x] **Onboarding** — first-launch page: what quill is, on-device pitch, the
      model download explained in brand voice before iOS's mic alert, and a
      card that tracks the permission state. One page, no wizard.
- [x] **App icon** — feather glyph, light+dark+tinted variants.

## Worth doing next (proposed)
- [ ] **Mac handoff** — iCloud sync investigated and deferred: the folder
      contract is portable as-is, so share-as-zip + AirDrop is the shipping
      path. iOS declines multi-track (mic + system) sessions so the Mac still
      owns transcribing its own recordings.

## Settled decisions
- Whisper (WhisperKit) for STT — multilingual incl. zh, fully local.
- zh-Hans/zh-Hant via ICU transform post-pass (whisper only knows "zh").
- Language setting is a multi-select allow-set; empty = auto.
- Notes structuring: Apple FoundationModels on-device; EnhanceService seam
  for a server backend if quality tops out.
- Recordings are user-owned folders under Documents (Files-visible).
- The filesystem is the transcription queue; automatic attempts cap at 3
  (`transcribe_failures` in meta.json), then only the manual retry re-queues.
- Deleting moves the folder to Documents/.trash, purged after 7 days.
- Model weights are excluded from iCloud backup; recordings are not. A
  TestFlight install over an existing one keeps Documents either way — the
  exclusion is about not blowing the user's quota (and not failing the
  backup that carries the recordings) on 4.3 GB we can re-download.
- Re-transcribe clears transcript + partial + notes and re-queues; it
  refuses (touching nothing) on a session the queue wouldn't take back.
  Re-running notes restores the previous notes.md if the whole chain fails.
