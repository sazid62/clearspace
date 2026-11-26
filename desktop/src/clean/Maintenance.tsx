import { useEffect, useState, useSyncExternalStore } from "react";
import { CheckCircle2, CircleDashed, KeyRound, Play, RotateCw, Scissors, Wrench, XCircle } from "lucide-react";
import { abbreviate, bytes, plural, words } from "./api";
import type { MaintenanceModel } from "./maintenanceModel";
import { Checkbox, ConfirmDialog, FileIcon, Pill, Segmented, SizeColumn, Spinner } from "./ui";

export function Maintenance({ model }: { model: MaintenanceModel }) {
  const s = useSyncExternalStore(model.subscribe, model.getSnapshot);
  useEffect(() => model.load(), [model]);
  return (
    <div className="detail-content clean-detail">
      <header className="detail-header" data-tauri-drag-region>
        <div className="detail-titles" data-tauri-drag-region>
          <div className="detail-title">Maintenance</div>
          <div className="detail-subtitle">{s.tab === "tasks" ? "System chores, run when you ask" : "Remove the Intel half of universal apps"}</div>
        </div>
        {s.tab === "slim" && (
          <div className="toolbar">
            <button className="icon-button" title="Look again" disabled={s.slimListing || s.slimBusy} onClick={() => model.listSlim()}>
              <RotateCw size={15} />
            </button>
          </div>
        )}
      </header>
      {s.slimSupported && (
        <div className="results-bar">
          <Segmented
            id="maintenance"
            value={s.tab}
            onChange={model.setTab}
            options={[
              { value: "tasks", label: "Tasks" },
              { value: "slim", label: "Slim Apps" },
            ]}
          />
        </div>
      )}
      {s.tab === "tasks" || !s.slimSupported ? <Tasks model={model} /> : <Slim model={model} />}
    </div>
  );
}

function Tasks({ model }: { model: MaintenanceModel }) {
  const s = useSyncExternalStore(model.subscribe, model.getSnapshot);
  const [confirming, setConfirming] = useState(false);
  const picked = model.pickedTasks();
  const admin = picked.some((t) => t.admin);
  const lines = picked.map((t) => (t.caution ? `${t.title}. ${t.caution}` : t.title));
  return (
    <>
      <div className="hint">
        <span>
          Each task runs one command the system provides, shown under it. Nothing runs until you tick it and press Run. Tasks marked <b>Administrator</b> ask for your password once, together.
        </span>
      </div>
      <div className="clean-list">
        {s.loading && s.tasks.length === 0 && (
          <div className="list-empty">
            <Spinner size={22} />
          </div>
        )}
        {s.tasks.map((t) => {
          const on = s.picked.has(t.id);
          const outcome = s.outcomes.get(t.id);
          const running = s.running.has(t.id);
          return (
            <div key={t.id} className={"clean-row tall task-row" + (on ? " selected" : "")} onClick={() => !s.busy && model.toggle(t.id, !on)}>
              <Checkbox checked={on} disabled={s.busy} title="Tick to run" onChange={(value) => model.toggle(t.id, value)} />
              <span className="file-icon glyph" style={{ width: 26, height: 26 }}>
                {t.id.startsWith("touchid") ? <KeyRound size={15} strokeWidth={1.6} /> : <Wrench size={15} strokeWidth={1.6} />}
              </span>
              <div className="clean-text">
                <div className="clean-title">
                  <span className="ellipsis">{t.title}</span>
                  {t.admin && <Pill text="Administrator" tone="gray" title="Asks for the administrator password." />}
                </div>
                <div className="clean-note">
                  {t.detail}
                  {t.caution ? ` ${t.caution}` : ""}
                </div>
                <code className="task-command" title={t.command}>
                  {t.command}
                </code>
              </div>
              <div className="task-state">
                {running ? (
                  <Spinner size={15} />
                ) : outcome ? (
                  <span className={outcome.ok ? "task-ok" : "task-failed"} title={outcome.message}>
                    {outcome.ok ? <CheckCircle2 size={15} /> : <XCircle size={15} />} {outcome.ok ? "Done" : outcome.message}
                  </span>
                ) : null}
              </div>
            </div>
          );
        })}
      </div>
      <div className="action-bar">
        {picked.length === 0 ? <CircleDashed size={20} className="muted" /> : <CheckCircle2 size={20} className="accent" />}
        <div className="action-text">
          <b>{picked.length === 0 ? "Nothing ticked" : `${plural(picked.length, "task")} ticked`}</b>
          <span className="muted">{s.busy ? "Running…" : picked.length === 0 ? "Tick the tasks to run" : admin ? "Asks for your password" : "Runs right away"}</span>
        </div>
        <div className="spacer" />
        <button className="primary-button" disabled={picked.length === 0 || s.busy} onClick={() => setConfirming(true)}>
          {s.busy ? <Spinner size={12} /> : <Play size={13} />} Run
        </button>
      </div>
      <ConfirmDialog
        open={confirming}
        title={`Run ${plural(picked.length, "task")}?`}
        lines={lines}
        note={admin ? "You'll be asked for the administrator password once." : "They run right away."}
        confirm="Run"
        onConfirm={() => model.run()}
        onClose={() => setConfirming(false)}
      />
    </>
  );
}

