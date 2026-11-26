import { useCallback, useEffect, useRef, useState, type ReactNode } from "react";
import { animate, motion, useMotionValue, useMotionValueEvent, type MotionValue } from "motion/react";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { Sidebar } from "./Sidebar";
import { CleanDetail, CleanSidebar, type Tool } from "./CleanSpace";
import { TerminalSidebar } from "./TerminalSidebar";
import { TerminalDetail } from "./TerminalDetail";
import { TerminalDialogs } from "./Dialogs";
import { TerminalModel } from "./terminalModel";
import { loadSpace, saveSpace, SPACE_SPRING, SPACES, spaceIndex, type SpaceId } from "./spaces";
import { matchShortcut, type Action } from "./shortcuts";

export const terminal = new TerminalModel();

export function App() {
  const [space, setSpace] = useState<SpaceId>(loadSpace);
  const [tool, setTool] = useState<Tool>("cleaner");
  const direction = useRef(1);
  const swipe = useMotionValue(0);

  const go = useCallback((next: SpaceId) => {
    setSpace((current) => {
      direction.current = spaceIndex(next) >= spaceIndex(current) ? 1 : -1;
      saveSpace(next);
      return next;
    });
  }, []);

  const perform = useCallback(
    (action: Action | string) => {
      switch (action) {
        case "newTab":
          go("terminal");
          terminal.newTab();
          break;
        case "closeTab":
          if (space === "terminal") terminal.closeSelected();
          break;
        case "nextTab":
          if (space === "terminal") terminal.selectAdjacent(1);
          break;
        case "prevTab":
          if (space === "terminal") terminal.selectAdjacent(-1);
          break;
        case "newGroup":
          go("terminal");
          terminal.edit({ kind: "newGroup" });
          break;
        case "space:clean":
        case "space:terminal":
          go(action.slice(6) as SpaceId);
          break;
        case "space:next":
        case "space:prev": {
          const i = spaceIndex(space) + (action === "space:next" ? 1 : -1);
          go(SPACES[(i + SPACES.length) % SPACES.length].id);
          break;
        }
      }
    },
    [space, go],
  );

  // Page shortcuts (all of them on Windows/Linux; macOS uses the menu bar).
  useEffect(() => {
    terminal.isShortcut = (e) => matchShortcut(e) !== undefined;
    const onKey = (e: KeyboardEvent) => {
      const action = matchShortcut(e);
      if (!action) return;
      e.preventDefault();
      e.stopPropagation();
      perform(action);
    };
    window.addEventListener("keydown", onKey, true);
    return () => window.removeEventListener("keydown", onKey, true);
  }, [perform]);

  // macOS menu bar items.
  useEffect(() => {
    const off = listen<string>("clearspace://menu", (e) => perform(e.payload));
    return () => void off.then((f) => f());
  }, [perform]);

  // Quit, window close, logout or restart: save everything first.
  useEffect(() => {
    const off = listen("clearspace://save-and-quit", async () => {
      await terminal.saveEverything().catch(() => {});
      await invoke("saved_for_quit");
    });
    return () => void off.then((f) => f());
  }, []);

  return (
    <div className="app">
      <Sidebar
        space={space}
        onSpace={go}
        swipe={swipe}
        pages={{
          clean: <CleanSidebar tool={tool} onTool={setTool} />,
          terminal: <TerminalSidebar model={terminal} />,
        }}
      />
      <DetailStack space={space} swipe={swipe} direction={direction.current}>
        {{
          clean: <CleanDetail tool={tool} />,
          terminal: <TerminalDetail model={terminal} active={space === "terminal"} />,
        }}
      </DetailStack>
      <TerminalDialogs model={terminal} />
    </div>
  );
}

/**
 * Every space's page stays mounted (shells keep running); the current one is shown. While a swipe
 * heads toward another space the page dims and drifts with the fingers; on a switch the new page
 * slides in from the side it came from.
 */
function DetailStack({
  space,
  swipe,
  direction,
  children,
}: {
  space: SpaceId;
  swipe: MotionValue<number>;
  direction: number;
  children: Record<SpaceId, ReactNode>;
}) {
  const opacity = useMotionValue(1);
  const drift = useMotionValue(0);
  const index = spaceIndex(space);

  useMotionValueEvent(swipe, "change", (p) => {
    const towardNeighbour = (p < 0 && index < SPACES.length - 1) || (p > 0 && index > 0) ? Math.min(Math.abs(p), 1) : 0;
    opacity.set(1 - towardNeighbour * 0.35);
    drift.set(Math.sign(p) * towardNeighbour * 32);
  });

  return (
    <motion.main className="detail" style={{ opacity, x: drift }}>
      {SPACES.map((s) => (
        <DetailPane key={s.id} active={s.id === space} direction={direction}>
          {children[s.id]}
        </DetailPane>
      ))}
    </motion.main>
  );
}

function DetailPane({ active, direction, children }: { active: boolean; direction: number; children: ReactNode }) {
  const x = useMotionValue(0);
  const opacity = useMotionValue(active ? 1 : 0);
  const [visible, setVisible] = useState(active);
  const first = useRef(true);

  useEffect(() => {
    if (first.current) {
      first.current = false;
      return;
    }
    if (active) {
      setVisible(true);
      x.set(direction * 60);
      animate(x, 0, SPACE_SPRING);
      animate(opacity, 1, { duration: 0.22, ease: "easeOut" });
    } else {
      animate(opacity, 0, { duration: 0.14, ease: "easeIn" }).then(() => setVisible(false));
    }
  }, [active]);

  return (
    <motion.section
      className="detail-pane"
      style={{ x, opacity, visibility: visible ? "visible" : "hidden", pointerEvents: active ? "auto" : "none", zIndex: active ? 1 : 0 }}
      aria-hidden={!active}
    >
      {children}
    </motion.section>
  );
}
