# src/doctor.nu
# Yggdrasil configuration manager — read-only host audit `ygg doctor` (RFC-017)
#
# Audit checks only read the filesystem, host.toml and state.json: no directories are created and
# nothing is written. `doctor-fix` (RFC-038, RFC-047) is the only mutating entry point; the CLI runs it
# under the host lock, and it touches only objects owned by ygg (state records, links into YGG_HOME or
# module directories, private files). Module-specific private files are declared by modules themselves
# in `[doctor] private_files` of their manifest.

use state.nu [load-state, save-state, expand-target-path, check-pending-journal, fs-windows, to-win32-path, restrict-file-access]
use manifest.nu [load-host-config, resolve-effective-plan]
use link.nu [resolve-link-targets, compute-link-ops, is-link-or-junction, link-literal-target, normalize-case, remove-link-only]
use env.nu [missing-secret-keys, classify-secret-value, load-secrets-env]
use pkg.nu [missing-package-managers]
use git.nu [copy-sync-status, is-canonicalizable]
use container.nu [detect-container-runtime, list-running-projects]

const MIN_NU_MINOR = 116

def finding [check: string, severity: string, target: string, detail: string, fix: string]: nothing -> record<check: string, severity: string, target: string, detail: string, fix: string> {
    { check: $check, severity: $severity, target: $target, detail: $detail, fix: $fix }
}

def to-list [value: any]: nothing -> list<string> {
    if ($value == null) { [] } else if (($value | describe) starts-with "list") { $value } else { [$value] }
}

# Files below root as relative paths (recursive, symlinks are not followed)
def list-files-rel [root: string, prefix: string = ""]: nothing -> list<string> {
    let items = (try { ls -a $root } catch { [] })
    mut out = []
    for it in $items {
        let name = ($it.name | path basename)
        let rel = if ($prefix == "") { $name } else { $prefix + "/" + $name }
        if ($it.type == "dir") {
            $out = ($out | append (list-files-rel $it.name $rel))
        } else {
            $out = ($out | append $rel)
        }
    }
    $out
}

# link / link_pending: managed links that are broken, point elsewhere or are replaced (RFC-011 ops)
def check-links [ops: table]: nothing -> list<record> {
    mut rows = []
    for o in $ops {
        if ($o.op == "RELINK") {
            $rows = ($rows | append (finding "link" "error" $o.dest $"link is dangling or points elsewhere \(expected -> '($o.src)', module '($o.module)'\)" "ygg apply"))
        } else if ($o.op == "BACKUP_REPLACE") {
            $rows = ($rows | append (finding "link" "error" $o.dest $"a real file or directory is in place of the link to '($o.src)' \(module '($o.module)'\)" "ygg apply (the existing path is moved to .state/backups/)"))
        } else if ($o.op == "LINK") {
            $rows = ($rows | append (finding "link_pending" "warn" $o.dest $"planned link to '($o.src)' \(module '($o.module)'\) is not applied yet" "ygg apply"))
        }
    }
    $rows
}

# a dangling link is owned by ygg when it is recorded in state or its literal target lies inside YGG_HOME or a module directory
def is-owned-link [p: string, state: record, roots: list<string>]: nothing -> bool {
    if ((normalize-case $p) in ($state.links | columns | append ($state.copies | columns) | each { |x| normalize-case $x })) {
        return true
    }
    let t = (link-literal-target $p)
    if ($t == "") {
        return false
    }
    let abs = if (($t | str starts-with "/") or ($t | str starts-with "\\") or ($t =~ "^[A-Za-z]:")) { $t } else { ($p | path dirname | path join $t) }
    let tn = (normalize-case ($abs | path expand -n))
    $roots | any { |r|
        let rn = (normalize-case ($r | path expand -n))
        let prefix = (($rn | str trim --right --char "/" | str trim --right --char "\\") + (char path_sep))
        ($tn == $rn) or ($tn | str starts-with $prefix)
    }
}

