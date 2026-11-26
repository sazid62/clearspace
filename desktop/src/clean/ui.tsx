import { useEffect, useRef, useState, type ReactNode } from "react";
import { AnimatePresence, motion } from "motion/react";
import { AlertTriangle, Check, CheckCircle2, File, Folder, Minus, Search, X, XOctagon, type LucideIcon } from "lucide-react";
import { revealItemInDir } from "@tauri-apps/plugin-opener";
import { writeText } from "@tauri-apps/plugin-clipboard-manager";
import { Menu, MenuItem } from "@tauri-apps/api/menu";
import { abbreviate, api, bytes, iconUrl, plural, words } from "./api";
import { canRetryAsAdmin, failures, removed, removedSize, type Removal, type RemovalHost } from "./removal";
import { isMac, os } from "../platform";

export function Checkbox({ checked, mixed, disabled, onChange, title }: { checked: boolean; mixed?: boolean; disabled?: boolean; onChange: (on: boolean) => void; title?: string }) {
  return (
    <button
      type="button"
      role="checkbox"
      aria-checked={mixed ? "mixed" : checked}
      className={"checkbox" + (checked || mixed ? " on" : "")}
      disabled={disabled}
      title={title}
      onClick={(e) => {
        e.stopPropagation();
        onChange(!checked);
      }}
    >
      {mixed ? <Minus size={11} strokeWidth={3.2} /> : checked ? <Check size={11} strokeWidth={3.2} /> : null}
    </button>
  );
}

export function Pill({ text, tone, title }: { text: string; tone: "green" | "orange" | "gray"; title?: string }) {
  return (
    <span className={`pill ${tone}`} title={title}>
      {text}
    </span>
  );
}

export function UsageBar({ fraction, muted }: { fraction: number; muted?: boolean }) {
  const tone = fraction > 0.9 ? "red" : fraction > 0.75 ? "orange" : "";
  return (
    <div className={"usage-bar" + (muted ? " muted" : "")}>
      <motion.div className={"usage-fill " + tone} initial={false} animate={{ width: `${Math.max(1, Math.min(100, fraction * 100))}%` }} transition={{ type: "spring", stiffness: 200, damping: 30 }} />
    </div>
  );
}

/** Size text with a bar showing the share of its folder (or of the biggest item in a list). */
export function SizeColumn({ size, fraction, muted }: { size: number; fraction: number; muted?: boolean }) {
  return (
    <div className="size-column">
      <span className={"size-text" + (muted ? " muted" : "")}>{bytes(size)}</span>
      <UsageBar fraction={fraction} muted />
    </div>
  );
}

/** The system's own icon for the file (Finder icons on macOS), falling back to a plain glyph. */
export function FileIcon({ path, size, dir, fallback }: { path: string; size: number; dir?: boolean; fallback?: LucideIcon }) {
  // macOS draws any file's Finder icon; elsewhere only icon image files (Linux app icons) can be shown.
  const drawable = os === "macos" || /\.(png|svg)$/i.test(path);
  const [failed, setFailed] = useState(false);
  useEffect(() => setFailed(false), [path]);
  const Glyph = fallback ?? (dir ? Folder : File);
  if (failed || !drawable) {
    return (
      <span className="file-icon glyph" style={{ width: size, height: size }}>
        <Glyph size={Math.round(size * 0.62)} strokeWidth={1.6} />
      </span>
    );
  }
  return <img className="file-icon" src={iconUrl(path, size)} width={size} height={size} loading="lazy" decoding="async" draggable={false} alt="" onError={() => setFailed(true)} />;
}

export function SearchField({ value, onChange, placeholder }: { value: string; onChange: (v: string) => void; placeholder: string }) {
  return (
    <label className="search-field">
      <Search size={13} className="search-icon" />
      <input value={value} placeholder={placeholder} spellCheck={false} onChange={(e) => onChange(e.target.value)} onKeyDown={(e) => e.key === "Escape" && onChange("")} />
      {value && (
        <button className="search-clear" onClick={() => onChange("")} aria-label="Clear search">
          <X size={11} strokeWidth={2.6} />
        </button>
      )}
    </label>
  );
}

export function Segmented<T extends string>({ value, options, onChange, id }: { value: T; options: { value: T; label: string }[]; onChange: (v: T) => void; id: string }) {
  return (
    <div className="segmented" role="tablist">
      {options.map((o) => (
        <button key={o.value} role="tab" aria-selected={o.value === value} className={"segment" + (o.value === value ? " selected" : "")} onClick={() => onChange(o.value)}>
          {o.value === value && <motion.span layoutId={`segment-${id}`} className="segment-pill" transition={{ type: "spring", stiffness: 500, damping: 38 }} />}
          <span className="segment-label">{o.label}</span>
        </button>
      ))}
    </div>
  );
}

