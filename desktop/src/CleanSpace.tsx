import { useEffect, useSyncExternalStore } from "react";
import { AnimatePresence, motion } from "motion/react";
import { HardDrive, PackageX, ShieldAlert, ShieldCheck } from "lucide-react";
import { api, bytes, type Storage } from "./clean/api";
import { CleanerModel } from "./clean/cleanerModel";
import { UninstallerModel } from "./clean/uninstallerModel";
import { DiskCleaner } from "./clean/DiskCleaner";
import { Uninstaller } from "./clean/Uninstaller";
import { UsageBar } from "./clean/ui";

export type Tool = "cleaner" | "uninstaller";

const TOOLS: { id: Tool; title: string; icon: typeof HardDrive }[] = [
  { id: "cleaner", title: "Disk Cleaner", icon: HardDrive },
  { id: "uninstaller", title: "App Uninstaller", icon: PackageX },
];

export const cleaner = new CleanerModel();
export const uninstaller = new UninstallerModel();

/** Disk capacity, shared by the sidebar footer and the cleaner; refreshed after removals and on focus. */
class StorageStore {
  private value?: Storage;
  private listeners = new Set<() => void>();
  subscribe = (l: () => void) => {
    this.listeners.add(l);
    return () => void this.listeners.delete(l);
  };
  get = () => this.value;
  refresh = () =>
    void api
      .storage()
      .then((s) => {
        this.value = s;
        this.listeners.forEach((l) => l());
      })
      .catch(() => {});
}
export const storage = new StorageStore();
cleaner.onFilesRemoved = storage.refresh;
uninstaller.onFilesRemoved = storage.refresh;

function useStorage() {
  useEffect(() => {
    storage.refresh();
    window.addEventListener("focus", storage.refresh);
    return () => window.removeEventListener("focus", storage.refresh);
  }, []);
  return useSyncExternalStore(storage.subscribe, storage.get);
}

export function CleanSidebar({ tool, onTool }: { tool: Tool; onTool: (t: Tool) => void }) {
  const info = useStorage();
  return (
    <div className="list clean-sidebar">
      <div className="section-title">Tools</div>
      {TOOLS.map((t) => {
        const Icon = t.icon;
        return (
          <button key={t.id} className={"row" + (t.id === tool ? " selected" : "")} onClick={() => onTool(t.id)}>
            <Icon size={15} className="row-icon" />
            <span className="row-title">{t.title}</span>
          </button>
        );
      })}
      {info && <SidebarStorage info={info} />}
    </div>
  );
}

function SidebarStorage({ info }: { info: Storage }) {
  const used = Math.max(0, info.total - info.available);
  return (
    <div className="sidebar-storage">
      <div className="sidebar-storage-name">
        <HardDrive size={13} className="muted" />
        <span className="ellipsis">{info.name}</span>
      </div>
      <UsageBar fraction={info.total ? used / info.total : 0} />
      <div className="muted small numeric">
        {bytes(info.available)} available of {bytes(info.total)}
      </div>
      {info.fullDiskAccess === true && (
        <div className="fda ok">
          <ShieldCheck size={12} /> Full Disk Access on
        </div>
      )}
      {info.fullDiskAccess === false && (
        <button className="fda warn" title="Lets Clearspace see every folder without repeated permission prompts" onClick={() => void api.openSettings("fullDiskAccess")}>
          <ShieldAlert size={12} /> Grant Full Disk Access
        </button>
      )}
    </div>
  );
}

/** The selected tool; switching cross-fades with a small lift. */
export function CleanDetail({ tool }: { tool: Tool }) {
  const info = useStorage();
  return (
    <AnimatePresence mode="popLayout" initial={false}>
      <motion.div
        key={tool}
        className="tool-pane"
        initial={{ opacity: 0, y: 6 }}
        animate={{ opacity: 1, y: 0 }}
        exit={{ opacity: 0 }}
        transition={{ opacity: { duration: 0.16 }, y: { type: "spring", stiffness: 380, damping: 32 } }}
      >
        {tool === "cleaner" ? <DiskCleaner model={cleaner} storage={info} /> : <Uninstaller model={uninstaller} />}
      </motion.div>
    </AnimatePresence>
  );
}
