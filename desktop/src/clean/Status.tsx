import { useEffect, useSyncExternalStore, type ReactNode } from "react";
import { ArrowDown, ArrowUp, BatteryCharging, BatteryMedium, Cpu, HardDrive, HeartPulse, MemoryStick, Network } from "lucide-react";
import { api, bytes, rate, type Program, type SystemStatus } from "./api";
import { Store } from "./removal";
import { Spinner, UsageBar } from "./ui";

const EVERY_MS = 2000;
const KEPT = 60;

interface State {
  latest?: SystemStatus;
  /** Recent readings, oldest first, for the small charts. */
  cpu: number[];
  down: number[];
  up: number[];
  error?: string;
}

/** Live system status; asks for a reading every two seconds while the view is open. */
export class StatusModel extends Store<State> {
  private timer?: number;
  private watchers = 0;
  private asking = false;

  constructor() {
    super({ cpu: [], down: [], up: [] });
  }

  /** Starts sampling; the returned function stops it. */
  watch = () => {
    this.watchers++;
    if (this.watchers === 1) {
      void this.sample();
      this.timer = window.setInterval(() => void this.sample(), EVERY_MS);
    }
    return () => {
      this.watchers--;
      if (this.watchers === 0) window.clearInterval(this.timer);
    };
  };

  async sample() {
    if (this.asking) return;
    this.asking = true;
    try {
      const latest = await api.status();
      const push = (list: number[], value: number) => [...list, value].slice(-KEPT);
      this.set({ latest, error: undefined, cpu: push(this.state.cpu, latest.cpu), down: push(this.state.down, latest.netDown), up: push(this.state.up, latest.netUp) });
    } catch (e) {
      this.set({ error: String(e) });
    } finally {
      this.asking = false;
    }
  }
}

export function Status({ model }: { model: StatusModel }) {
  const s = useSyncExternalStore(model.subscribe, model.getSnapshot);
  useEffect(() => model.watch(), [model]);
  const v = s.latest;
  return (
    <div className="detail-content clean-detail">
      <header className="detail-header" data-tauri-drag-region>
        <div className="detail-titles" data-tauri-drag-region>
          <div className="detail-title">Status</div>
          <div className="detail-subtitle">{v ? [v.host, v.system, `up ${uptime(v.uptime)}`].filter(Boolean).join(" · ") : "Reading the system…"}</div>
        </div>
      </header>
      {!v ? (
        <div className="scroll center">{s.error ? <div className="muted">{s.error}</div> : <Spinner size={26} />}</div>
      ) : (
        <div className="scroll">
          <div className="status-grid">
            <Health status={v} />
            <Card icon={Cpu} title="Processor" value={`${Math.round(v.cpu)}%`} detail={v.processor || `${v.cores} cores`}>
              <Chart values={s.cpu} max={100} />
              <div className="cores">
                {v.perCore.map((usage, i) => (
                  <span key={i} className="core" title={`Core ${i + 1}: ${Math.round(usage)}%`}>
                    <span style={{ height: `${Math.max(4, Math.min(100, usage))}%` }} />
                  </span>
                ))}
              </div>
              {v.load && <Fact label="Load (1, 5, 15 min)" value={v.load.map((l) => l.toFixed(2)).join("  ")} />}
            </Card>
            <Card icon={MemoryStick} title="Memory" value={`${Math.round((v.memoryUsed / Math.max(1, v.memoryTotal)) * 100)}%`} detail={`${bytes(v.memoryUsed)} of ${bytes(v.memoryTotal)} in use`}>
              <UsageBar fraction={v.memoryUsed / Math.max(1, v.memoryTotal)} />
              <Fact label="Swapped to disk" value={v.swapTotal > 0 || v.swapUsed > 0 ? `${bytes(v.swapUsed)} of ${bytes(v.swapTotal)}` : "None"} />
            </Card>
            <Card icon={HardDrive} title="Disk" value={`${Math.round(((v.diskTotal - v.diskAvailable) / Math.max(1, v.diskTotal)) * 100)}%`} detail={`${bytes(v.diskAvailable)} available of ${bytes(v.diskTotal)}`}>
              <UsageBar fraction={(v.diskTotal - v.diskAvailable) / Math.max(1, v.diskTotal)} />
              <Fact label="Reading" value={rate(v.diskRead)} />
              <Fact label="Writing" value={rate(v.diskWrite)} />
            </Card>
            <Card icon={Network} title="Network" value={rate(v.netDown)} detail="Downloading now">
              <Chart values={s.down} second={s.up} />
              <Fact
                label={
                  <>
                    <ArrowDown size={11} /> Down
                  </>
                }
                value={rate(v.netDown)}
              />
              <Fact
                label={
                  <>
                    <ArrowUp size={11} /> Up
                  </>
                }
                value={rate(v.netUp)}
              />
            </Card>
            {v.battery && (
              <Card icon={v.battery.charging ? BatteryCharging : BatteryMedium} title="Battery" value={`${v.battery.percent}%`} detail={v.battery.charging ? "Plugged in" : "On battery"}>
                <div className="usage-bar">
                  <div className={"usage-fill battery" + (v.battery.percent <= 20 && !v.battery.charging ? " low" : "")} style={{ width: `${Math.max(1, v.battery.percent)}%` }} />
                </div>
              </Card>
            )}
            <Programs title="Busiest programs" programs={v.byCpu} value={(p) => `${p.cpu.toFixed(p.cpu < 10 ? 1 : 0)}%`} note="Percent of one processor core" />
            <Programs title="Most memory" programs={v.byMemory} value={(p) => bytes(p.memory)} />
          </div>
        </div>
      )}
    </div>
  );
}