/** Renders a long list a chunk at a time, adding the next chunk as the end scrolls into view. */
export function LazyList<T>({ items, render, step = 150, resetKey }: { items: T[]; render: (item: T) => ReactNode; step?: number; resetKey?: unknown }) {
  const [count, setCount] = useState(step);
  const sentinel = useRef<HTMLDivElement>(null);
  useEffect(() => setCount(step), [resetKey, step]);
  useEffect(() => {
    const el = sentinel.current;
    if (!el) return;
    const observer = new IntersectionObserver((entries) => entries[0]?.isIntersecting && setCount((c) => c + step));
    observer.observe(el);
    return () => observer.disconnect();
  }, [count, items.length, step]);
  return (
    <>
      {items.slice(0, count).map(render)}
      {items.length > count && <div ref={sentinel} className="lazy-sentinel" />}
    </>
  );
}

export function Spinner({ size = 16 }: { size?: number }) {
  return <span className="spinner" style={{ width: size, height: size }} />;
}

export function Hero({ icon: Icon, tint }: { icon: LucideIcon; tint?: string }) {
  return (
    <div className="empty-badge" style={tint ? { background: tint } : undefined}>
      <Icon size={34} strokeWidth={1.6} />
    </div>
  );
}

/** Native right-click menu for a file: reveal it, copy its path, plus what the list adds. */
export async function showFileMenu(path: string, more: { text: string; action: () => void }[] = []) {
  const menu = await Menu.new({
    items: [
      await MenuItem.new({ text: words().reveal, action: () => void revealItemInDir(path) }),
      await MenuItem.new({ text: "Copy Path", action: () => void writeText(path) }),
      ...(await Promise.all(more.map((item) => MenuItem.new(item)))),
    ],
  });
  await menu.popup();
}

