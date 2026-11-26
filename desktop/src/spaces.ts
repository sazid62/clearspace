import { Sparkles, SquareTerminal, type LucideIcon } from "lucide-react";

/** Top-level modes, like Arc's spaces. Each brings its own sidebar and tint. */
export type SpaceId = "clean" | "terminal";

export interface Space {
  id: SpaceId;
  title: string;
  icon: LucideIcon;
  /** CSS custom property holding the space's tint. */
  tint: string;
}

export const SPACES: Space[] = [
  { id: "clean", title: "Clean", icon: Sparkles, tint: "var(--teal)" },
  { id: "terminal", title: "Terminal", icon: SquareTerminal, tint: "var(--purple)" },
];

export const spaceIndex = (id: SpaceId) => Math.max(0, SPACES.findIndex((s) => s.id === id));

/**
 * One spring for every space change — click, shortcut or swipe. The native build's
 * spring(response: 0.42, dampingFraction: 0.86): stiffness (2π/0.42)², damping 2·0.86·√stiffness.
 */
export const SPACE_SPRING = { type: "spring", stiffness: 224, damping: 25.7, mass: 1 } as const;

export function loadSpace(): SpaceId {
  try {
    const saved = localStorage.getItem("space");
    if (saved === "clean" || saved === "terminal") return saved;
  } catch {}
  return "clean";
}

export function saveSpace(id: SpaceId) {
  try {
    localStorage.setItem("space", id);
  } catch {}
}
