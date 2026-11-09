# src/pkg.nu
# Yggdrasil configuration manager — Package providers driver

use state.nu [detect-host-os, get-ygg-home, load-state, save-state, expand-target-path]

# RFC-005: winget "already installed" / "no applicable upgrade" exit codes count as success
const WINGET_OK_CODES = [0, -1978335135, -1978335189]

# Managers whose package-set hash is never cached (RFC-014): fast `pacman -T` precheck instead
const UNCACHED_MGRS = ["pacman", "paru"]

# Managers checked with `pacman -T` before installing (RFC-022)
const NATIVE_MGRS = ["pacman", "paru"]

# Safe managers whose packages can be cleanly uninstalled without impacting system stability (RFC-030)
const SAFE_PRUNE_MGRS = ["uv", "mise", "pnpm", "cargo"]

# System package managers requiring --force-system-prune to uninstall (RFC-030)
const SYSTEM_PRUNE_MGRS = ["pacman", "paru", "apt", "dnf", "zypper", "brew", "winget", "scoop"]

# RFC-005 / RFC-013: package installation commands as argv lists (one invocation per entry)
def pkg-argv-list [mgr: string, pkgs: list<string>]: nothing -> list<list<string>> {
    match $mgr {
        "winget" => ($pkgs | each { |p| [winget install --exact --disable-interactivity --accept-source-agreements --accept-package-agreements $p] }),
        "scoop" => ($pkgs | each { |p| [scoop install $p] }),
        "uv" => ($pkgs | each { |p| [uv tool install $p] }),
        "brew" => [[brew install ...$pkgs]],
        "apt" => [[sudo apt-get install -y --no-install-recommends ...$pkgs]],
        "dnf" => [[sudo dnf install -y ...$pkgs]],
        "zypper" => [[sudo zypper install -y ...$pkgs]],
        "pacman" => [[sudo pacman -S --needed --noconfirm ...$pkgs]],
        "paru" => [[paru -S --needed --noconfirm ...$pkgs]],
        "mise" => [[mise use --path "~/.config/mise/config.local.toml" ...$pkgs]],
        "cargo" => [[cargo install ...$pkgs]],
        "pnpm" => [[pnpm add -g ...$pkgs]],
        _ => [[$mgr install ...$pkgs]]
    }
}

# Packages addressed by one argv invocation (per-package managers carry the last argument)
def argv-pkgs [mgr: string, argv: list<string>, pkgs: list<string>]: nothing -> list<string> {
    if ($mgr in ["winget", "scoop", "uv"]) { [($argv | last)] } else { $pkgs }
}

# RFC-013: default per-invocation timeout in seconds (0 = no timeout)
def default-pkg-timeout [mgr: string]: nothing -> int {
    match $mgr {
        "winget" | "scoop" | "uv" | "mise" | "pnpm" | "brew" | "apt" | "dnf" | "zypper" => 300,
        "cargo" | "paru" | "pacman" => 0,
        _ => 0
    }
}

# Kill a job and its whole process tree. The pids are read from `job list` strictly
# BEFORE `job kill`: afterwards the entry is gone and child processes would be orphaned.
def kill-job-tree [jid: int]: nothing -> nothing {
    let pids = (try { job list | where id == $jid | get -o 0.pids | default [] } catch { [] })
    if ($nu.os-info.family == "windows") {
        for pid in $pids {
            try { ^taskkill /T /F /PID ($pid | into string) | complete | ignore } catch { }
        }
    } else {
        for pid in $pids {
            try { ^pkill -KILL -P ($pid | into string) | complete | ignore } catch { }
            try { ^kill -KILL ($pid | into string) | complete | ignore } catch { }
        }
    }
    try { job kill $jid | ignore } catch { }
}