function Slim({ model }: { model: MaintenanceModel }) {
  const s = useSyncExternalStore(model.subscribe, model.getSnapshot);
  const [confirming, setConfirming] = useState(false);
  const w = words();
  const picked = model.pickedSlim();
  const total = picked.reduce((n, a) => n + a.intel, 0);
  const largest = Math.max(s.slimApps[0]?.intel ?? 1, 1);
  const left = s.slimApps.filter((a) => !s.slimOutcomes.get(a.id)?.ok);
  const slimmed = [...s.slimOutcomes.values()].filter((o) => o.ok);
  return (
    <>
      <div className="hint">
        <span>
          These apps carry their code twice: once for Apple silicon, which this Mac runs, and once for Intel, which it never does. Slimming removes the Intel half. Each app is changed on a copy, the copy's signature is checked, and
          the original goes to the {w.trash} so you can put it back. App Store apps are left alone.
          {slimmed.length > 0 ? <b> Empty the {w.trash} to get the space back.</b> : null}
        </span>
      </div>
      <div className="clean-list">
        {s.slimApps.map((a) => {
          const on = s.slimPicked.has(a.id);
          const outcome = s.slimOutcomes.get(a.id);
          const running = s.slimRunning === a.id;
          const done = !!outcome?.ok;
          return (
            <div key={a.id} className={"clean-row tall" + (on ? " selected" : "")} onClick={() => !s.slimBusy && !done && model.toggleSlim(a.id, !on)}>
              <Checkbox checked={on} disabled={s.slimBusy || done} title="Tick to slim" onChange={(value) => model.toggleSlim(a.id, value)} />
              <FileIcon path={a.id} size={26} fallback={Scissors} />
              <div className="clean-text">
                <div className="clean-title">
                  <span className="ellipsis">{a.name}</span>
                  {done && <Pill text="Slimmed" tone="green" />}
                  {running && <Spinner size={12} />}
                </div>
                <div className="clean-subtitle ellipsis">
                  {abbreviate(a.id)} · Intel code in {plural(a.files, "file")}
                </div>
                {outcome && !outcome.ok && <div className="clean-note task-failed">{outcome.message}</div>}
              </div>
              <SizeColumn size={done ? outcome.freed : a.intel} fraction={a.intel / largest} muted={done} />
            </div>
          );
        })}
        {s.slimListing && (
          <div className="list-empty">
            <Spinner size={22} />
            <span>Looking through your apps…</span>
          </div>
        )}
        {!s.slimListing && s.slimApps.length === 0 && (
          <div className="list-empty">
            <CheckCircle2 size={28} strokeWidth={1.6} />
            <b>Nothing to slim</b>
            <span>No app here carries Intel code that can be removed safely.</span>
          </div>
        )}
      </div>
      <div className="action-bar">
        <Checkbox checked={left.length > 0 && picked.length === left.length} mixed={picked.length > 0 && picked.length < left.length} disabled={left.length === 0 || s.slimBusy} title="Select all" onChange={(on) => model.pickAllSlim(on)} />
        <div className="action-text">
          <b>{picked.length === 0 ? "Nothing ticked" : `${plural(picked.length, "app")} ticked`}</b>
          <span className="muted numeric">{s.slimBusy ? "Slimming…" : picked.length === 0 ? "Tick the apps to slim" : bytes(total)}</span>
        </div>
        <div className="spacer" />
        <button className="primary-button" disabled={picked.length === 0 || s.slimBusy} onClick={() => setConfirming(true)}>
          {s.slimBusy ? <Spinner size={12} /> : <Scissors size={13} />} Slim
        </button>
      </div>
      <ConfirmDialog
        open={confirming}
        title={`Slim ${plural(picked.length, "app")} (${bytes(total)})?`}
        lines={picked.slice(0, 8).map((a) => a.name)}
        note={`Quit them first. Each original goes to the ${w.trash}; put it back from there if a slimmed app misbehaves. An app that needs Intel plug-ins should stay as it is.`}
        confirm="Slim"
        onConfirm={() => model.slim()}
        onClose={() => setConfirming(false)}
      />
    </>
  );
}
