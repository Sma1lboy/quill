import Foundation
@preconcurrency import FluidAudio

/// Speaker separation over a finished recording: FluidAudio's offline
/// diarizer (pyannote-family Core ML models, ~50 MB one-time download)
/// clusters voice embeddings into speakers, then whisper segments get
/// relabeled "me" → "S1"/"S2"/… by time overlap.
///
/// Single-voice recordings stay "me" (no relabel when one cluster covers
/// everything). Best-effort: any failure leaves the transcript untouched.
enum Diarizer {
    /// Speaker turns for the audio file, sorted by start time.
    static func speakerTurns(for audio: URL) async throws -> [(speaker: String, start: Double, end: Double)] {
        let manager = OfflineDiarizerManager()
        try await manager.prepareModels()
        let result = try await manager.process(audio)
        return result.segments
            .map { (speaker: $0.speakerId, start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds)) }
            .sorted { $0.start < $1.start }
    }

    /// Relabel transcript segments with speaker IDs by midpoint lookup.
    /// Returns nil when diarization found ≤1 speaker (keep "me").
    static func relabel(
        segments: [Transcript.Segment],
        turns: [(speaker: String, start: Double, end: Double)]
    ) -> [Transcript.Segment]? {
        let speakers = Set(turns.map(\.speaker))
        guard speakers.count > 1 else { return nil }

        // Stable display names in order of first appearance: S1, S2, …
        var names: [String: String] = [:]
        for turn in turns where names[turn.speaker] == nil {
            names[turn.speaker] = "S\(names.count + 1)"
        }

        return segments.map { seg in
            let mid = Double(seg.start_ms + seg.end_ms) / 2000.0
            // The turn covering the midpoint; else the nearest turn.
            let covering = turns.first { $0.start <= mid && mid <= $0.end }
                ?? turns.min { min(abs($0.start - mid), abs($0.end - mid)) < min(abs($1.start - mid), abs($1.end - mid)) }
            guard let covering else { return seg }
            return Transcript.Segment(
                speaker: names[covering.speaker] ?? seg.speaker,
                start_ms: seg.start_ms,
                end_ms: seg.end_ms,
                text: seg.text
            )
        }
    }
}
