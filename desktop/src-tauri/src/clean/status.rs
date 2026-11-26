//! Live system status: processor, memory, disk and network activity, battery and the busiest
//! programs. The window asks for a sample every couple of seconds while the Status view is open.

use serde::Serialize;
use std::time::Instant;
use sysinfo::{CpuRefreshKind, DiskRefreshKind, Disks, MemoryRefreshKind, Networks, ProcessRefreshKind, ProcessesToUpdate, System};

#[derive(Serialize, Clone, Debug)]
#[serde(rename_all = "camelCase")]
pub struct Program {
    pub pid: u32,
    pub name: String,
    /// Percent of one processor core, as Activity Monitor and Task Manager's details show it.
    pub cpu: f32,
    pub memory: u64,
}

#[derive(Serialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Battery {
    pub percent: u8,
    /// Plugged in, whether or not it is still filling up.
    pub charging: bool,
}

#[derive(Serialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Health {
    /// 100 is a machine with room to spare; each issue takes points off.
    pub score: u8,
    pub issues: Vec<String>,
}

#[derive(Serialize, Clone, Debug)]
#[serde(rename_all = "camelCase")]
pub struct Status {
    pub host: String,
    pub system: String,
    pub processor: String,
    pub cores: usize,
    /// Seconds since the machine started.
    pub uptime: u64,
    /// Percent of all cores together.
    pub cpu: f32,
    pub per_core: Vec<f32>,
    /// Load over 1, 5 and 15 minutes; None on Windows.
    pub load: Option<[f64; 3]>,
    pub memory_used: u64,
    pub memory_total: u64,
    pub swap_used: u64,
    pub swap_total: u64,
    pub disk_total: u64,
    pub disk_available: u64,
    /// Bytes a second.
    pub disk_read: u64,
    pub disk_write: u64,
    pub net_down: u64,
    pub net_up: u64,
    pub battery: Option<Battery>,
    pub by_cpu: Vec<Program>,
    pub by_memory: Vec<Program>,
    pub health: Health,
}

pub struct Sampler {
    system: System,
    networks: Option<Networks>,
    disks: Option<Disks>,
    last: Instant,
}

/// Interfaces that carry traffic already counted on a real one (VPN tunnels, bridges, containers).
fn is_virtual(interface: &str) -> bool {
    let name = interface.to_lowercase();
    // "lo" and "lo0", but not Windows' "Local Area Connection".
    let loopback = name.strip_prefix("lo").is_some_and(|rest| rest.chars().all(|c| c.is_ascii_digit()));
    loopback || ["utun", "tun", "tap", "wg", "awdl", "llw", "bridge", "docker", "veth", "br-", "virbr", "vmnet", "loopback", "anpi", "ap1", "gif", "stf"].iter().any(|p| name.starts_with(p))
}

impl Sampler {
    pub fn new() -> Result<Self, String> {
        let mut system = System::new().map_err(|e| e.to_string())?;
        system.refresh_cpu_list(CpuRefreshKind::everything());
        system.refresh_memory_specifics(MemoryRefreshKind::everything());
        Ok(Sampler { system, networks: Networks::new_with_refreshed_list().ok(), disks: Disks::new_with_refreshed_list().ok(), last: Instant::now() })
    }