# Run an external command (argv form) with an optional timeout in seconds (<= 0: no timeout,
# runs inline without `job spawn`). On timeout the process tree is killed and
# { exit_code: 124, timed_out: true } is returned.
export def run-with-timeout [argv: list<string>, timeout_sec: int]: nothing -> record {
    let bin = ($argv | first)
    let args = ($argv | skip 1)
    if $timeout_sec <= 0 {
        return (try {
            ^$bin ...$args | complete
        } catch { |e|
            { exit_code: 127, stdout: "", stderr: $e.msg }
        } | insert timed_out false)
    }
    # A unique tag is required: a killed job still delivers its result later, and an
    # untagged `job recv` in the next call would receive that stale message.
    let tag = (random int 1..1000000000)
    let jid = (job spawn {
        let r = (try {
            ^$bin ...$args | complete
        } catch { |e|
            { exit_code: 127, stdout: "", stderr: $e.msg }
        })
        $r | job send 0 --tag $tag
    })
    try {
        job recv --tag $tag --timeout ($timeout_sec * 1sec) | insert timed_out false
    } catch {
        kill-job-tree $jid
        { exit_code: 124, stdout: "", stderr: $"timed out after ($timeout_sec)s", timed_out: true }
    }
}

# Package managers supported on a host, in installation order
export def allowed-package-managers [host_os: record]: nothing -> list<string> {
    if ($host_os.os == "windows") {
        ["winget", "scoop", "mise", "cargo", "pnpm", "uv"]
    } else if ($host_os.os == "macos") {
        ["brew", "mise", "cargo", "pnpm", "uv"]
    } else if ($host_os.os == "linux") {
        let is_arch = ($host_os.distro in ["cachyos", "arch"]) or ("arch" in $host_os.auto_scopes)
        let is_debian = ($host_os.distro in ["ubuntu", "debian", "pop", "mint"]) or ("debian" in $host_os.auto_scopes) or ("ubuntu" in $host_os.auto_scopes)
        let is_fedora = ($host_os.distro in ["fedora", "rhel", "centos"]) or ("fedora" in $host_os.auto_scopes) or ("rhel" in $host_os.auto_scopes)
        let is_suse = ($host_os.distro in ["opensuse", "sles", "opensuse-tumbleweed", "opensuse-leap"]) or ("opensuse" in $host_os.auto_scopes) or ("suse" in $host_os.auto_scopes)

        let native_mgrs = if $is_arch {
            ["pacman", "paru"]
        } else if $is_debian {
            ["apt"]
        } else if $is_fedora {
            ["dnf"]
        } else if $is_suse {
            ["zypper"]
        } else {
            ["apt", "dnf", "zypper", "pacman", "paru"]
        }

        let has_brew = (which brew | is-not-empty) or (($env.YGG_HOST_BREW? | default false) in [true, "true", 1, "1"]) or ($env.YGG_MOCK_PKG_ALLOWED? | default "" | split row "," | any { |m| $m == "brew" })
        let brew_list = if $has_brew { ["brew"] } else { [] }

        $native_mgrs | append $brew_list | append ["mise", "cargo", "pnpm", "uv"]
    } else {
        ["mise", "cargo", "pnpm", "uv"]
    }
}

# Managers with packages in the plan that are supported on this host but not found on PATH
# (read-only; mock: YGG_MOCK_PKG_MISSING lists the missing ones)
export def missing-package-managers [plan: record]: nothing -> list<string> {
    let pkgs_record = ($plan.packages? | default {})
    let allowed = (allowed-package-managers (detect-host-os))
    $pkgs_record | columns | where { |mgr|
        let raw = ($pkgs_record | get $mgr)
        let has_pkgs = if (($raw | describe) starts-with "list") {
            ($raw | where { |it| ($it != null) and ($it != "") } | is-not-empty)
        } else {
            ($raw != null) and ($raw != "")
        }
        let missing = if (is-mock-mode) {
            $mgr in (csv-env "YGG_MOCK_PKG_MISSING")
        } else {
            which $mgr | is-empty
        }
        ($mgr in $allowed) and $has_pkgs and $missing
    }
}

def is-mock-mode []: nothing -> bool {
    ($env.YGG_MOCK_PKG_LOG? | default "") != ""
}

