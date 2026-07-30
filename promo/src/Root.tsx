import { Composition } from "remotion";
import { QuillPromo } from "./QuillPromo";

export const Root: React.FC = () => (
  <Composition
    id="QuillPromo"
    component={QuillPromo}
    durationInFrames={450} // 15s @ 30fps
    fps={30}
    width={1920}
    height={1080}
  />
);
