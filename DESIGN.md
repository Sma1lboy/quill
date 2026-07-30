# quill design language

Locked 2026-07-29 after review round 3
(https://brand-studio.sma1lboy.me/s/quill-app-ui). quill is a sibling of
kobe and inherits its design DNA — palette values come from
`kobe/packages/branding/src/colors.ts` and must not drift independently.
This file is the truth source for every quill surface (macOS popover, iOS
app, future web).

## Identity

- **Family**: warm porcelain paper, espresso ink, terracotta as the single
  brand-defining accent. Terminal-native voice: mono kickers, bracket-chip
  wordmark, compressed copy.
- **Wordmark**: `[ quill ]` — brackets in accent, word in ink, mono bold.
  The kobe `[Tab]` hotkey grammar; reads as a thing you can press.
- **Surfaces are matte, not glass.** Solid paper backgrounds. No
  `.regularMaterial`/blur chrome — the warm palette dies under a
  desaturating blur.
- **Terracotta never means "error".** Error has its own red slot.

## Tokens

| Token | Light (porcelain) | Dark (Claude-port) | Use |
|---|---|---|---|
| paper | `#F6F3EC` | `#141413` | app background |
| surface | `#FDFCF9` | `#1A1917` | cards, idle buttons |
| inset | `#EFEAE0` | `#2B2A27` | banners, footers |
| line | `#DFD8CB` | `#3A3835` | hairlines, borders |
| ink | `#3B322A` | `#EAE7DF` | primary text |
| muted | `#7C7266` | `#A9A39A` | secondary text |
| accent | `#C46B48` | `#CC785C` | terracotta — recording state, brackets, hover tint |
| accentSoft | accent @ 10% | accent @ 14% | hover/selection wash |
| error | `#B65742` | `#D47563` | failures only |

Radius: 8pt standard, 6pt small rows, continuous corners always.

## Type

- **Mono carries structure**: labels, numbers, kickers, stage tags,
  wordmark. System monospaced (SF Mono) on Apple platforms; JetBrains Mono
  stack on web.
- **System face carries prose**: session titles, transcript text.
- **Kicker**: uppercase mono 10pt medium, +1.2 tracking, muted —
  `LOCAL · ON-DEVICE`, `RECENT`.
- **Stage tags**: fixed-width mono column (`NOTE` / `TXT` / `AUD`), accent
  when fully processed, muted otherwise. Never icons.
- Numbers are always `monospacedDigit`.

## Motion (apple-design skill rules)

- Springs critically damped (`response 0.3–0.4, damping 1.0`) — nothing in
  quill carries momentum, so no bounce anywhere.
- Press feedback on pointer-down: scale 0.97, spring response 0.25.
- State morphs happen in place along the same path (record dot ↔ stop
  square).
- Timers use `contentTransition(.numericText())`.
- Live level = 15fps linear follow, sqrt-lifted so quiet speech is visible.
- `Reduce Motion` → everything degrades to 150ms ease-out fades.

## Component grammar

- **Record control**: one full-width pressable bar, 40pt (macOS) / 56pt
  (iOS). Idle: surface fill, line border, accent dot + `start recording`
  mono label. Recording: whole bar flips to accent, dot morphs to stop
  square, elapsed mono timer + live waveform (5 desynced capsules,
  weights 0.5/0.9/1.0/0.7/0.45) + `STOP` kicker.
- **Header**: bracket-chip wordmark left; right side is the `LOCAL ·
  ON-DEVICE` kicker at rest, `● REC` in accent while recording.
- **Session rows**: stage tag column → title (`Today 09:30`,
  `Yesterday 14:00`, else `Mon, Jul 28 · 09:30`) → right-aligned mono
  duration. Hover/press = accentSoft wash, radius 6.
- **Pipeline banner**: inset fill, mini spinner tinted accent, mono
  lowercase status (`transcribing 2026.07.29-0930 · 1 queued`).
- **Empty states**: two mono lines, compressed voice, sell local-first
  ("~/Recordings is empty / sessions land here as folders you own").
- **Footer**: inset @ 50%, mono path button (`~/Recordings`) left, `quit`
  right; hover flips to accent + wash.

## Voice

Technical, compressed, lowercase-leaning (`start recording`, `quit`,
`transcribing …`). Kickers uppercase. No exclamation marks, no emoji, no
"AI magic" language. Say what the machine is doing.