    /// Activity is measured since the previous sample, so the first one reads as idle.
    pub fn sample(&mut self, disk_total: u64, disk_available: u64) -> Status {
        let seconds = self.last.elapsed().as_secs_f64().max(0.2);
        self.last = Instant::now();
        let s = &mut self.system;
        s.refresh_cpu_usage();
        s.refresh_memory_specifics(MemoryRefreshKind::everything());
        s.refresh_processes_specifics(ProcessesToUpdate::All, true, ProcessRefreshKind::nothing().with_cpu().with_memory());

        let rate = |bytes: u64| (bytes as f64 / seconds) as u64;
        let (mut down, mut up) = (0, 0);
        if let Some(networks) = &mut self.networks {
            networks.refresh(true);
            for (name, data) in networks.iter() {
                if !is_virtual(&name.to_string_lossy()) {
                    down += data.received();
                    up += data.transmitted();
                }
            }
        }
        // Volumes of one disk each report that disk's activity, so the busiest stands for all.
        let (mut read, mut written) = (0, 0);
        if let Some(disks) = &mut self.disks {
            disks.refresh_specifics(true, DiskRefreshKind::nothing().with_io_usage());
            for disk in disks.iter() {
                let usage = disk.usage();
                read = read.max(usage.read_bytes);
                written = written.max(usage.written_bytes);
            }
        }

        let mut programs: Vec<Program> = s
            .processes()
            .iter()
            .map(|(pid, p)| Program { pid: pid.as_u32(), name: p.name().to_string_lossy().into_owned(), cpu: p.cpu_usage(), memory: p.memory() })
            .filter(|p| !p.name.is_empty())
            .collect();
        programs.sort_by(|a, b| b.cpu.total_cmp(&a.cpu));
        let by_cpu: Vec<Program> = programs.iter().take(6).cloned().collect();
        programs.sort_by(|a, b| b.memory.cmp(&a.memory));
        programs.truncate(6);

        let cores = s.cpus().len().max(1);
        let cpu = s.global_cpu_usage();
        let load = if cfg!(windows) { None } else { System::load_average().ok().map(|l| [l.one, l.five, l.fifteen]) };
        // What programs hold and can't give back at once; cached files don't count.
        let memory_total = s.total_memory();
        let memory_used = if s.available_memory() > 0 { memory_total.saturating_sub(s.available_memory()) } else { s.used_memory() };
        let health = health(&Vitals { cpu, load: load.map(|l| l[0]), cores, memory_used, memory_total, swap_used: s.used_swap(), disk_total, disk_available });
        Status {
            host: System::host_name().unwrap_or_default(),
            system: System::long_os_version().unwrap_or_default(),
            processor: s.cpus().first().map(|c| c.brand().trim().to_string()).unwrap_or_default(),
            cores,
            uptime: System::uptime().unwrap_or(0),
            cpu,
            per_core: s.cpus().iter().map(|c| c.usage()).collect(),
            load,
            memory_used,
            memory_total,
            swap_used: s.used_swap(),
            swap_total: s.total_swap(),
            disk_total,
            disk_available,
            disk_read: rate(read),
            disk_write: rate(written),
            net_down: rate(down),
            net_up: rate(up),
            battery: battery(),
            by_cpu,
            by_memory: programs,
            health,
        }
    }
}

pub struct Vitals {
    pub cpu: f32,
    pub load: Option<f64>,
    pub cores: usize,
    pub memory_used: u64,
    pub memory_total: u64,
    pub swap_used: u64,
    pub disk_total: u64,
    pub disk_available: u64,
}

/// A rough score: what is close to running out, and how much that matters.
pub fn health(v: &Vitals) -> Health {
    let mut score: i32 = 100;
    let mut issues = vec![];
    let mut take = |points: i32, issue: &str| {
        score -= points;
        issues.push(issue.to_string());
    };
    if v.disk_total > 0 {
        let full = 1.0 - v.disk_available as f64 / v.disk_total as f64;
        if full > 0.95 {
            take(35, "The disk is almost full.");
        } else if full > 0.88 {
            take(18, "The disk is getting full.");
        }
    }
    if v.memory_total > 0 {
        let used = v.memory_used as f64 / v.memory_total as f64;
        if used > 0.93 {
            take(20, "Memory is almost all in use.");
        } else if used > 0.85 {
            take(8, "Memory is running high.");
        }
        if v.swap_used as f64 > v.memory_total as f64 * 0.25 {
            take(12, "A lot is swapped out to disk, which slows things down.");
        }
    }
    let per_core = v.load.map(|l| l / v.cores.max(1) as f64);
    if per_core.is_some_and(|l| l > 1.5) {
        take(15, "More work is queued than the processor can keep up with.");
    } else if v.cpu > 85.0 || per_core.is_some_and(|l| l > 1.0) {
        take(8, "The processor is busy.");
    }
    Health { score: score.clamp(0, 100) as u8, issues }
}

#[cfg(target_os = "macos")]
fn battery() -> Option<Battery> {
    let out = std::process::Command::new("/usr/bin/pmset").args(["-g", "batt"]).output().ok()?;
    parse_pmset(&String::from_utf8_lossy(&out.stdout))
}

