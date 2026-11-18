# Package Failure Diagnostics & Active Runtime Guard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show exit codes and sanitized output tails (`stderr` or `stdout`) on package manager failures/timeouts, mark `WINGET_OK_CODES` as `[ok]` in progress output, and safely skip in-place `winget` upgrades of active `nu`/`pwsh` runtimes on Windows with a warning.

**Architecture:** Extend `src/pkg.nu` with `format-pkg-failure-tail`, `--ok-codes` on `run-with-timeout`, richer failure records (`exit_code`, `tail`) and `warnings: list<record<source: string, module: string, item: string, message: string>>` on `install-packages`, plus a pure `active-runtime-winget-warning` guard (bypassed in `--dry-run`, skipping `state.hashes` caching when triggered). Update `bin/ygg.nu` (`apply-plan`) to surface `exit_code` and `tail` in the final error and append `$pkg_res.warnings` to `(hook-warnings $hooks)` in `format-apply-summary`.

**Tech Stack:** Nushell (`nu >= 0.116`), `src/pkg.nu`, `src/progress.nu` (`sanitize-log-line`), `bin/ygg.nu`, `tests/test_pkg_git.nu`, `tests/test_e2e_apply.nu`.

**Spec:** [2026-11-18-pkg-failure-diagnostics-and-running-shell-design.md](../../specs/2026-11-18-pkg-failure-diagnostics-and-running-shell-design.md) (`RFC-064`, Issue `#14`)

## Global Constraints

- Nushell `>= 0.116`; cross-platform on Linux, Windows 11/Server Non-Admin, macOS (`active-runtime-winget-warning` is Windows-only no-op elsewhere; diagnostics apply to all managers).
- ZERO HOST MUTATION in tests: all tests run inside `with-temp-ygg` using `YGG_MOCK_*` env vars, never invoking real `winget`.
- `--dry-run` (`ygg diff` / `apply --dry-run`) must remain strictly read-only and emit no runtime-skip warnings or progress noise (AGENTS.md §2.1).
- Backward compatibility: `install-packages` keeps `mgr`, `pkg`, `reason`, `stderr` in `failed` items and keeps `skipped` strictly as `list<string>` of cached manager names.
- Git & DoD (AGENTS.md §1a): implement in worktree `.worktrees/fix-issue-14-pkg-failure-diagnostics` (branch `fix/issue-14-pkg-failure-diagnostics` from `origin/main`), include `# regression: #14` on new tests, and end final commit with `Fixes #14`.

## Review Focus

- `winget` writes errors to `stdout` with `\r`-overwritten spinner lines and ANSI codes: `format-pkg-failure-tail` must split on `[\r\n]+` before `sanitize-log-line` and fall back to `stdout` when `stderr` has no non-empty lines after sanitization.
- `run-with-timeout` with `--ok-codes $WINGET_OK_CODES` must print `[ok]` (not `[fail]`) for `-1978335135` and `-1978335189`, while still printing `[timeout]` on `timed_out: true`.
- `install-packages` skipping `Microsoft.PowerShell` when `pwsh` is active must **not** write `pkg:winget` to `state.hashes` (so a subsequent `ygg apply` outside `pwsh` still installs it), while `Microsoft.PowerShell` when `pwsh` is **not** active must install normally.
- `install-packages --dry-run` must not trigger `active-runtime-winget-warning` or populate `warnings`.
- `YGG_MOCK_PKG_LOG` tests that do not set `YGG_MOCK_ACTIVE_RUNTIME` must not unexpectedly skip `Nushell.Nushell` / `Microsoft.PowerShell`.

---

### Task 1: `format-pkg-failure-tail` and `--ok-codes` in `src/pkg.nu`

**Files:**
- Modify: `src/pkg.nu:5` (import `sanitize-log-line` from `progress.nu`), `src/pkg.nu:87-93` (`run-with-timeout`), `src/pkg.nu:214-225` (status check with `$ok_codes`), `src/pkg.nu:514` (add `format-pkg-failure-tail`)
- Test: `tests/test_pkg_git.nu`

**Interfaces:**
- Consumes: `sanitize-log-line [line: string]: nothing -> string` from `src/progress.nu`
- Produces:
  - `export def format-pkg-failure-tail [stderr: string, stdout: string, --max-lines: int = 5]: nothing -> string`
  - `export def run-with-timeout [argv: list<string>, timeout_sec: int, --label: string = "", --no-tty-progress, --soft-fail, --ok-codes: list<int> = [0]]: nothing -> record`