# orphan_link: dangling symlinks without a state record, depth 1, in ~, ~/.config, ~/.local/bin
# and the parent directories of managed paths. `owned` rows (warn) are removable by --fix; the rest are info (RFC-047)
def check-orphan-links [state: record, targets: table, sb: string, roots: list<string>]: nothing -> list<record> {
    let managed = ($state.links | columns | append ($state.copies | columns) | append ($targets | get -o dest | default []))
    let managed_norm = ($managed | each { |p| normalize-case $p })
    let base_dirs = (["~", "~/.config", "~/.local/bin"] | each { |d| expand-target-path $d --sandbox $sb })
    let dirs = ($base_dirs | append ($managed | each { |p| $p | path dirname }) | each { |d| normalize-case $d } | uniq)
    mut rows = []
    for d in $dirs {
        if (($d | path type) != "dir") {
            continue
        }
        for it in (try { ls -a $d } catch { [] }) {
            let p = $it.name
            let is_link = ($it.type == "symlink") or (try { is-link-or-junction $p } catch { false })
            if (not $is_link) or ($p | path exists) or ((normalize-case $p) in $managed_norm) {
                continue
            }
            let owned = (is-owned-link $p $state $roots)
            let row = if $owned {
                (finding "orphan_link" "warn" $p $"dangling symlink -> '(link-literal-target $p)' left by ygg" "ygg doctor --fix removes the link")
            } else {
                (finding "orphan_link" "info" $p $"dangling symlink -> '(link-literal-target $p)' does not belong to ygg" "remove the link manually if it is no longer needed")
            }
            $rows = ($rows | append ($row | insert owned $owned))
        }
    }
    $rows | uniq-by target
}

# state_orphan: state records of modules that are not in host.toml
def check-state-orphans [state: record, host_modules: list<string>]: nothing -> list<record> {
    mut rows = []
    for section in ["links", "copies"] {
        let records = ($state | get $section)
        for dest in ($records | columns) {
            let m = (($records | get $dest).module? | default "")
            if ($m not-in $host_modules) {
                $rows = ($rows | append (finding "state_orphan" "warn" $dest $"state.($section) record of module '($m)' which is not in host.toml" "ygg apply (prunes the record)"))
            }
        }
    }
    $rows | uniq-by target
}

# sync: 3-way conflicts and host edits not saved yet (RFC-004)
def check-sync [state: record]: nothing -> list<record> {
    copy-sync-status $state | each { |r|
        if ($r.status == "conflict") {
            finding "sync" "warn" $r.dest $"conflict: host and module '($r.module)' both changed the file" "ygg apply --force (take the module version) or ygg save --force (keep the host version)"
        } else {
            finding "sync" "warn" $r.dest $"pending_save: host changes are not saved to module '($r.module)'" "ygg save"
        }
    }
}

# RFC-049: input is "SID|Rights|Type" lines; insecure = Allow entry for a broad SID
export def is-windows-acl-insecure [acl_lines: string]: nothing -> bool {
    let broad = ["S-1-1-0" "S-1-5-11" "S-1-5-32-545" "S-1-5-32-546" "S-1-5-7"]
    $acl_lines | lines | any { |l|
        let parts = ($l | str trim | split row "|")
        (($parts | length) >= 3) and (($parts | get 0 | str trim | str replace -a "\u{feff}" "" | str uppercase) in $broad) and (($parts | get 2 | str trim | str lowercase) == "allow")
    }
}

# Select PowerShell binary and whether PSModulePath must be hidden for Windows PowerShell 5.1
export def select-powershell [has_pwsh: bool, has_winps: bool]: nothing -> record<bin: string, hide_module_path: bool> {
    if $has_pwsh {
        { bin: "pwsh", hide_module_path: false }
    } else if $has_winps {
        { bin: "powershell.exe", hide_module_path: true }
    } else {
        { bin: "", hide_module_path: false }
    }
}

