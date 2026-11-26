import { useEffect, useLayoutEffect, useRef, useState, type ReactNode } from "react";
import { animate, motion, useMotionValue, useTransform, type MotionValue } from "motion/react";
import { WheelGestures } from "wheel-gestures";
import { SPACE_SPRING, SPACES, spaceIndex, type SpaceId } from "./spaces";
import { shortcutLabel } from "./shortcuts";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { isMac } from "./platform";

/**
 * Arc-style sidebar: every space's sidebar sits side by side and the strip follows a two-finger
 * swipe, rubber-bands at the ends, and springs to the nearest space when the fingers lift.
 * `swipe` reports the live drag in sidebar widths (negative = toward the next space) so the
 * detail pane can react too.
 */
export function Sidebar({
  space,
  onSpace,
  swipe,
  pages,
}: {
  space: SpaceId;
  onSpace: (id: SpaceId) => void;
  swipe: MotionValue<number>;
  pages: Record<SpaceId, ReactNode>;
}) {
  const viewport = useRef<HTMLDivElement>(null);
  const [width, setWidth] = useState(240);
  const index = spaceIndex(space);
  const x = useMotionValue(-index * width);
  const [dragging, setDragging] = useState(false);

  // Latest values for the gesture handler, which is set up once.
  const live = useRef({ index, width, onSpace });
  live.current = { index, width, onSpace };
  const settlingTo = useRef<number | null>(null);

  // Measured before the first paint, then on every resize.
  useLayoutEffect(() => {
    const el = viewport.current;
    if (!el) return;
    const measure = () => setWidth(Math.max(1, el.clientWidth));
    measure();
    const observer = new ResizeObserver(measure);
    observer.observe(el);
    return () => observer.disconnect();
  }, []);

  // A resize jumps straight to the current page (stopping any spring still aiming at the old width).
  useLayoutEffect(() => {
    trace(`width ${width} index=${live.current.index}`);
    x.stop();
    x.set(-live.current.index * width);
  }, [width]);

  // Clicks and shortcuts glide to the new page; a swipe already started its own spring.
  const mounted = useRef(false);
  useEffect(() => {
    if (!mounted.current) {
      mounted.current = true;
      return;
    }
    trace(`index effect index=${index} settlingTo=${settlingTo.current}`);
    if (settlingTo.current === index) {
      settlingTo.current = null;
      return;
    }
    animate(x, -index * live.current.width, SPACE_SPRING);
    animate(swipe, 0, SPACE_SPRING);
  }, [index]);

  // One swipe: `begin` when the fingers start moving sideways, `drag` as they move, `settle` when they lift.
  const gesture = useRef({ active: false, offset: 0, last: 0 });
  const begin = () => {
    const { index, width } = live.current;
    // Grabbing the strip mid-spring continues from where it is instead of jumping.
    x.stop();
    swipe.stop();
    gesture.current = { active: true, offset: x.get() + index * width, last: 0 };
    setDragging(true);
    trace(`start index=${index} offset=${Math.round(gesture.current.offset)}`);
  };
  const drag = (mx: number) => {
    if (!gesture.current.active) begin();
    gesture.current.last = mx;
    const { index, width } = live.current;
    const shown = rubberBand(gesture.current.offset + mx, index, width);
    x.set(-index * width + shown);
    swipe.set(shown / width);
  };
  /** `velocity` is the fingers' speed when they lifted, in px per second (0 if they rested first). */
  const settle = (mx: number, velocity: number) => {
    if (!gesture.current.active) return;
    gesture.current.active = false;
    setDragging(false);
    const { index, width } = live.current;
    // Go to the neighbour if the swipe, plus where its flick would carry it, passed 40%.
    const projected = gesture.current.offset + mx + velocity * 0.18;
    let target = index;
    if (projected < -width * 0.4 && index < SPACES.length - 1) target += 1;
    if (projected > width * 0.4 && index > 0) target -= 1;
    trace(`settle mx=${Math.round(mx)} v=${Math.round(velocity)} index=${index} target=${target}`);
    animate(x, -target * width, { ...SPACE_SPRING, velocity });
    animate(swipe, 0, SPACE_SPRING);
    if (target !== index) {
      settlingTo.current = target;
      live.current.onSpace(SPACES[target].id);
    }
  };
  const handlers = useRef({ drag, settle });
  handlers.current = { drag, settle };

  // A swipe cut short (the window lost focus mid-gesture) still lands on a page.
  useEffect(() => {
    const onBlur = () => gesture.current.active && handlers.current.settle(gesture.current.last, 0);
    window.addEventListener("blur", onBlur);
    return () => window.removeEventListener("blur", onBlur);
  }, []);

  // macOS: the trackpad's real phases come from AppKit (see swipe.rs), so the snap happens the
  // moment the fingers lift, carrying their exact speed.
  useEffect(() => {
    if (!isMac) return;
    const aside = viewport.current?.closest("aside");
    if (!aside) return;
    const report = () => {
      const r = aside.getBoundingClientRect();
      void invoke("swipe_region", { x: r.left, y: r.top, width: r.width, height: r.height });
    };
    report();
    const observer = new ResizeObserver(report);
    observer.observe(aside);
    window.addEventListener("resize", report);
    const off = listen<{ kind: "change"; dx: number } | { kind: "end"; dx: number; velocity: number }>("clearspace://swipe", ({ payload }) => {
      if (payload.kind === "change") handlers.current.drag(payload.dx);
      else handlers.current.settle(payload.dx, payload.velocity);
    });
    return () => {
      observer.disconnect();
      window.removeEventListener("resize", report);
      void off.then((f) => f());
    };
  }, []);

  // Windows and Linux: the web view only sees wheel events, so the lift is inferred.
  useEffect(() => {
    const el = viewport.current;
    if (!el || isMac) return;
    const gestures = WheelGestures({ preventWheelAction: "x" });
    gestures.observe(el);
    let axis: "none" | "x" | "y" = "none";
    let done = false;

    gestures.on("wheel", (state) => {
      if (state.isStart) {
        axis = "none";
        done = false;
      }
      if (done) return;
      const [mx, my] = state.axisMovement;
      if (axis === "none" && Math.hypot(mx, my) > 6) axis = Math.abs(mx) > Math.abs(my) * 1.2 ? "x" : "y";
      if (axis !== "x") return;
      // Coasting means the fingers flicked and lifted: carry their speed. Silence means they rested.
      if (state.isMomentum || state.isEnding) {
        done = true;
        handlers.current.settle(mx, state.isMomentum ? state.axisVelocity[0] * 1000 : 0);
        return;
      }
      handlers.current.drag(mx);
    });

    return () => gestures.disconnect();
  }, []);

  return (
    <aside className="sidebar">
      <SpaceTints x={x} width={width} />
      <div className="sidebar-titlebar" data-tauri-drag-region />
      <div className="pager" ref={viewport}>
        <motion.div className="pager-strip" style={{ x, width: width * SPACES.length }}>
          {SPACES.map((s) => (
            <div
              key={s.id}
              className="pager-page"
              style={{ width, pointerEvents: s.id === space && !dragging ? "auto" : "none" }}
              aria-hidden={s.id !== space}
              inert={s.id !== space}
            >
              {pages[s.id]}
            </div>
          ))}
        </motion.div>
      </div>
      <SpaceSwitcher space={space} onSpace={onSpace} />
    </aside>
  );
}