- [ ] **Step 1: Write failing unit tests in `tests/test_pkg_git.nu`**

Add tests `# regression: #14`:
- `test_format_pkg_failure_tail`:
  - prefers `stderr` over `stdout` when `stderr` has non-empty sanitized lines;
  - falls back to `stdout` when `stderr` is empty or only whitespace/ANSI;
  - splits on `[\r\n]+` and strips ANSI + `\r`-spinner fragments (e.g. `"\r\x1b[32m  -\r  \\\rFailed to install\nExit code: 1"` -> `"Failed to install\nExit code: 1"`);
  - caps output to last `--max-lines` lines (default 5);
  - returns `""` when both are empty.
- `test_run_with_timeout_ok_codes`:
  - runs a child `^nu -c "exit 42"` with `--label "test" --no-tty-progress --ok-codes [0, 42]`, asserting `exit_code == 42` and stderr contains `[ok]` (and does not contain `[fail]`).

- [ ] **Step 2: Run the new tests to verify they fail**

Run: `nu tests/run.nu --filter test_format_pkg_failure_tail` and `nu tests/run.nu --filter test_run_with_timeout_ok_codes`
Expected: FAIL (`format-pkg-failure-tail` not found / `--ok-codes` unknown flag).

- [ ] **Step 3: Implement `format-pkg-failure-tail` and `--ok-codes` in `src/pkg.nu`**

- Import `sanitize-log-line` in `use progress.nu [...]` at `src/pkg.nu:5`.
- Add `--ok-codes: list<int> = [0]` to `run-with-timeout` (`src/pkg.nu:87-93`) and update `src/pkg.nu:217` to:
  `let status = if ($exit_code in $ok_codes) { "ok" } else if $soft_fail { "warn" } else { "fail" }`
- Add `export def format-pkg-failure-tail [stderr: string, stdout: string, --max-lines: int = 5]: nothing -> string` right before `run-install-argv`: split by `[\r\n]+`, map `sanitize-log-line`, filter non-empty; prefer `$stderr` lines if non-empty else `$stdout` lines; take `last $max_lines` and `str join "\n"`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `nu tests/run.nu --filter test_format_pkg_failure_tail` and `nu tests/run.nu --filter test_run_with_timeout_ok_codes`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/pkg.nu tests/test_pkg_git.nu
git commit -m "feat(pkg): add format-pkg-failure-tail and --ok-codes on run-with-timeout"
```

---

### Task 2: `active-runtime-winget-warning` and `install-packages` Diagnostics & Runtime Guard

**Files:**
- Modify: `src/pkg.nu:515-539` (`run-install-argv`), `src/pkg.nu:543-702` (`install-packages`), add `active-runtime-winget-warning`
- Test: `tests/test_pkg_git.nu`

**Interfaces:**
- Consumes: `format-pkg-failure-tail`, `run-with-timeout --ok-codes` (from Task 1)
- Produces:
  - `export def active-runtime-winget-warning [pkg: string, ctx?: record]: nothing -> string` (when `ctx` is omitted, `os` comes from `detect-host-os` and `detect-pwsh-active` is called lazily only when `os == "windows"` and `pkg` is `microsoft.powershell*`)
  - `install-packages` return type annotation (`src/pkg.nu:552` updated): `nothing -> record<executed: list<string>, skipped: list<string>, failed: list<record<mgr: string, pkg: string, reason: string, exit_code: int, stderr: string, tail: string>>, warnings: list<record<source: string, module: string, item: string, message: string>>>`

- [ ] **Step 1: Write failing unit tests in `tests/test_pkg_git.nu`**

Add tests `# regression: #14`:
- `test_active_runtime_winget_warning`:
  - returns `""` on `os: "linux"` even for `"Nushell.Nushell"` and `"Microsoft.PowerShell"`;
  - returns non-empty warning on `os: "windows"` for `"Nushell.Nushell"` and `"nushell"` (case-insensitive);
  - returns non-empty warning on `os: "windows"` for `"Microsoft.PowerShell"` and `"Microsoft.PowerShell.Preview"` when `in_pwsh: true`, and `""` when `in_pwsh: false`;
  - returns `""` on `os: "windows"` for `"Git.Git"`.
