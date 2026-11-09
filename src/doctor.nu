# src/doctor.nu
# Yggdrasil configuration manager — read-only host audit `ygg doctor` (RFC-017)
#
# Every check only reads the filesystem, host.toml and state.json: no directories are created,
# nothing is written, nothing is fixed automatically. Module-specific private files are declared
# by modules themselves in `[doctor] private_files` of their manifest.

use state.nu [load-state, expand-target-path, check-pending-journal, detect-host-os, to-win32-path]
use manifest.nu [load-host-config, resolve-effective-plan]
use link.nu [resolve-link-targets, compute-link-ops, is-link-or-junction, link-literal-target, normalize-case]
use env.nu [missing-secret-keys]
use pkg.nu [missing-package-managers]
use git.nu [copy-sync-status, is-canonicalizable]

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

# orphan_link: dangling symlinks without a state record, depth 1, in ~, ~/.config, ~/.local/bin
# and the parent directories of managed paths
def check-orphan-links [state: record, targets: table, sb: string]: nothing -> list<record> {
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
            $rows = ($rows | append (finding "orphan_link" "warn" $p $"dangling symlink -> '(link-literal-target $p)' is not managed by ygg" "remove the link manually if it is no longer needed"))
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

export def is-windows-acl-insecure [output: string]: nothing -> bool {
    let re = '(?i)(BUILTIN\\Users|Everyone|NT AUTHORITY\\Authenticated Users):[^\r\n]*?\((R|F|M|RX)\)'
    $output =~ $re
}

# perm: private files must not be accessible by group/others (Unix) or Users/Everyone (Windows RFC-035)
export def check-perms [ygg_home: string, plan: record, sb: string]: nothing -> list<record> {
    let host_os = (detect-host-os)
    let is_windows = ($host_os.os == "windows")
    let private = ($plan.modules? | default [] | each { |m|
        to-list ($m.manifest?.doctor?.private_files? | default []) | each { |p| expand-target-path $p --sandbox $sb }
    } | flatten)
    let files = if $is_windows {
        [
            ($ygg_home | path join "secrets.toml")
            ($ygg_home | path join ".state" "env" "env.ps1")
        ]
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
            let is_insecure = if $mock_insecure {
                true
            } else if ($mock_output != "") {
                is-windows-acl-insecure $mock_output
            } else if (which icacls.exe | is-not-empty) or (which icacls | is-not-empty) {
                let cmd = if (which icacls.exe | is-not-empty) { "icacls.exe" } else { "icacls" }
                let out = (try { ^$cmd (to-win32-path $real) | complete | get stdout } catch { "" })
                is-windows-acl-insecure $out
            } else {
                false
            }
            if $is_insecure {
                $rows = ($rows | append (finding "perm" "error" $f "insecure Windows ACL: readable by Users/Everyone" $"icacls '($f)' /inheritance:r /grant:r %USERNAME%:F"))
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

# tool: nu >= 0.116, git, package managers with packages in the plan
def check-tools [plan: record]: nothing -> list<record> {
    mut rows = []
    let ver = ((version).version | split row "." | each { |p| try { $p | into int } catch { 0 } })
    if (($ver | get -o 0 | default 0) == 0) and (($ver | get -o 1 | default 0) < $MIN_NU_MINOR) {
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

# shadow: a directory replaced by a link whose latest backup has files the source does not have
def check-shadow [ygg_home: string, targets: table]: nothing -> list<record> {
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
            let shown = ($missing | first 5 | str join ", ")
            let more = if (($missing | length) > 5) { $" and (($missing | length) - 5) more" } else { "" }
            $rows = ($rows | append (finding "shadow" "warn" $t.dest $"latest backup has ($missing | length) file\(s\) missing in the source '($t.src)': ($shown)($more)" $"restore manually from '($found)'"))
        }
    }
    $rows
}

# secrets: keys of a module secrets.example.toml absent in secrets.toml (names only, RFC-024)
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

# journal_incomplete: pending WAL transaction from an interrupted run (RFC-027)
def check-journal [ygg_home: string]: nothing -> list<record> {
    let journal = (check-pending-journal $ygg_home)
    if ($journal.incomplete? | default false) {
        let ts = ($journal.timestamp? | default "unknown")
        let steps_info = if ($journal.steps? != null) {
            let active = ($journal.steps | transpose k v | where v in ["IN_PROGRESS", "COMMITTED"] | each { |r| $"($r.k):($r.v)" } | str join ", ")
            if ($active != "") { $" \(last steps: ($active)\)" } else { "" }
        } else { "" }
        [
            (finding "journal_incomplete" "error" ($ygg_home | path join ".state" "journal.json") $"interrupted transaction from ($ts)($steps_info)" "run 'ygg apply' to recover or inspect and delete .state/journal.json")
        ]
    } else {
        []
    }
}

# Read-only audit of the host (RFC-017). Rows: { check, severity (error | warn), target, detail, fix }.
# Checks: link, link_pending, orphan_link, state_orphan, sync, perm, tool, collision, shadow,
# secrets, canonical, journal_incomplete; plus `plan` (error) when host.toml or a module manifest cannot be resolved.
export def run-doctor [
    ygg_home: string,
    --sandbox: string = ""
]: nothing -> table<check: string, severity: string, target: string, detail: string, fix: string> {
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
        (check-orphan-links $state $targets $sb)
        (check-state-orphans $state $loaded.host_modules)
        (check-sync $state)
        (check-perms $ygg_home $plan $sb)
        (check-tools $plan)
        (check-collisions $resolved)
        (check-shadow $ygg_home $targets)
        (check-secrets $ygg_home $plan)
        (check-canonical $plan $targets)
        (check-journal $ygg_home)
    ] | flatten
}