/// ` -InternalBattery-0 (id=123)	84%; discharging; 5:12 remaining present: true`
#[cfg(any(target_os = "macos", test))]
fn parse_pmset(text: &str) -> Option<Battery> {
    let line = text.lines().find(|l| l.contains("InternalBattery"))?;
    let percent = line.split('%').next()?.rsplit(|c: char| !c.is_ascii_digit()).next()?.parse().ok()?;
    let state = line.split(';').nth(1).unwrap_or("").trim();
    Some(Battery { percent, charging: state == "charging" || state == "charged" || state == "finishing charge" || text.contains("'AC Power'") })
}

#[cfg(target_os = "linux")]
fn battery() -> Option<Battery> {
    use super::fsx;
    let base = "/sys/class/power_supply";
    for name in fsx::list_names(base) {
        let dir = fsx::join(base, &name);
        if std::fs::read_to_string(fsx::join(&dir, "type")).is_ok_and(|t| t.trim() == "Battery") {
            let percent = std::fs::read_to_string(fsx::join(&dir, "capacity")).ok()?.trim().parse().ok()?;
            let state = std::fs::read_to_string(fsx::join(&dir, "status")).unwrap_or_default();
            return Some(Battery { percent, charging: matches!(state.trim(), "Charging" | "Full" | "Not charging") });
        }
    }
    None
}

#[cfg(windows)]
fn battery() -> Option<Battery> {
    use windows_sys::Win32::System::Power::{GetSystemPowerStatus, SYSTEM_POWER_STATUS};
    let mut status: SYSTEM_POWER_STATUS = unsafe { std::mem::zeroed() };
    if unsafe { GetSystemPowerStatus(&mut status) } == 0 {
        return None;
    }
    // 128 in the flags means no battery; 255 means the level is unknown.
    if status.BatteryFlag & 128 != 0 || status.BatteryLifePercent > 100 {
        return None;
    }
    Some(Battery { percent: status.BatteryLifePercent, charging: status.ACLineStatus == 1 })
}

#[cfg(test)]
mod tests {
    use super::*;

    const GB: u64 = 1 << 30;

    fn vitals() -> Vitals {
        Vitals { cpu: 12.0, load: Some(1.0), cores: 8, memory_used: 8 * GB, memory_total: 16 * GB, swap_used: 0, disk_total: 500 * GB, disk_available: 200 * GB }
    }

    #[test]
    fn a_roomy_machine_scores_full() {
        assert_eq!(health(&vitals()), Health { score: 100, issues: vec![] });
    }

    #[test]
    fn each_shortage_takes_points_off() {
        let full = health(&Vitals { disk_available: 10 * GB, ..vitals() });
        assert_eq!((full.score, full.issues.as_slice()), (65, ["The disk is almost full.".to_string()].as_slice()));
        let busy = health(&Vitals { load: Some(20.0), memory_used: 15 * GB, swap_used: 6 * GB, ..vitals() });
        assert_eq!(busy.score, 100 - 20 - 12 - 15);
        assert_eq!(busy.issues.len(), 3);
    }

    #[test]
    fn reads_the_battery_line() {
        let text = "Now drawing from 'Battery Power'\n -InternalBattery-0 (id=4653155)\t84%; discharging; 5:12 remaining present: true\n";
        assert_eq!(parse_pmset(text), Some(Battery { percent: 84, charging: false }));
        let charging = "Now drawing from 'AC Power'\n -InternalBattery-0 (id=1)\t100%; charged; 0:00 remaining present: true\n";
        assert_eq!(parse_pmset(charging), Some(Battery { percent: 100, charging: true }));
        assert_eq!(parse_pmset("Now drawing from 'AC Power'\n"), None);
    }

    #[test]
    fn tunnels_do_not_count_as_network_traffic() {
        assert!(is_virtual("utun4") && is_virtual("lo0") && is_virtual("docker0"));
        assert!(!is_virtual("en0") && !is_virtual("eth0") && !is_virtual("Wi-Fi") && !is_virtual("Local Area Connection"));
    }
}