- `test_install_packages_failure_includes_exit_code_and_tail`:
  - with `YGG_MOCK_PKG_FAIL: "winget:Bad.Pkg"`, `$res.failed.0` has `exit_code == 1`, `tail != ""`, `mgr == "winget"`, `pkg == "Bad.Pkg"`, `reason == "error"`;
  - export `run-install-argv` (or test via a small failing `^nu` script on `PATH` / `run-with-timeout` + `format-pkg-failure-tail`) to verify `stdout` fallback and `exit_code` propagation on a non-mock failure.
- `test_install_packages_skips_active_runtime_without_caching_hash`:
  - with `YGG_HOST_OS_OVERRIDE: "windows"`, `YGG_MOCK_PKG_LOG: $log`, `YGG_MOCK_ACTIVE_RUNTIME: "nu,pwsh"`, and manifest `winget = ["Nushell.Nushell", "Microsoft.PowerShell", "Git.Git"]`:
    - `$res.failed` is `[]`, `$res.skipped` is `[]`, `($res.warnings | length) == 2`, `$res.warnings.0.source == "pkg"`;
    - `$log` contains only `Git.Git` (not `Nushell.Nushell` or `Microsoft.PowerShell`);
    - `(load-state $home).hashes | get -o "pkg:winget"` is `null` (not cached!).
  - in `--dry-run` with the same `YGG_MOCK_ACTIVE_RUNTIME: "nu,pwsh"`, `$res.warnings` is `[]` and all 3 commands appear in `$res.executed`.

- [ ] **Step 2: Run the new tests to verify they fail**

Run: `nu tests/run.nu --filter test_active_runtime_winget_warning` and `nu tests/run.nu --filter test_install_packages_`
Expected: FAIL.

- [ ] **Step 3: Implement `active-runtime-winget-warning` and update `run-install-argv` / `install-packages` in `src/pkg.nu`**

- Add `detect-pwsh-active []: nothing -> bool`: in mock mode checks `("pwsh" in (csv-env "YGG_MOCK_ACTIVE_RUNTIME"))`; otherwise checks `try { ps | any { |p| $p.name =~ '(?i)^pwsh(\.exe)?$' } } catch { false }`.
- Add `active-runtime-winget-warning [pkg: string, ctx?: record]: nothing -> string` implementing the rules from RFC-064 §5.2 (evaluating `detect-pwsh-active` lazily only when `os == "windows"` and `pkg` matches `microsoft.powershell*`).
- Update `run-install-argv` (exporting it if tested directly):
  - compute `let ok_codes = if ($mgr == "winget") { $WINGET_OK_CODES } else { [0] }` **before** calling `run-with-timeout`, and pass `--ok-codes=$ok_codes`;
  - return `{ ok, reason, exit_code, stderr, stdout }` (mock fail returns `exit_code: 1, stdout: ""`; timeout returns `exit_code: 124, stdout: ($r.stdout | default "")`; normal error returns `exit_code: $r.exit_code, stdout: ($r.stdout | default "")`).
- Update `install-packages` (including its return type annotation at `src/pkg.nu:552`):
  - initialize `mut warnings: list<record> = []` and `mut mgr_skipped_runtime = false`, and include `warnings: []` in `$empty_res` and return record;
  - in `sudo_required` branch, include `exit_code: 1, tail: $msg` in `$failed`;
  - inside `for argv in $argvs` (only when `not $dry_run`, since `$dry_run` already `continue`s at line 656): if `$mgr == "winget"`, check `active-runtime-winget-warning` for `$inv_pkgs.0` (in mock mode, guard with `(($env.YGG_MOCK_ACTIVE_RUNTIME? | default "") != "")` so existing mock tests are unaffected). If non-empty: `print -e $"[ygg] Warning: ($rt_warn)"`, append `{ source: "pkg", module: $mgr, item: $inv_pkgs.0, message: $rt_warn }` to `$warnings`, set `$mgr_skipped_runtime = true`, and `continue`;
  - on `not $r.ok`: compute `$tail = (format-pkg-failure-tail $r.stderr $r.stdout)`; print `[ygg] Error: package manager '($mgr)' failed for '($pkg_str)' (($r.reason), exit ($r.exit_code))` (appending `":\n  " + ($tail | lines | str join "\n  ")` only when `$tail != ""`), append `{ mgr, pkg, reason, exit_code: $r.exit_code, stderr: $r.stderr, tail: $tail }` to `$failed`;
  - at hash-saving check (`src/pkg.nu:684`): `if (not $mgr_failed) and (not $mgr_skipped_runtime) { ... }`.