# Read ACL of a file as "SID|Rights|Type" lines via PowerShell; ok=false when it cannot be read
def read-windows-acl [path: string]: nothing -> record<ok: bool, out: string, err: string> {
    if (($env.YGG_MOCK_WINDOWS_ACL_FAIL? | default "") == "1") {
        return { ok: false, out: "", err: "" }
    }
    let sel = (select-powershell (which pwsh | is-not-empty) (which powershell.exe | is-not-empty))
    if $sel.bin == "" {
        return { ok: false, out: "", err: "PowerShell not found" }
    }
    let script = "$p = $env:YGG_ACL_PATH; (Get-Acl -LiteralPath $p).Access | ForEach-Object { $_.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value + '|' + $_.FileSystemRights + '|' + $_.AccessControlType }"
    let win = (to-win32-path $path)
    let r = (try {
        do {
            if $sel.hide_module_path { hide-env -i PSModulePath }
            with-env { YGG_ACL_PATH: $win } { ^($sel.bin) -NoProfile -NonInteractive -Command $script | complete }
        }
    } catch { |e| { exit_code: 1, stdout: "", stderr: $e.msg } })
    if $r.exit_code != 0 {
        let first_err = ($r.stderr | lines | where { |l| ($l | str trim) != "" } | get -o 0 | default "" | str trim)
        { ok: false, out: "", err: $first_err }
    } else {
        { ok: true, out: $r.stdout, err: "" }
    }
}

# perm: private files must not be accessible by group/others (Unix) or Users/Everyone (Windows RFC-035)
export def check-perms [ygg_home: string, plan: record, sb: string]: nothing -> list<record> {
    let is_windows = (fs-windows)
    let private = ($plan.modules? | default [] | each { |m|
        to-list ($m.manifest?.doctor?.private_files? | default []) | each { |p| expand-target-path $p --sandbox $sb }
    } | flatten)
    let files = if $is_windows {
        let env_dir = ($ygg_home | path join ".state" "env")
        let env_files = (try { ls -a $env_dir | where { |it| $it.type == "file" and (($it.name | path basename) | str starts-with "env.") } | get name } catch { [] })
        [($ygg_home | path join "secrets.toml")]
        | append $env_files
        | append ($ygg_home | path join ".state" "journal.json")
        | append $private
        | uniq
    } else {
        let env_dir = ($ygg_home | path join ".state" "env")
        let env_files = (try { ls -a $env_dir | where { |it| $it.type == "file" } | get name } catch { [] })
        [($ygg_home | path join "secrets.toml")]
        | append $env_files
        | append (expand-target-path "~/.config/environment.d/99-ygg.conf" --sandbox $sb)
        | append $private
        | uniq
    }
    mut rows = []
    for f in $files {
        if not ($f | path exists) {
            continue
        }
        let real = ($f | path expand)
        if (($real | path type) != "file") {
            continue
        }
        if $is_windows {
            let mock_insecure = (($env.YGG_MOCK_WINDOWS_INSECURE_ACL? | default "") == "1")
            let mock_output = ($env.YGG_MOCK_WINDOWS_ICACLS_OUTPUT? | default "")
            mut unreadable = false
            mut unreadable_err = ""
            let is_insecure = if $mock_insecure {
                true
            } else if ($mock_output != "") {
                is-windows-acl-insecure $mock_output
            } else {
                let acl = (read-windows-acl $real)
                $unreadable = (not $acl.ok)
                $unreadable_err = $acl.err
                is-windows-acl-insecure $acl.out
            }
            if $unreadable {
                let msg = "cannot read Windows ACL (PowerShell failed or unavailable)" + (if $unreadable_err != "" { $": ($unreadable_err)" } else { "" })
                $rows = ($rows | append (finding "acl_unreadable" "warn" $f $msg "check PowerShell availability and execution policy, then re-run ygg doctor"))
            }
            if $is_insecure {
                $rows = ($rows | append (finding "perm" "error" $f "insecure Windows ACL: readable by Users/Everyone" $"icacls '($f)' /inheritance:r /grant:r \"${env:USERNAME}:F\""))
            }
            continue
        }
        # nu 0.116 `ls -lD` mode is the 9-char "rwxrwxrwx" string (no file type char)
        let mode = (try { ls -lD $real | get -o 0.mode | default "" } catch { "" })
        if ($mode == "") {
            continue
        }
        let perms = ($mode | str substring (($mode | str length) - 9)..)
        if (($perms | str substring 3..) != "------") {
            $rows = ($rows | append (finding "perm" "error" $f $"mode ($perms), expected rw-------" $"chmod 600 '($f)'"))
        }
    }
    $rows
}