/** A modal over the window, like the Terminal dialogs. */
export function Modal({ open, onClose, children, width = 420 }: { open: boolean; onClose: () => void; children: ReactNode; width?: number }) {
  useEffect(() => {
    if (!open) return;
    const onKey = (e: KeyboardEvent) => e.key === "Escape" && onClose();
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [open, onClose]);
  return (
    <AnimatePresence>
      {open && (
        <motion.div className="scrim" initial={{ opacity: 0 }} animate={{ opacity: 1 }} exit={{ opacity: 0 }} transition={{ duration: 0.15 }} onMouseDown={(e) => e.target === e.currentTarget && onClose()}>
          <motion.div
            className="dialog"
            style={{ width }}
            initial={{ opacity: 0, scale: 0.96, y: 8 }}
            animate={{ opacity: 1, scale: 1, y: 0 }}
            exit={{ opacity: 0, scale: 0.97 }}
            transition={{ type: "spring", stiffness: 420, damping: 32 }}
          >
            {children}
          </motion.div>
        </motion.div>
      )}
    </AnimatePresence>
  );
}

/** "Move 3 items to the Trash?" with the paths listed and a destructive confirm button. */
export function ConfirmDialog({
  open,
  title,
  lines,
  note,
  confirm,
  destructive,
  typeToConfirm,
  onConfirm,
  onClose,
}: {
  open: boolean;
  title: string;
  lines: string[];
  note: string;
  confirm: string;
  destructive?: boolean;
  /** When set, the button stays off until this text is typed. */
  typeToConfirm?: string;
  onConfirm: () => void;
  onClose: () => void;
}) {
  const [typed, setTyped] = useState("");
  const input = useRef<HTMLInputElement>(null);
  const button = useRef<HTMLButtonElement>(null);
  useEffect(() => {
    if (!open) return;
    setTyped("");
    requestAnimationFrame(() => (typeToConfirm ? input.current?.focus() : button.current?.focus()));
  }, [open, typeToConfirm]);
  const ready = !typeToConfirm || typed === typeToConfirm;
  const go = () => {
    if (!ready) return;
    onClose();
    onConfirm();
  };
  return (
    <Modal open={open} onClose={onClose} width={460}>
      <div className="confirm-head">
        {destructive && <AlertTriangle size={26} className="confirm-icon" />}
        <h2>{title}</h2>
      </div>
      {lines.length > 0 && (
        <div className="confirm-list">
          {lines.map((l) => (
            <div key={l} className="confirm-line">
              {l}
            </div>
          ))}
        </div>
      )}
      <p className="help">{note}</p>
      {typeToConfirm && (
        <label className="field">
          <span>
            Type <b className="confirm-name">{typeToConfirm}</b> to confirm
          </span>
          <input ref={input} value={typed} placeholder={typeToConfirm} onChange={(e) => setTyped(e.target.value)} onKeyDown={(e) => e.key === "Enter" && go()} />
        </label>
      )}
      <div className="dialog-buttons">
        <button className="plain-button" onClick={onClose}>
          Cancel
        </button>
        <button ref={button} className={destructive ? "danger-button" : "primary-button"} disabled={!ready} onClick={go}>
          {confirm}
        </button>
      </div>
    </Modal>
  );
}

/** Progress while removing, then a summary with what failed and why. */
export function RemovalPanel({ removal, host }: { removal?: Removal; host: RemovalHost }) {
  const w = words();
  return (
    <AnimatePresence>
      {removal && (
        <motion.div className="scrim local" initial={{ opacity: 0 }} animate={{ opacity: 1 }} exit={{ opacity: 0 }} transition={{ duration: 0.15 }}>
          <motion.div className="dialog removal" initial={{ opacity: 0, scale: 0.96, y: 8 }} animate={{ opacity: 1, scale: 1, y: 0 }} exit={{ opacity: 0, scale: 0.97 }} transition={{ type: "spring", stiffness: 420, damping: 32 }}>
            {removal.running ? <Running removal={removal} /> : <Summary removal={removal} host={host} />}
          </motion.div>
        </motion.div>
      )}
    </AnimatePresence>
  );

  function Running({ removal }: { removal: Removal }) {
    const done = removal.outcomes.length;
    return (
      <>
        <h2>{removal.mode === "trash" ? `Moving to ${w.trash}…` : "Deleting…"}</h2>
        <div className="progress">
          <motion.div className="progress-fill" initial={false} animate={{ width: `${(done / Math.max(1, removal.total)) * 100}%` }} transition={{ type: "spring", stiffness: 160, damping: 26 }} />
        </div>
        <div className="progress-caption">
          <span className="ellipsis">{abbreviate(removal.current)}</span>
          <span className="numeric">
            {Math.min(done + 1, removal.total)} of {removal.total}
          </span>
        </div>
        {removal.mode === "permanent" && removedSize(removal) > 0 && <div className="freed">{bytes(removedSize(removal))} freed so far</div>}
        <div className="help faint">Large folders can take a few minutes.</div>
      </>
    );
  }

  function Summary({ removal, host }: { removal: Removal; host: RemovalHost }) {
    const fails = failures(removal);
    const count = removed(removal).length;
    const size = bytes(removedSize(removal));
    const title = count === 0 ? "Nothing was removed" : removal.mode === "trash" ? `Moved ${plural(count, "item")} to the ${w.trash}` : `Deleted ${plural(count, "item")}`;
    const detail =
      count === 0 ? "The items below were left as they were." : removal.mode === "trash" ? `${size} is now in the ${w.trash}. Empty the ${w.trash} to get the space back.` : `${size} of disk space freed.`;
    return (
      <>
        <div className="summary-head">
          {fails.length === 0 ? <CheckCircle2 size={30} className="ok-icon" /> : <AlertTriangle size={30} className="warn-icon" />}
          <div>
            <h2>{title}</h2>
            <p className="help">{detail}</p>
          </div>
        </div>
        {fails.length > 0 && (
          <>
            <div className="fail-title">{plural(fails.length, "item")} couldn't be removed</div>
            <div className="fail-list">
              {fails.map((f) => (
                <div key={f.path} className="fail">
                  <div className="ellipsis">{abbreviate(f.path)}</div>
                  <div className="fail-reason">{f.error}</div>
                </div>
              ))}
            </div>
            {isMac && fails.some((f) => f.path.endsWith(".app")) && (
              <div className="help">
                Removing apps can need App Management permission.{" "}
                <button className="link-button" onClick={() => void api.openSettings("appManagement")}>
                  Open Settings
                </button>
              </div>
            )}
          </>
        )}
        {removal.adminError && (
          <div className="admin-error">
            <XOctagon size={13} /> {removal.adminError}
          </div>
        )}
        <div className="dialog-buttons">
          {removal.elevating && (
            <span className="waiting">
              <Spinner size={13} /> Waiting for administrator approval…
            </span>
          )}
          {canRetryAsAdmin(removal) && (
            <button className="plain-button" disabled={removal.elevating} onClick={() => host.retryAsAdmin()}>
              Retry as Administrator…
            </button>
          )}
          <button className="primary-button" disabled={removal.elevating} autoFocus onClick={() => host.finishRemoval()}>
            Done
          </button>
        </div>
      </>
    );
  }
}