/** Self-test trace of swipe decisions (only when the self-test creates the array). */
const trace = (line: string) => (window as { __swipeTrace?: string[] }).__swipeTrace?.push(`${Math.round(performance.now())} ${line}`);

/** Free between pages; past the first or last page it resists, like iOS scroll views. */
function rubberBand(movement: number, index: number, width: number) {
  const pastEdge = (index === 0 && movement > 0) || (index === SPACES.length - 1 && movement < 0);
  if (!pastEdge) return Math.max(-width, Math.min(width, movement));
  const d = Math.abs(movement) / width;
  return Math.sign(movement) * (1 - 1 / (d * 0.55 + 1)) * width;
}

/** Each space's tint fades in as its page slides into view. */
function SpaceTints({ x, width }: { x: MotionValue<number>; width: number }) {
  return (
    <>
      {SPACES.map((s, i) => (
        <SpaceTint key={s.id} x={x} width={width} i={i} tint={s.tint} />
      ))}
    </>
  );
}

function SpaceTint({ x, width, i, tint }: { x: MotionValue<number>; width: number; i: number; tint: string }) {
  const opacity = useTransform(x, (v) => Math.max(0, 1 - Math.abs(-v / width - i)));
  return <motion.div className="sidebar-tint" style={{ opacity, ["--tint" as string]: tint }} />;
}

/** The space buttons at the bottom of the sidebar; the highlight pill glides to the current one. */
function SpaceSwitcher({ space, onSpace }: { space: SpaceId; onSpace: (id: SpaceId) => void }) {
  return (
    <nav className="space-switcher">
      {SPACES.map((s) => {
        const selected = s.id === space;
        const Icon = s.icon;
        return (
          <button
            key={s.id}
            className={"space-button" + (selected ? " selected" : "")}
            style={{ ["--tint" as string]: s.tint }}
            onClick={() => onSpace(s.id)}
            title={`${s.title} (${shortcutLabel(`space:${s.id}`)})`}
          >
            {selected && <motion.span layoutId="space-pill" className="space-pill" transition={SPACE_SPRING} />}
            <Icon size={15} strokeWidth={2} className="space-icon" />
            {selected && (
              <motion.span
                className="space-title"
                initial={{ opacity: 0, scale: 0.85 }}
                animate={{ opacity: 1, scale: 1 }}
                transition={{ duration: 0.2 }}
              >
                {s.title}
              </motion.span>
            )}
          </button>
        );
      })}
    </nav>
  );
}
