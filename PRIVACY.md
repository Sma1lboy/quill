# Privacy Policy — quill for iPhone

Last updated: 8 August 2026

**quill does not collect any data.** There is no account, no analytics, no
crash reporting, no advertising, and no server that belongs to us. This
document exists because the App Store requires one, and because "we collect
nothing" is a claim you should be able to check.

## What stays on your device

Every recording session is a plain folder inside quill's own Documents
directory on your iPhone, visible to you in the Files app:

- the audio you recorded (`mic.caf`)
- the transcript, as JSON and as Markdown
- the notes written from that transcript (`notes.md`)
- any images you attached, and the text recognised in them
- a small `meta.json` with the session's start time, duration and title

Transcription runs on your device, on the Neural Engine. The notes are
written by Apple's on-device foundation model, or by a Qwen model you chose
to download that also runs on your device. **Your audio is never uploaded,
because there is nowhere for it to go.**

Your settings — model choice, language restrictions, the notes prompt — are
stored locally in the app's own preferences.

## When quill uses the network

Once, per model you choose to download: the speech-recognition and notes
model weights are fetched from Hugging Face (`huggingface.co`). That is a
plain file download. Hugging Face sees the request the way any web server
sees a download — including your IP address — under
[their privacy policy](https://huggingface.co/privacy). Nothing about you,
your recordings, or your transcripts is attached to it.

If you never download an optional model, quill makes no network requests at
all.

## Microphone and photos

The microphone is used only while you are recording, and only to write audio
into the session folder you are recording. Photo or file access, if you
grant it, is used only to bring the file you picked into a session.

## Backups

Your recordings live in Documents, so they are included in your own iCloud
or Finder backup if you have backups enabled. That backup is between you and
Apple; we have no access to it. Downloaded model weights are explicitly
excluded from backup — they can be re-downloaded, and they are large enough
to hurt your quota.

## Deleting your data

Delete a session inside quill (it moves to a `.trash` folder that is purged
after 7 days), or delete the folder yourself in Files. Deleting the app
removes everything it ever wrote. Since we never received any of it, there
is nothing for you to ask us to erase.

## Children

quill collects no data from anyone, including children.

## Changes

If a future version of quill ever sends anything anywhere, this page will
say so before that version ships, and the change will be visible in the
commit history of this file.

## Contact

Open an issue at <https://github.com/Sma1lboy/quill/issues>.
