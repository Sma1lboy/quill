# whisper model bake-off

audio: 2026.07.29-2301/mic.caf

## base (openai_whisper-base)

- load: 2.8s (incl. download if any)
- transcribe: 0.2s
- language: zh

> 今天下午和團隊開會討論了新的錄音功能 決定先做快速錄音 以及模式下週再上線

## small (openai_whisper-small)

- load: 2.8s (incl. download if any)
- transcribe: 0.6s
- language: zh

> 今天下午和团队开会讨论了新的录音功能,决定先做快速录音,你进模式下周再上线。

## large-v3 turbo (openai_whisper-large-v3_turbo)

- load: 3.6s (incl. download if any)
- transcribe: 3.0s
- language: zh

> 今天下午和团队开会讨论了新的录音功能,决定先做快速录音,米记模式下周再上线。