# True when the Nushell version is at least (0, MIN_NU_MINOR) for major 0 and any later major (RFC-057)
export def nu-version-ok [ver: string]: nothing -> bool {
    let parts = ($ver | split row "." | each { |p| try { $p | into int } catch { 0 } })
    let major = ($parts | get -o 0 | default 0)
    let minor = ($parts | get -o 1 | default 0)
    ($major > 0) or ($minor >= $MIN_NU_MINOR)
}

# tool: nu >= 0.116, git, package managers with packages in the plan
def check-tools [plan: record]: nothing -> list<record> {
    mut rows = []
    if not (nu-version-ok (version).version) {
        $rows = ($rows | append (finding "tool" "error" "nu" $"nu ((version).version) is older than 0.($MIN_NU_MINOR)" $"upgrade nu to 0.($MIN_NU_MINOR) or newer"))
    }
    if (which git | is-empty) {
        $rows = ($rows | append (finding "tool" "error" "git" "git is not on PATH" "install git"))
    }
    for mgr in (missing-package-managers $plan) {
        $rows = ($rows | append (finding "tool" "error" $mgr $"package manager '($mgr)' has packages in the plan but is not on PATH" $"install ($mgr) or remove its packages"))
    }
    $rows
}

# collision: cross-module overrides of one destination (RFC-010)
def check-collisions [resolved: record]: nothing -> list<record> {
    $resolved.collisions? | default [] | group-by dest | values | each { |g| $g | last } | each { |c|
        finding "collision" "warn" $c.dest $"claimed by '($c.loser_module)' \(($c.loser_key)\) is overridden by '($c.winner_module)' \(($c.winner_key)\)" "keep one of the links or exclude it in host.toml"
    }
}

# Shadowed paths for display: everything below a `.git` directory collapses into `<dir>/.git/ (N files)`
def collapse-git-paths [paths: list<string>]: nothing -> list<string> {
    let tagged = ($paths | each { |p|
        let segs = ($p | split row "/")
        let idx = ($segs | enumerate | where { |s| $s.item == ".git" } | get -o 0.index)
        if ($idx == null) {
            { key: $p, git: false }
        } else {
            { key: (($segs | first ($idx + 1) | str join "/") + "/"), git: true }
        }
    })
    let git_dirs = ($tagged | where { |t| $t.git } | group-by key | transpose key rows | each { |g| $"($g.key) \(($g.rows | length) files\)" })
    $git_dirs | append ($tagged | where { |t| not $t.git } | each { |t| $t.key })
}

# shadow: a directory replaced by a link whose latest backup has files the source does not have.
# A finding acknowledged with `ygg doctor --ack-shadow` (state.acks.shadow) is `info` until a newer
# backup of the same destination appears. Rows carry `backup` (the backup directory found).
def check-shadow [ygg_home: string, targets: table, acked: list]: nothing -> list<record> {
    let bkp_root = ($ygg_home | path join ".state" "backups")
    let backups = (try { ls $bkp_root | where { |it| $it.type == "dir" } | sort-by name --reverse | get name } catch { [] })
    if ($backups | is-empty) {
        return []
    }
    mut rows = []
    for t in ($targets | where { |t| $t.is_dir }) {
        if not (is-link-or-junction $t.dest) {
            continue
        }
        let rel_dest = ($t.dest | str replace --regex '^[A-Za-z]:' '' | str replace --regex '^[\\/]+' '')
        let found = ($backups | each { |b| $b | path join $rel_dest } | where { |c| ($c | path type) == "dir" } | get -o 0 | default "")
        if ($found == "") {
            continue
        }
        let missing = (list-files-rel $found | where { |rel| ($t.src | path join $rel | path type) == null })
        if ($missing | is-not-empty) {
            let items = (collapse-git-paths $missing)
            let shown = ($items | first 5 | str join ", ")
            let more = if (($items | length) > 5) { $" and (($items | length) - 5) more" } else { "" }
            let is_acked = ($acked | any { |a| ($a.target? == $t.dest) and ($a.backup? == $found) })
            let severity = if $is_acked { "info" } else { "warn" }
            let prefix = if $is_acked { "acknowledged: " } else { "" }
            let fix = if $is_acked { $"restore manually from '($found)' if needed" } else { $"restore manually from '($found)', or acknowledge with 'ygg doctor --ack-shadow'" }
            $rows = ($rows | append ((finding "shadow" $severity $t.dest $"($prefix)latest backup has ($missing | length) file\(s\) missing in the source '($t.src)': ($shown)($more)" $fix) | insert backup $found))
        }
    }
    $rows
}