function uptime(seconds: number) {
  const days = Math.floor(seconds / 86400);
  const hours = Math.floor((seconds % 86400) / 3600);
  const minutes = Math.floor((seconds % 3600) / 60);
  return days > 0 ? `${days}d ${hours}h` : hours > 0 ? `${hours}h ${minutes}m` : `${minutes}m`;
}

function Card({ icon: Icon, title, value, detail, children }: { icon: typeof Cpu; title: string; value: string; detail: string; children?: ReactNode }) {
  return (
    <section className="status-card">
      <div className="status-head">
        <Icon size={14} className="muted" />
        <span className="status-title">{title}</span>
        <span className="status-value numeric">{value}</span>
      </div>
      <div className="muted small ellipsis">{detail}</div>
      {children}
    </section>
  );
}

function Fact({ label, value }: { label: ReactNode; value: string }) {
  return (
    <div className="status-fact">
      <span className="muted">{label}</span>
      <span className="numeric">{value}</span>
    </div>
  );
}

function Health({ status }: { status: SystemStatus }) {
  const { score, issues } = status.health;
  const tone = score >= 85 ? "good" : score >= 60 ? "fair" : "poor";
  return (
    <section className={`status-card health ${tone}`}>
      <div className="health-score numeric">
        <HeartPulse size={18} />
        {score}
      </div>
      <div className="health-text">
        <b>{tone === "good" ? "Running well" : tone === "fair" ? "Under some strain" : "Struggling"}</b>
        {issues.length === 0 ? <span className="muted">Disk, memory and processor all have room to spare.</span> : issues.map((issue) => <span key={issue}>{issue}</span>)}
        <span className="muted small">A rough score out of 100 from how full the disk and memory are and how busy the processor is.</span>
      </div>
    </section>
  );
}

function Programs({ title, programs, value, note }: { title: string; programs: Program[]; value: (p: Program) => string; note?: string }) {
  return (
    <section className="status-card programs">
      <div className="status-head">
        <span className="status-title">{title}</span>
        {note && <span className="muted small">{note}</span>}
      </div>
      {programs.map((p) => (
        <div key={p.pid} className="status-fact">
          <span className="ellipsis">{p.name}</span>
          <span className="numeric">{value(p)}</span>
        </div>
      ))}
    </section>
  );
}

/** A small line chart of recent readings; `second` draws a fainter line on the same scale. */
function Chart({ values, second, max }: { values: number[]; second?: number[]; max?: number }) {
  const top = Math.max(max ?? 0, ...values, ...(second ?? []), 1);
  const line = (list: number[]) => list.map((v, i) => `${((i + KEPT - list.length) / (KEPT - 1)) * 100},${30 - (Math.min(v, top) / top) * 28 - 1}`).join(" ");
  return (
    <svg className="status-chart" viewBox="0 0 100 30" preserveAspectRatio="none" aria-hidden>
      {second && <polyline className="second" points={line(second)} />}
      <polyline points={line(values)} />
    </svg>
  );
}