def csv-env [name: string]: nothing -> list<string> {
    $env | get -o $name | default "" | split row "," | each { |s| $s | str trim } | where { |it| $it != "" }
}

# RFC-022: packages not installed yet, determined with a single `pacman -T`
# (mock: installed packages come from YGG_MOCK_PKG_INSTALLED, pacman is never run)
def missing-native-pkgs [pkgs: list<string>]: nothing -> list<string> {
    if (is-mock-mode) {
        let installed = (csv-env "YGG_MOCK_PKG_INSTALLED")
        return ($pkgs | where { |p| not ($p in $installed) })
    }
    let res = (try { ^pacman -T ...$pkgs | complete } catch { { exit_code: -1, stdout: "", stderr: "" } })
    match $res.exit_code {
        0 => [],
        127 => ($res.stdout | lines | each { |l| $l | str trim } | where { |l| $l != "" }),
        _ => $pkgs
    }
}

# RFC-022: without a TTY (or with YGG_NONINTERACTIVE=1) sudo must work without a password
# (mock: YGG_MOCK_SUDO_DENIED=1 simulates missing rights, sudo is never run)
def sudo-available []: nothing -> bool {
    if (is-mock-mode) {
        return (($env.YGG_MOCK_SUDO_DENIED? | default "") != "1")
    }
    let non_interactive = (not (is-terminal --stdin)) or (($env.YGG_NONINTERACTIVE? | default "") == "1")
    if not $non_interactive {
        return true
    }
    (try { ^sudo -n true | complete } catch { { exit_code: 1 } }).exit_code == 0
}

# RFC-014: SHA-256 of the sorted, de-duplicated package list of one manager
def pkg-set-hash [pkgs: list<string>]: nothing -> string {
    $pkgs | uniq | sort | str join "\n" | hash sha256
}

# Expand leading `~` in argv for real execution (the mock log keeps the `~/...` form)
def expand-argv [argv: list<string>]: nothing -> list<string> {
    $argv | each { |a|
        if ($a == "~") or ($a | str starts-with "~/") { $a | path expand } else { $a }
    }
}

# RFC-013: provider preparation commands (`mise trust --yes` for existing mise configs)
def provider-prep-argvs [mgr: string, sandbox: string]: nothing -> list<list<string>> {
    if ($mgr != "mise") {
        return []
    }
    ["~/.config/mise/config.toml", "~/.config/mise/config.local.toml"]
    | where { |p| (expand-target-path $p --sandbox=$sandbox) | path exists }
    | each { |p| [mise trust --yes $p] }
}

# Run (or mock-log) provider preparation; failures are warnings only
def prepare-provider-environment [mgr: string, sandbox: string, timeout: int]: nothing -> list<string> {
    mut done = []
    for argv in (provider-prep-argvs $mgr $sandbox) {
        let cmd_str = ($argv | str join " ")
        if (is-mock-mode) {
            $"($cmd_str)\n" | save -a $env.YGG_MOCK_PKG_LOG
        } else {
            let r = (run-with-timeout (expand-argv $argv) $timeout)
            if ($r.exit_code != 0) {
                print -e $"[ygg] Warning: '($cmd_str)' failed: ($r.stderr | str trim)"
            }
        }
        $done = ($done | append $cmd_str)
    }
    $done
}