- [ ] **Step 4: Run `test_pkg_git` suite to verify all unit tests pass**

Run: `nu tests/run.nu --filter test_pkg_git`
Expected: PASS (all existing + new `# regression: #14` tests).

- [ ] **Step 5: Commit**

```bash
git add src/pkg.nu tests/test_pkg_git.nu
git commit -m "feat(pkg): surface exit_code/tail on failure and guard active nu/pwsh on winget"
```

---

### Task 3: Surface Package Diagnostics & Warnings in `bin/ygg.nu` (`apply-plan`)

**Files:**
- Modify: `bin/ygg.nu:568-571` (format `$pkg_res.failed` with `exit_code` and `tail`), `bin/ygg.nu:606` (include `$pkg_res.warnings` in `format-apply-summary`)
- Test: `tests/test_e2e_apply.nu`

**Interfaces:**
- Consumes: `$pkg_res.failed` (`mgr`, `pkg`, `reason`, `exit_code`, `tail`) and `$pkg_res.warnings` from `install-packages` (Task 2)
- Produces: updated `apply-plan` error formatting and warning count in `bin/ygg.nu`

- [ ] **Step 1: Write failing E2E tests in `tests/test_e2e_apply.nu`**

Add tests `# regression: #14`:
- `test_e2e_apply_pkg_failure_includes_exit_code_and_tail`:
  - run `ygg apply` with `YGG_MOCK_PKG_LOG: ($home | path join "pkg.log")`, `YGG_MOCK_PKG_FAIL: "winget:Bad.Pkg"`, and `YGG_HOST_OS_OVERRIDE: "windows"`;
  - assert `exit_code != 0` and `$res.stderr` contains `winget: Bad.Pkg (error, exit 1:` and `simulated failure`.
- `test_e2e_apply_active_runtime_winget_warns_and_succeeds`:
  - run `ygg apply` with `YGG_HOST_OS_OVERRIDE: "windows"`, `YGG_MOCK_PKG_LOG: ($home | path join "pkg.log")`, `YGG_MOCK_ACTIVE_RUNTIME: "nu"`, and `winget = ["Nushell.Nushell"]`;
  - assert `exit_code == 0`, `$res.stdout` contains `with 1 warning(s)`, and `$res.stderr` contains `[ygg] Warning:`.

- [ ] **Step 2: Run the new E2E tests to verify they fail**

Run: `nu tests/run.nu --filter test_e2e_apply_pkg_failure_includes_exit_code_and_tail` and `nu tests/run.nu --filter test_e2e_apply_active_runtime_winget_warns_and_succeeds`
Expected: FAIL (missing `exit 1` in error / `with 1 warning(s)` missing).

- [ ] **Step 3: Update `apply-plan` in `bin/ygg.nu`**

- At `bin/ygg.nu:568-571`, format each failed package `f`:
  - `let meta = $"($f.reason), exit ($f.exit_code? | default 1)"`
  - `let snippet = if (($f.tail? | default "") != "") { $f.tail | lines | last | str trim } else { "" }`
  - `if $snippet != "" { $"($f.mgr): ($f.pkg) \(($meta): ($snippet)\)" } else { $"($f.mgr): ($f.pkg) \(($meta)\)" }`
- At `bin/ygg.nu:606`, combine warnings as `let all_warnings = ((hook-warnings $hooks) | append ($pkg_res.warnings? | default []))` and pass `$all_warnings` to `format-apply-summary`.

- [ ] **Step 4: Run `test_e2e_apply` and `test_cli` suites**

Run: `nu tests/run.nu --filter test_e2e_apply` and `nu tests/run.nu --filter test_e2e_cli`
Expected: PASS.

- [ ] **Step 5: Full test suite, `context-init`, and commit**

Run: `mise run test` and `context-init update` + `context-init check --compact` (or MCP `context_check`).
Commit with footer `Fixes #14`:
```bash
git add bin/ygg.nu tests/test_e2e_apply.nu
git commit -m "fix(pkg): show exit code/output tail on failure and warn on active nu/pwsh" -m "Fixes #14"
```
