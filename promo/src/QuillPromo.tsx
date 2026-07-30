import {
  AbsoluteFill,
  Img,
  interpolate,
  spring,
  staticFile,
  useCurrentFrame,
  useVideoConfig,
} from "remotion";

// quill promo — 15s, kobe grammar throughout: porcelain paper + dot field,
// terracotta accent, mono chrome, Fraunces-style serif display (system
// serif fallback keeps render hermetic). Motion follows apple-design:
// critically damped springs, no bounce.
//
// Beats (frames @30fps, matching the constants below — the phones stagger 1s
// apart and then all three hold, they don't hand off in 3s windows):
//         0.2-2.7s   [ quill ] wordmark types in, then shrinks + fades out
//         3.3s       phone 1 slides up: record (home)
//         4.3s       phone 2: transcript w/ speakers
//         5.3s       phone 3: structured note
//         10.7s      captions fade
//         11.0-15s   tagline + repo

const paper = "#F6F3EC";
const ink = "#3B322A";
const inkSoft = "#5C5248";
const faint = "#8A7F71";
const accent = "#C46B48";
const mono = "'JetBrains Mono', 'SF Mono', Menlo, monospace";
const serif = "'Fraunces', Georgia, 'Times New Roman', serif";

const DotField: React.FC = () => (
  <AbsoluteFill
    style={{
      backgroundImage: "radial-gradient(rgba(160,140,110,.35) 2px, transparent 2px)",
      backgroundSize: "42px 42px",
    }}
  />
);

const Glow: React.FC = () => (
  <div
    style={{
      position: "absolute",
      right: -300,
      bottom: -420,
      width: 1100,
      height: 950,
      background: "radial-gradient(closest-side, rgba(201,113,79,.20), transparent 70%)",
    }}
  />
);

// Typed-in wordmark with blinking caret (kobe BracketChip grammar).
const Wordmark: React.FC<{ start: number; exitAt?: number }> = ({ start, exitAt }) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const word = "quill";
  const chars = Math.max(0, Math.floor((frame - start - 14) / 4));
  const typed = word.slice(0, Math.min(chars, word.length));
  const caretOn = Math.floor(frame / 10) % 2 === 0;

  const leftIn = spring({ frame: frame - start, fps, config: { damping: 200 } });
  const rightIn = spring({ frame: frame - start - 5, fps, config: { damping: 200 } });

  const exit = exitAt
    ? interpolate(frame, [exitAt, exitAt + 20], [1, 0], {
        extrapolateLeft: "clamp",
        extrapolateRight: "clamp",
      })
    : 1;
  const rise = exitAt
    ? interpolate(frame, [exitAt, exitAt + 20], [0, -60], {
        extrapolateLeft: "clamp",
        extrapolateRight: "clamp",
      })
    : 0;

  return (
    <div
      style={{
        display: "flex",
        alignItems: "baseline",
        gap: 28,
        opacity: exit,
        transform: `translateY(${rise}px)`,
      }}
    >
      <span
        style={{
          fontFamily: mono,
          fontWeight: 700,
          fontSize: 150,
          color: accent,
          opacity: leftIn,
          transform: `translateX(${interpolate(leftIn, [0, 1], [-70, 0])}px)`,
        }}
      >
        [
      </span>
      <span
        style={{
          fontFamily: serif,
          fontWeight: 400,
          fontSize: 190,
          color: ink,
          letterSpacing: "-0.02em",
          minWidth: 470,
          textAlign: "center",
        }}
      >
        {typed}
        <span
          style={{
            display: "inline-block",
            width: 14,
            height: 130,
            marginLeft: 10,
            verticalAlign: "-12px",
            background: accent,
            opacity: caretOn && chars <= word.length + 4 ? 1 : 0,
          }}
        />
      </span>
      <span
        style={{
          fontFamily: mono,
          fontWeight: 700,
          fontSize: 150,
          color: accent,
          opacity: rightIn,
          transform: `translateX(${interpolate(rightIn, [0, 1], [70, 0])}px)`,
        }}
      >
        ]
      </span>
    </div>
  );
};