# Execute one install invocation (mock-aware). Returns { ok, reason, stderr }
def run-install-argv [mgr: string, argv: list<string>, inv_pkgs: list<string>, timeout: int]: nothing -> record {
    let cmd_str = ($argv | str join " ")
    if (is-mock-mode) {
        let mock_fails = (csv-env "YGG_MOCK_PKG_FAIL")
        let hit = ($mock_fails | any { |f|
            ($f == $mgr) or ($inv_pkgs | any { |p| $f == ($mgr + ":" + $p) })
        })
        if $hit {
            return { ok: false, reason: "error", stderr: $"Package manager '($mgr)' error: simulated failure" }
        }
        $"($cmd_str)\n" | save -a $env.YGG_MOCK_PKG_LOG
        return { ok: true, reason: "", stderr: "" }
    }
    let r = (run-with-timeout (expand-argv $argv) $timeout)
    if $r.timed_out {
        return { ok: false, reason: "timeout", stderr: $r.stderr }
    }
    let ok_codes = if ($mgr == "winget") { $WINGET_OK_CODES } else { [0] }
    if ($r.exit_code in $ok_codes) {
        { ok: true, reason: "", stderr: "" }
    } else {
        { ok: false, reason: "error", stderr: ($r.stderr | default "") }
    }
}

# Install packages according to the resolved effective plan.
# Call forms: `install-packages $ygg_home $plan ...` or `install-packages $plan ...` (YGG_HOME).
export def install-packages [
    home_or_plan: any,
    maybe_plan?: any,
    --dry-run,
    --skip-packages (-S),
    --pkg: string = "",
    --pkg-timeout: int = -1,
    --refresh-packages,
    --sandbox: string = ""
]: nothing -> record<executed: list<string>, skipped: list<string>, failed: list<record<mgr: string, pkg: string, reason: string, stderr: string>>> {
    let ygg_home = if ($maybe_plan == null) { get-ygg-home } else { $home_or_plan }
    let plan = if ($maybe_plan == null) { $home_or_plan } else { $maybe_plan }
    let selected = ($pkg | split row "," | each { |s| $s | str trim } | where { |it| $it != "" })
    let empty_res = { executed: [], skipped: [], failed: [] }

    if ($selected | is-not-empty) and $skip_packages {
        error make { msg: "--pkg cannot be combined with --skip-packages" }
    }
    if $skip_packages {
        return $empty_res
    }
    # In sandbox without mock logging, protect host package managers from execution
    let env_sb = ($env.YGG_SANDBOX? | default "")
    let effective_sb = if ($sandbox != "") { $sandbox } else { $env_sb }
    let mock = (is-mock-mode)
    if (not $mock) and ($effective_sb != "") {
        return $empty_res
    }

    let pkgs_record = ($plan.packages? | default {})

    for s in $selected {
        let has = (($pkgs_record | get -o $s | default []) | is-not-empty)
        if not $has {
            print -e $"[ygg] Warning: --pkg '($s)' has no packages in the plan."
        }
    }

    if ($pkgs_record | columns | is-empty) {
        return $empty_res
    }

    let allowed_mgrs = (allowed-package-managers (detect-host-os))

    let hashes = ((load-state $ygg_home).hashes? | default {})
    mut executed: list<string> = []
    mut skipped: list<string> = []
    mut failed: list<record> = []
    mut new_hashes: record = {}
    mut new_packages: record = {}

    for mgr in ($pkgs_record | columns) {
        if not ($mgr in $allowed_mgrs) {
            continue
        }
        if ($selected | is-not-empty) and not ($mgr in $selected) {
            continue
        }

        let raw_pkgs = ($pkgs_record | get $mgr)
        let pkgs = if (($raw_pkgs | describe) starts-with "list") {
            $raw_pkgs | where { |it| ($it != null) and ($it != "") }
        } else if ($raw_pkgs != null) and ($raw_pkgs != "") {
            [$raw_pkgs]
        } else {
            []
        }
        if ($pkgs | is-empty) {
            continue
        }

        # RFC-002: skip managers that are not installed (mockable via YGG_MOCK_PKG_MISSING)
        let is_missing = if $mock {
            ($mgr in (csv-env "YGG_MOCK_PKG_MISSING"))
        } else {
            (which $mgr | is-empty)
        }
        if $is_missing {
            print -e $"[ygg] Warning: Package manager '($mgr)' not found on PATH. Skipping ($pkgs | length) package\(s\)."
            continue
        }

        # RFC-014: package-set cache (bypassed by --refresh-packages and an explicit --pkg)
        let cacheable = not ($mgr in $UNCACHED_MGRS)
        let set_hash = (pkg-set-hash $pkgs)
        let hash_key = $"pkg:($mgr)"
        if $cacheable and (not $refresh_packages) and ($selected | is-empty) and (($hashes | get -o $hash_key) == $set_hash) {
            $skipped = ($skipped | append $mgr)
            $new_packages = ($new_packages | upsert $mgr $pkgs)
            continue
        }

        # RFC-022: only packages that are not installed yet reach pacman / paru
        let todo = if ($mgr in $NATIVE_MGRS) { missing-native-pkgs $pkgs } else { $pkgs }
        if ($todo | is-empty) {
            $new_packages = ($new_packages | upsert $mgr $pkgs)
            continue
        }

        let timeout = if ($pkg_timeout >= 0) { $pkg_timeout } else { default-pkg-timeout $mgr }
        let argvs = (pkg-argv-list $mgr $todo)

        if $dry_run {
            let prep = (provider-prep-argvs $mgr $effective_sb | each { |a| $a | str join " " })
            $executed = ($executed | append $prep | append ($argvs | each { |a| $a | str join " " }))
            continue
        }

        if ($mgr in $NATIVE_MGRS) and not (sudo-available) {
            let msg = $"Package manager '($mgr)' requires sudo, which is not available non-interactively. Run 'sudo -v' first or install manually: ($todo | str join ' ')"
            print -e $"[ygg] Error: ($msg)"
            $failed = ($failed | append { mgr: $mgr, pkg: ($todo | str join " "), reason: "sudo_required", stderr: $msg })
            continue
        }

        let prep_done = (prepare-provider-environment $mgr $effective_sb $timeout)
        $executed = ($executed | append $prep_done)

        mut mgr_failed = false
        for argv in $argvs {
            let inv_pkgs = (argv-pkgs $mgr $argv $todo)
            let r = (run-install-argv $mgr $argv $inv_pkgs $timeout)
            if $r.ok {
                $executed = ($executed | append ($argv | str join " "))
            } else {
                $mgr_failed = true
                let pkg_str = ($inv_pkgs | str join " ")
                print -e $"Package manager '($mgr)' failed for '($pkg_str)' \(($r.reason)\): ($r.stderr | str trim)"
                $failed = ($failed | append { mgr: $mgr, pkg: $pkg_str, reason: $r.reason, stderr: $r.stderr })
            }
        }

        if (not $mgr_failed) {
            if $cacheable {
                $new_hashes = ($new_hashes | upsert $hash_key $set_hash)
            }
            $new_packages = ($new_packages | upsert $mgr $pkgs)
        }
    }

    # Hash and state.packages are stored only for successful managers on a real (or mock-logged) run
    if ($new_hashes | columns | is-not-empty) or ($new_packages | columns | is-not-empty) {
        let st = (load-state $ygg_home)
        let merged_hashes = ($st.hashes? | default {} | merge $new_hashes)
        let merged_packages = ($st.packages? | default {} | merge $new_packages)
        save-state $ygg_home ($st | upsert hashes $merged_hashes | upsert packages $merged_packages)
    }

    { executed: $executed, skipped: $skipped, failed: $failed }
}

