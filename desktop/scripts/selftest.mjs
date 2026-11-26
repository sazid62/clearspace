#!/usr/bin/env node
// Runs the app's built-in self-test (setup, then quit and reopen to restore) and checks the logs.
// Usage: node scripts/selftest.mjs <path to the app binary> [output folder]
// Used by CI on macOS, Windows and Ubuntu; works locally too.
import { spawn } from "node:child_process";
import { mkdtempSync, readFileSync, existsSync, mkdirSync, writeFileSync, rmSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";

const [binary, outArg] = process.argv.slice(2);
if (!binary) {
  console.error("usage: node scripts/selftest.mjs <app binary> [output folder]");
  process.exit(2);
}
const out = outArg ?? mkdtempSync(join(tmpdir(), "clearspace-selftest-"));
const data = join(out, "terminal");

// The Disk Cleaner scans this instead of the whole disk: a JS project with node_modules and a
// .next cache, plus one big log. Inside /tmp on macOS/Linux and the home folder on Windows, where
// the cleaner looks for leftovers.
const fixture = process.platform === "win32" ? join(homedir(), `clearspace-fixture-${process.pid}`) : `/tmp/clearspace-fixture-${process.pid}`;
const mb = (n) => Buffer.alloc(n * 1024 * 1024, 1);
mkdirSync(join(fixture, "project", "node_modules"), { recursive: true });
mkdirSync(join(fixture, "project", ".next"), { recursive: true });
mkdirSync(join(fixture, "notes"), { recursive: true });
writeFileSync(join(fixture, "project", "package.json"), "{}");
writeFileSync(join(fixture, "project", "node_modules", "blob"), mb(25));
writeFileSync(join(fixture, "project", ".next", "cache.bin"), mb(22));
writeFileSync(join(fixture, "notes", "huge.log"), mb(30));
// A linked git worktree: its .git file points into a repository's .git/worktrees.
const admin = join(fixture, "repo", ".git", "worktrees", "feature");
mkdirSync(admin, { recursive: true });
mkdirSync(join(fixture, ".hidden", "feature"), { recursive: true });
writeFileSync(join(admin, "HEAD"), "ref: refs/heads/feat/login\n");
writeFileSync(join(fixture, ".hidden", "feature", ".git"), `gitdir: ${admin.replaceAll("\\", "/")}\n`);
writeFileSync(join(fixture, ".hidden", "feature", "code.txt"), "x");

function run(scenario) {
  return new Promise((resolve) => {
    const child = spawn(binary, [], {
      env: { ...process.env, CLEARSPACE_SELFTEST: scenario, CLEARSPACE_SELFTEST_DIR: out, CLEARSPACE_TERMINAL_DIR: data, CLEARSPACE_SCAN_ROOTS: fixture },
      stdio: "inherit",
    });
    const timer = setTimeout(() => {
      console.error(`${scenario}: still running after 150 s, stopping it`);
      child.kill();
    }, 150_000);
    child.on("exit", (code) => {
      clearTimeout(timer);
      resolve(code);
    });
  });
}

const checks = {
  setup: [
    /^first tab output has hello-from-42: true$/m,
    /^mid-swipe 90px: space=Terminal/m,
    /^after resting at 90px: space=Terminal/m,
    /^after 180px swipe: space=Clean/m,
    /^after short flick: space=Terminal/m,
    /^after flick back: space=Clean/m,
    /^after short swipe: space=Clean/m,
    /^rubber band: space=Clean strip=translateX\(\d/m,
    /^after rubber band: space=Clean/m,
    /^after vertical: space=Clean/m,
    ...(process.platform === "darwin" ? [/^coasting after a swipe swallowed: true$/m] : []),
  ],
  clean: [
    /^welcome shows Start Scan: true$/m,
    /^scan finished: true$/m,
    /^suggestions: .*node_modules · project\/review/m,
    /^suggestions: .*\.next build cache · project\/safe/m,
    /^large files: 3, /m,
    /^worktrees: feature@feat\/login in repo$/m,
    /^selected after Select All Safe: \.next$/m,
    /^removal finished: true$/m,
    /^removed: 1, failed: $/m,
    /^removed items gone from disk: true$/m,
    /^suggestions after removal: (?!.*\.next)/m,
    /^guard on scanned folder: This folder is protected\.$/m,
    ...(process.platform === "darwin" ? [/^icon handler: 200 image\/png \d{3,} bytes$/m] : []),
    /^apps loaded: true$/m,
    /^uninstall confirm open: true$/m,
    /^nothing removed: true$/m,
  ],
  restore: [
    /^terminals shown: 1, it is the selected tab's: true$/m,
    /^groups: skreno\/purple, infra\/green$/m,
    /^tabs: [^|]+\(pinned\)@.+ \| api@.+ \| .+#orange \| /m,
    /^pinned tab restored scrollback: true, divider: true$/m,
    /^api startup command ran: true/m,
    /^api command typed once: true$/m,
  ],
};

let failed = 0;
for (const scenario of ["setup", "restore", "clean"]) {
  const code = await run(scenario);
  const logFile = join(out, `${scenario}.log`);
  const log = existsSync(logFile) ? readFileSync(logFile, "utf8") : "";
  console.log(`\n== ${scenario} (exit ${code}) ==\n${log.split("\n").filter((l) => !l.startsWith("workspace:")).join("\n")}`);
  for (const check of checks[scenario]) {
    if (!check.test(log)) {
      failed++;
      console.error(`FAIL ${scenario}: ${check}`);
    }
  }
}
rmSync(fixture, { recursive: true, force: true });
console.log(failed ? `\n${failed} check(s) failed. Snapshots and logs: ${out}` : `\nAll checks passed. Snapshots and logs: ${out}`);
process.exit(failed ? 1 : 0);