# secrets: keys of a module secrets.example.toml absent in secrets.toml (names only, RFC-024)
# secrets_materialized: warn when materialize = true and external secrets exist (RFC-042)
def check-secrets [ygg_home: string, plan: record]: nothing -> list<record> {
    let secrets = ($ygg_home | path join "secrets.toml")
    mut rows = []
    for m in ($plan.modules? | default []) {
        let tmpl = ($m.dir | path join "secrets.example.toml")
        if not ($tmpl | path exists) {
            continue
        }
        let missing = (missing-secret-keys $tmpl $secrets)
        if ($missing | is-not-empty) {
            $rows = ($rows | append (finding "secrets" "warn" $secrets $"module '($m.name)' is missing secrets: ($missing | str join ', ')" $"add the keys from '($tmpl)' to secrets.toml"))
        }
    }

    let host_cfg = (try { load-host-config $ygg_home } catch { {} })
    let materialize = ($host_cfg | get -o ygg.secrets.materialize | default false)
    if $materialize {
        let sec_env = (try { load-secrets-env $ygg_home } catch { {} })
        let has_external = ($sec_env
            | values
            | where { |v| not (($v | describe) starts-with "record") and not (($v | describe) starts-with "table") }
            | any { |v| (classify-secret-value ($v | into string)).kind != "literal" }
        )
        if $has_external {
            $rows = ($rows | append (finding "secrets_materialized" "warn" $secrets "external secrets are materialized to plaintext files on disk" "set [ygg.secrets] materialize = false in host.toml"))
        }
    }

    $rows
}

# canonical: module or link target is reachable but its path does not canonicalize (RFC-025)
def check-canonical [plan: record, targets: table]: nothing -> list<record> {
    mut rows = []
    for m in ($plan.modules? | default []) {
        if ($m.dir | path exists) and not (is-canonicalizable $m.dir) {
            $rows = ($rows | append (finding "canonical" "warn" $m.dir $"module '($m.name)' is on a volume without path canonicalization support" "copy the module to a local disk and ygg add it from there"))
        }
    }
    for t in $targets {
        if ($t.dest | path exists) and not (is-canonicalizable $t.dest) {
            $rows = ($rows | append (finding "canonical" "warn" $t.dest $"link target of module '($t.module)' does not canonicalize" "copy the module to a local disk and ygg add it from there"))
        }
    }
    $rows
}

# journal_interrupted / journal_failed: transaction status audit (RFC-043)
def check-journal [ygg_home: string]: nothing -> list<record> {
    let journal = (check-pending-journal $ygg_home)
    let journal_path = ($ygg_home | path join ".state" "journal.json")
    match $journal.state {
        "interrupted" => {
            let ts = if ($journal.started != "") { $" from ($journal.started)" } else { "" }
            [
                (finding "journal_interrupted" "error" $journal_path $"interrupted transaction($ts)" "run 'ygg apply' to recover or inspect and delete .state/journal.json")
            ]
        },
        "failed" => {
            let detail = if ($journal.error != "") {
                $"transaction failed at step '($journal.failed_step)': ($journal.error)"
            } else {
                $"transaction failed at step '($journal.failed_step)'"
            }
            [
                (finding "journal_failed" "warn" $journal_path $detail "run 'ygg apply' to recover or inspect and delete .state/journal.json")
            ]
        },
        _ => []
    }
}