# RFC-030: package uninstallation command as a shell string
def pkg-uninstall-cmd [mgr: string, pkg: string]: nothing -> string {
    match $mgr {
        "uv" => $"uv tool uninstall ($pkg)",
        "mise" => $"mise uninstall ($pkg)",
        "pnpm" => $"pnpm remove -g ($pkg)",
        "cargo" => $"cargo uninstall ($pkg)",
        "pacman" => $"sudo pacman -R --noconfirm ($pkg)",
        "paru" => $"paru -R --noconfirm ($pkg)",
        "apt" => $"sudo apt-get remove -y ($pkg)",
        "dnf" => $"sudo dnf remove -y ($pkg)",
        "zypper" => $"sudo zypper remove -y ($pkg)",
        "brew" => $"brew uninstall ($pkg)",
        "winget" => $"winget uninstall --exact ($pkg)",
        "scoop" => $"scoop uninstall ($pkg)",
        _ => $"($mgr) uninstall ($pkg)"
    }
}

# RFC-030: prune packages that are in state.packages but absent in current plan
export def prune-unused-packages [
    ygg_home: string,
    current_plan: record,
    --dry-run,
    --force-system-prune
]: nothing -> list<string> {
    let state = (load-state $ygg_home)
    let state_pkgs = ($state.packages? | default {})
    let plan_pkgs_rec = ($current_plan.packages? | default {})
    let mock = (is-mock-mode)

    mut executed_cmds: list<string> = []
    mut updated_packages: record = $state_pkgs
    mut updated_hashes: record = ($state.hashes? | default {})

    for mgr in ($state_pkgs | columns) {
        let is_safe = ($mgr in $SAFE_PRUNE_MGRS)
        if (not $is_safe) and (not $force_system_prune) {
            continue
        }

        let prev_pkgs_raw = ($state_pkgs | get $mgr)
        let prev_pkgs: list<string> = if (($prev_pkgs_raw | describe) starts-with "list") {
            $prev_pkgs_raw | where { |p| ($p != null) and ($p != "") }
        } else if ($prev_pkgs_raw != null) and ($prev_pkgs_raw != "") {
            [$prev_pkgs_raw]
        } else {
            []
        }

        let plan_pkgs_raw = ($plan_pkgs_rec | get -o $mgr | default [])
        let plan_pkgs: list<string> = if (($plan_pkgs_raw | describe) starts-with "list") {
            $plan_pkgs_raw | where { |p| ($p != null) and ($p != "") }
        } else if ($plan_pkgs_raw != null) and ($plan_pkgs_raw != "") {
            [$plan_pkgs_raw]
        } else {
            []
        }

        let stale_pkgs = ($prev_pkgs | where { |p| not ($p in $plan_pkgs) })
        if ($stale_pkgs | is-empty) {
            continue
        }

        mut pruned_this_mgr: list<string> = []
        for pkg in $stale_pkgs {
            let cmd_str = (pkg-uninstall-cmd $mgr $pkg)
            $executed_cmds = ($executed_cmds | append $cmd_str)

            if $dry_run {
                continue
            }

            if $mock {
                $"($cmd_str)\n" | save -a $env.YGG_MOCK_PKG_LOG
                $pruned_this_mgr = ($pruned_this_mgr | append $pkg)
            } else {
                let argv = ($cmd_str | split row " ")
                let timeout = (default-pkg-timeout $mgr)
                let r = (run-with-timeout (expand-argv $argv) $timeout)
                if ($r.exit_code == 0) {
                    $pruned_this_mgr = ($pruned_this_mgr | append $pkg)
                } else {
                    print -e $"[ygg] Warning: Failed to prune '($pkg)' with '($mgr)': ($r.stderr | str trim)"
                }
            }
        }

        if (not $dry_run) and ($pruned_this_mgr | is-not-empty) {
            let remaining = ($prev_pkgs | where { |p| not ($p in $pruned_this_mgr) })
            let cur_pkgs = $updated_packages
            let cur_hashes = $updated_hashes
            if ($remaining | is-empty) {
                $updated_packages = (try { $cur_pkgs | reject $mgr } catch { $cur_pkgs | upsert $mgr [] })
                $updated_hashes = (try { $cur_hashes | reject $"pkg:($mgr)" } catch { $cur_hashes })
            } else {
                $updated_packages = ($cur_pkgs | upsert $mgr $remaining)
                $updated_hashes = ($cur_hashes | upsert $"pkg:($mgr)" (pkg-set-hash $remaining))
            }
        }
    }

    if (not $dry_run) and ($executed_cmds | is-not-empty) {
        save-state $ygg_home ($state | upsert packages $updated_packages | upsert hashes $updated_hashes)
    }

    $executed_cmds
}