// One phone beat: slides up with a caption; slides on to its slot.
const PhoneBeat: React.FC<{
  src: string;
  caption: string;
  sub: string;
  start: number;
  x: number;
}> = ({ src, caption, sub, start, x }) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const enter = spring({ frame: frame - start, fps, config: { damping: 200 }, durationInFrames: 34 });
  const y = interpolate(enter, [0, 1], [900, 0]);
  // Captions hand the floor to the closing tagline.
  const captionOut = interpolate(frame, [320, 340], [1, 0], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
  });

  return (
    <div
      style={{
        position: "absolute",
        left: x,
        top: 130,
        width: 420,
        transform: `translateY(${y}px)`,
        opacity: enter,
        display: "flex",
        flexDirection: "column",
        alignItems: "center",
        gap: 26,
      }}
    >
      <Img src={src} style={{ width: 420 }} />
      <div style={{ textAlign: "center", opacity: captionOut }}>
        <div style={{ fontFamily: mono, fontSize: 25, fontWeight: 700, color: accent, letterSpacing: ".04em" }}>
          {caption}
        </div>
        <div style={{ fontFamily: mono, fontSize: 19, color: faint, marginTop: 8 }}>{sub}</div>
      </div>
    </div>
  );
};

const Tagline: React.FC<{ start: number }> = ({ start }) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const inSpring = spring({ frame: frame - start, fps, config: { damping: 200 } });

  return (
    <AbsoluteFill
      style={{
        alignItems: "center",
        justifyContent: "flex-end",
        paddingBottom: 64,
        opacity: inSpring,
      }}
    >
      <div style={{ textAlign: "center", transform: `translateY(${interpolate(inSpring, [0, 1], [40, 0])}px)` }}>
        <div style={{ fontFamily: serif, fontSize: 44, color: ink }}>
          record → transcribe → <span style={{ color: accent, fontStyle: "italic" }}>notes</span> · all on your device
        </div>
        <div style={{ fontFamily: mono, fontSize: 24, color: faint, marginTop: 14 }}>
          no cloud · no account · github.com/Sma1lboy/quill
        </div>
      </div>
    </AbsoluteFill>
  );
};

export const QuillPromo: React.FC = () => {
  const frame = useCurrentFrame();

  // Wordmark holds center stage, then rises away as phones arrive.
  const wordmarkCenter = interpolate(frame, [80, 110], [0, -320], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
  });
  const wordmarkScale = interpolate(frame, [80, 110], [1, 0.42], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
  });

  return (
    <AbsoluteFill style={{ background: paper }}>
      <DotField />
      <Glow />

      <AbsoluteFill style={{ alignItems: "center", justifyContent: "center" }}>
        <div style={{ transform: `translateY(${wordmarkCenter}px) scale(${wordmarkScale})` }}>
          {/* exitAt was implemented in Wordmark but never passed, so the mark
              only shrank to 0.42 and parked at y-320 — which is exactly behind
              phone 2 — staying there through the tagline. Fading it on the same
              80→110 window the shrink already uses hands the frame to the
              phones instead of leaving a fragment under one. */}
          <Wordmark start={6} exitAt={80} />
        </div>
      </AbsoluteFill>

      <PhoneBeat
        src={staticFile("home-light-framed.png")}
        caption="RECORD"
        sub="one tap · pause anytime"
        start={100}
        x={210}
      />
      <PhoneBeat
        src={staticFile("transcript-light-framed.png")}
        caption="TRANSCRIBE"
        sub="whisper on-device · speakers split"
        start={130}
        x={750}
      />
      <PhoneBeat
        src={staticFile("detail-light-framed.png")}
        caption="NOTES"
        sub="apple intelligence · auto-titled"
        start={160}
        x={1290}
      />

      <Tagline start={330} />
    </AbsoluteFill>
  );
};