# Acknowledge the shadow findings of `report` (state.acks.shadow = their {target, backup}; entries of
# findings that are gone are dropped). Only state.json is written; the CLI runs this under the host lock.
# Returns the findings that were warnings before.
export def ack-shadow [ygg_home: string, report: list]: nothing -> list<record> {
    let rows = ($report | where { |r| ($r.check == "shadow") and (($r.backup? | default "") != "") })
    let st = (load-state $ygg_home)
    save-state $ygg_home ($st | upsert acks ($st.acks | upsert shadow ($rows | each { |r| { target: $r.target, backup: $r.backup } })))
    $rows | where { |r| $r.severity == "warn" }
}

# containers: enabled stacks not running, enabled modules with unavailable runtime, or stale state.containers entries (RFC-059)
def check-containers [plan: record, state: record, --sandbox: string = ""]: nothing -> list<record> {
    let stacks = ($plan.containers? | default [])
    let enabled = ($stacks | where enabled == true)
    let st_entries = ($state.containers? | default [])
    let settings = ($plan.container_settings? | default { runtime: "", timeout: 600 })
    mut rows = []

    for e in $st_entries {
        if ($stacks | where { |s| $s.module == $e.module and $s.project == $e.project } | is-empty) {
            $rows = ($rows | append (finding "containers" "warn" $e.project $"stack recorded in state \(module '($e.module)'\) is no longer in plan" "run: ygg apply"))
        }
    }

    if ($enabled | is-not-empty) {
        let rt = (detect-container-runtime $settings --sandbox $sandbox)
        if $rt.status != "ok" {
            for m in ($enabled | get module | uniq) {
                $rows = ($rows | append (finding "containers" "warn" $m $"containers enabled for module '($m)', but runtime is unavailable \(($rt.status)\)" "run: ygg apply"))
            }
        } else {
            let running = (list-running-projects $rt.runtime)
            for s in $enabled {
                if $s.project not-in $running {
                    $rows = ($rows | append (finding "containers" "warn" $s.project $"enabled container stack \(module '($s.module)'\) is not running" "run: ygg apply"))
                }
            }
        }
    }

    $rows
}

# Read-only audit of the host (RFC-017). Rows: { check, severity (error | warn | info), target, detail, fix }.
# Checks: link, link_pending, orphan_link, state_orphan, sync, perm, tool, collision, shadow,
# secrets, canonical, journal_interrupted, journal_failed, containers; plus `plan` (error) when host.toml or a module manifest cannot be resolved.
export def run-doctor [
    ygg_home: string,
    --sandbox: string = ""
]: nothing -> list<record> {
    let sb = if ($sandbox != "") { $sandbox } else { ($env.YGG_SANDBOX? | default "") }
    let state = (load-state $ygg_home)
    let empty_plan = { modules: [], links: [], save: [], packages: {} }

    let loaded = (try {
        let host_cfg = (load-host-config $ygg_home)
        { host_modules: ($host_cfg.modules? | default [] | each { |m| $m.name }), plan: (resolve-effective-plan $ygg_home), err: "" }
    } catch { |e|
        let names = (try { load-host-config $ygg_home | get -o modules | default [] | each { |m| $m.name } } catch { [] })
        { host_modules: $names, plan: $empty_plan, err: $e.msg }
    })
    let plan = $loaded.plan
    let resolved = (resolve-link-targets $plan --sandbox $sb)
    let targets = ($resolved.targets? | default [])
    let ops = (compute-link-ops $ygg_home $resolved --sandbox $sb)

    let plan_rows = if ($loaded.err != "") {
        [(finding "plan" "error" ($ygg_home | path join "host.toml") $loaded.err "fix host.toml or the module manifest")]
    } else {
        []
    }

    [
        $plan_rows
        (check-links $ops)
        (check-orphan-links $state $targets $sb ([$ygg_home] | append ($plan.modules | each { |m| $m.dir? | default "" } | where { |d| $d != "" }) | append ($loaded.host_modules | each { |n| $ygg_home | path join "modules" $n })))
        (check-state-orphans $state $loaded.host_modules)
        (check-sync $state)
        (check-perms $ygg_home $plan $sb)
        (check-tools $plan)
        (check-collisions $resolved)
        (check-shadow $ygg_home $targets ($state.acks | get -o shadow | default []))
        (check-secrets $ygg_home $plan)
        (check-canonical $plan $targets)
        (check-journal $ygg_home)
        (check-containers $plan $state --sandbox $sb)
    ] | flatten
}

# Automatically resolve deterministic safe findings (RFC-038).
# Safe checks handled:
#   - perm: chmod 600 (Unix) or icacls reset inheritance & grant owner:F (Windows)
#   - orphan_link: only `owned = true` rows; dangling symlink removed via remove-link-only (foreign links are left)
#   - state_orphan: link on disk (if it is a symlink) removed via remove-link-only, then the record is dropped from
#     state.links / state.copies; a copy stays on disk (`record removed, file left in place`)
# Unsafe checks (sync, shadow, etc.): skipped.
# Returns list of records describing fixed findings with status: "fixed" or "failed".
export def doctor-fix [
    ygg_home: string,
    findings: list<record>,
    --sandbox: string = ""
]: nothing -> list<record> {
    let is_windows = (fs-windows)
    mut state = (load-state $ygg_home)
    mut state_changed = false
    mut fixed_list = []

    for f in $findings {
        let check = ($f.check? | default "")
        let target = ($f.target? | default "")

        match $check {
            "perm" => {
                let ok = (restrict-file-access $target)
                if $ok {
                    let done = if $is_windows { $"icacls ($target) /inheritance:r /grant:r \"${env:USERNAME}:F\"" } else { "chmod 0600" }
                    $fixed_list = ($fixed_list | append ($f | insert status "fixed" | insert action $done))
                } else {
                    $fixed_list = ($fixed_list | append ($f | insert status "failed" | insert action "failed to update permissions"))
                }
            }
            "orphan_link" => {
                if (not ($f.owned? | default false)) {
                    $fixed_list = ($fixed_list | append ($f | insert status "skipped" | insert action "link does not belong to ygg, left in place"))
                    continue
                }
                let ok = (try {
                    remove-link-only $target
                    true
                } catch {
                    false
                })
                if $ok {
                    $fixed_list = ($fixed_list | append ($f | insert status "fixed" | insert action "removed orphan link"))
                } else {
                    $fixed_list = ($fixed_list | append ($f | insert status "failed" | insert action "failed to remove orphan link"))
                }
            }
            "state_orphan" => {
                let in_links = ($target in ($state.links | columns))
                let in_copies = ($target in ($state.copies | columns))
                if $in_links or $in_copies {
                    mut action = "pruned orphaned record from state"
                    if $in_links {
                        let is_link = (try { is-link-or-junction $target } catch { false })
                        let removed = if $is_link {
                            (try { remove-link-only $target; true } catch { false })
                        } else {
                            true
                        }
                        if not $removed {
                            $fixed_list = ($fixed_list | append ($f | insert status "failed" | insert action "failed to remove link, record kept"))
                            continue
                        }
                        $action = if $is_link { "link and record removed" } else { "record removed, file left in place" }
                    } else {
                        $action = "record removed, file left in place"
                    }
                    if $in_links {
                        $state.links = ($state.links | reject $target)
                    }
                    if $in_copies {
                        $state.copies = ($state.copies | reject $target)
                    }
                    $state_changed = true
                    $fixed_list = ($fixed_list | append ($f | insert status "fixed" | insert action $action))
                } else {
                    $fixed_list = ($fixed_list | append ($f | insert status "skipped" | insert action "target not found in state"))
                }
            }
            _ => {
                # Dangerous or unfixable checks (sync, shadow, tool, etc.) are skipped
            }
        }
    }

    if $state_changed {
        save-state $ygg_home $state
    }

    $fixed_list
}

