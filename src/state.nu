# src/state.nu
# Yggdrasil configuration manager — state & path utilities

# Get YGG_HOME directory path (defaults to ~/.ygg)
export def get-ygg-home []: nothing -> string {
    let env_home = ($env.YGG_HOME? | default "")
    if ($env_home != "") {
        $env_home | path expand
    } else {
        "~/.ygg" | path expand
    }
}

# Ensure YGG_HOME is explicitly set when running in sandbox mode
export def assert-sandbox-home [sandbox: string]: nothing -> nothing {
    let effective = if ($sandbox != "") {
        $sandbox
    } else {
        ($env.YGG_SANDBOX? | default "")
    }

    if ($effective != "") {
        let env_home = ($env.YGG_HOME? | default "")
        if ($env_home == "") {
            error make { msg: "Running with --sandbox or YGG_SANDBOX requires explicit YGG_HOME to prevent mutating host ~/.ygg" }
        }
    }
}

# Ensure base directory structure in YGG_HOME
export def ensure-ygg-dirs [ygg_home: string]: nothing -> nothing {
    mkdir ($ygg_home | path join "modules")
    mkdir ($ygg_home | path join ".state" "backups")
    mkdir ($ygg_home | path join ".state" "env")
}

# Load current state from .state/state.json
export def load-state [ygg_home: string]: nothing -> record {
    let state_file = ($ygg_home | path join ".state" "state.json")
    let default_state = { links: {}, copies: {}, hashes: {}, packages: {} }

    if not ($state_file | path exists) {
        return $default_state
    }

    let loaded = (try {
        let val = (open $state_file)
        if not (($val | describe) starts-with "record") {
            error make { msg: "top-level value is not an object" }
        }
        $val
    } catch { |e|
        error make { msg: $"Cannot parse ($state_file): ($e.msg). Refusing to continue; restore from .state/state.json.bak or delete the file." }
    })
    {
        links: ($loaded.links? | default {}),
        copies: ($loaded.copies? | default {}),
        hashes: ($loaded.hashes? | default {}),
        packages: ($loaded.packages? | default {})
    }
}

# Atomically save state to .state/state.json
export def save-state [ygg_home: string, state: record]: nothing -> nothing {
    let state_dir = ($ygg_home | path join ".state")
    if not ($state_dir | path exists) {
        mkdir $state_dir
    }
    let state_file = ($state_dir | path join "state.json")
    let rand_id = (random chars --length 8)
    let tmp_file = ($state_dir | path join $"state.json.tmp.($rand_id)")

    $state | to json --indent 2 | save -f $tmp_file
    if ($state_file | path exists) {
        cp -f $state_file ($state_dir | path join "state.json.bak")
    }
    mv -f $tmp_file $state_file
}

# Detect host OS, distribution, and auto-discovered scopes
export def detect-host-os []: nothing -> record<os: string, distro: string, auto_scopes: list<string>> {
    let override = ($env.YGG_HOST_OS_OVERRIDE? | default "")
    if ($override != "") {
        let o = ($override | str lowercase)
        if ($o == "windows") {
            return { os: "windows", distro: "windows", auto_scopes: ["windows"] }
        } else if ($o in ["macos", "darwin"]) {
            return { os: "macos", distro: "macos", auto_scopes: ["macos", "unix", "darwin"] }
        } else if ($o == "cachyos") {
            return { os: "linux", distro: "cachyos", auto_scopes: ["linux", "unix", "cachyos", "arch"] }
        } else if ($o == "arch") {
            return { os: "linux", distro: "arch", auto_scopes: ["linux", "unix", "arch"] }
        } else if ($o in ["ubuntu", "debian", "pop", "mint"]) {
            return { os: "linux", distro: $o, auto_scopes: (["linux", "unix", $o, "debian"] | uniq) }
        } else if ($o in ["fedora", "rhel", "centos"]) {
            return { os: "linux", distro: $o, auto_scopes: (["linux", "unix", $o, "fedora", "rhel"] | uniq) }
        } else if ($o in ["opensuse", "sles", "opensuse-tumbleweed", "opensuse-leap"]) {
            return { os: "linux", distro: $o, auto_scopes: (["linux", "unix", $o, "opensuse", "suse"] | uniq) }
        } else if ($o == "linux") {
            return { os: "linux", distro: "linux", auto_scopes: ["linux", "unix"] }
        } else {
            return { os: $o, distro: $o, auto_scopes: [$o] }
        }
    }

    if ($nu.os-info.family == "windows") {
        return { os: "windows", distro: "windows", auto_scopes: ["windows"] }
    }

    if ($nu.os-info.family == "macos") or ($nu.os-info.name == "darwin") {
        return { os: "macos", distro: "macos", auto_scopes: ["macos", "unix", "darwin"] }
    }

    # Linux / Unix
    mut distro = "linux"
    mut scopes = ["linux", "unix"]

    if ("/etc/os-release" | path exists) {
        let lines = (open --raw "/etc/os-release" | lines)
        mut id_val = ""
        mut id_like_val = ""

        for line in $lines {
            let trimmed = ($line | str trim)
            if ($trimmed | str starts-with "ID=") {
                $id_val = ($trimmed | str substring 3.. | str trim -c '"' | str trim -c "'" | str lowercase)
            } else if ($trimmed | str starts-with "ID_LIKE=") {
                $id_like_val = ($trimmed | str substring 8.. | str trim -c '"' | str trim -c "'" | str lowercase)
            }
        }

        if ($id_val != "") {
            $distro = $id_val
            $scopes = ($scopes | append $id_val)
        }

        if ($id_like_val != "") {
            for like_item in ($id_like_val | split row " ") {
                let clean_like = ($like_item | str trim)
                if ($clean_like != "") {
                    $scopes = ($scopes | append $clean_like)
                }
            }
        }
    }

    {
        os: "linux",
        distro: $distro,
        auto_scopes: ($scopes | uniq)
    }
}

# Expand target paths with support for ~, $APPDATA, $LOCALAPPDATA, $DOCUMENTS
# and full re-rooting inside sandbox when specified or YGG_SANDBOX is set
export def expand-target-path [raw_path: string, --sandbox: string = ""]: nothing -> string {
    let sb = if ($sandbox != "") {
        $sandbox
    } else {
        ($env.YGG_SANDBOX? | default "")
    }

    let norm = $raw_path

    if ($norm == "~") {
        if ($sb != "") {
            return $sb
        } else {
            return ("~" | path expand)
        }
    }

    if ($norm | str starts-with "~/") or ($norm | str starts-with "~\\") {
        let rel = ($norm | str substring 2.. | str replace --all "/" (char path_sep) | str replace --all "\\" (char path_sep))
        if ($sb != "") {
            return ($sb | path join $rel)
        } else {
            return (("~" | path expand) | path join $rel)
        }
    }

    if ($norm == "$APPDATA") or ($norm | str starts-with "$APPDATA/") or ($norm | str starts-with "$APPDATA\\") {
        let rel = if ($norm == "$APPDATA") { "" } else { ($norm | str substring 9.. | str replace --all "/" (char path_sep) | str replace --all "\\" (char path_sep)) }
        let base = if ($sb != "") {
            ($sb | path join "AppData" "Roaming")
        } else if ($nu.os-info.family == "windows") {
            ($env.APPDATA? | default (("~" | path expand) | path join "AppData" "Roaming"))
        } else {
            (("~" | path expand) | path join ".config")
        }
        return (if ($rel == "") { $base } else { ($base | path join $rel) })
    }

    if ($norm == "$LOCALAPPDATA") or ($norm | str starts-with "$LOCALAPPDATA/") or ($norm | str starts-with "$LOCALAPPDATA\\") {
        let rel = if ($norm == "$LOCALAPPDATA") { "" } else { ($norm | str substring 14.. | str replace --all "/" (char path_sep) | str replace --all "\\" (char path_sep)) }
        let base = if ($sb != "") {
            ($sb | path join "AppData" "Local")
        } else if ($nu.os-info.family == "windows") {
            ($env.LOCALAPPDATA? | default (("~" | path expand) | path join "AppData" "Local"))
        } else {
            (("~" | path expand) | path join ".local" "share")
        }
        return (if ($rel == "") { $base } else { ($base | path join $rel) })
    }

    if ($norm == "$DOCUMENTS") or ($norm | str starts-with "$DOCUMENTS/") or ($norm | str starts-with "$DOCUMENTS\\") {
        let rel = if ($norm == "$DOCUMENTS") { "" } else { ($norm | str substring 11.. | str replace --all "/" (char path_sep) | str replace --all "\\" (char path_sep)) }
        let base = if ($sb != "") {
            ($sb | path join "Documents")
        } else if ($nu.os-info.family == "windows") {
            let pwsh_res = (try { ^pwsh -NoProfile -Command "[Environment]::GetFolderPath('MyDocuments')" | complete } catch {
                try { ^powershell -NoProfile -Command "[Environment]::GetFolderPath('MyDocuments')" | complete } catch { { exit_code: 1, stdout: "" } }
            })
            if ($pwsh_res.exit_code == 0) and (($pwsh_res.stdout | str trim) != "") {
                ($pwsh_res.stdout | str trim)
            } else {
                (("~" | path expand) | path join "Documents")
            }
        } else {
            (("~" | path expand) | path join "Documents")
        }
        return (if ($rel == "") { $base } else { ($base | path join $rel) })
    }

    # If it is already an absolute path under home-path and sandbox is active, re-root it
    if ($sb != "") {
        let home = ("~" | path expand)
        let exp = ($raw_path | path expand -n)
        if ($exp | str starts-with $home) {
            let rel = ($exp | str substring (($home | str length)..) | str trim -c "/" | str trim -c "\\")
            return ($sb | path join $rel)
        }
        return $exp
    }

    $raw_path | path expand -n
}

# Move regular file or directory to centralized backup directory
export def backup-existing [ygg_home: string, target_path: string]: nothing -> string {
    let ptype = ($target_path | path type)
    if ($ptype == null) {
        return ""
    }

    let timestamp = (date now | format date "%Y%m%d_%H%M%S_%f")
    let backup_dir = ($ygg_home | path join ".state" "backups" $timestamp)

    # Sanitize path to create relative subpath
    # Remove Windows drive letter prefix (e.g. C:) and leading slashes
    let sanitized = ($target_path | str replace --regex '^[A-Za-z]:' '' | str replace --regex '^[\\/]+' '')
    let dest_path = ($backup_dir | path join $sanitized)

    mkdir ($dest_path | path dirname)
    mv $target_path $dest_path

    $dest_path
}

# Convert a path to Windows form for cmd.exe arguments. Uses `path expand -n` so
# symlinks are NOT resolved to their targets (Zero-Data-Loss for del/rmdir).
export def to-win32-path [p: string]: nothing -> string {
    $p | path expand -n | str replace -a "/" "\\"
}

# Restrict file permissions to current user only (0600 on Unix, inheritance reset & owner:F on Windows) (RFC-049)
export def restrict-file-access [path: string]: nothing -> bool {
    let host_os = (detect-host-os)
    let is_windows = ($host_os.os == "windows")
    if $is_windows {
        let win_path = (to-win32-path $path)
        let user = ($env.USERNAME? | default ($env.USER? | default ""))
        let cmd = if (which icacls.exe | is-not-empty) { "icacls.exe" } else { "icacls" }
        let res = (try {
            if ($user != "") {
                ^$cmd $win_path /inheritance:r $"/grant:r" $"($user):F" | complete
            } else {
                ^$cmd $win_path /inheritance:r | complete
            }
        } catch { { exit_code: 1 } })
        $res.exit_code == 0
    } else {
        let res = (try { ^chmod 0600 $path | complete } catch { { exit_code: 1 } })
        $res.exit_code == 0
    }
}


# Coerce a PID read from a journal or lock file to int; anything unparsable becomes 0 (dead)
def coerce-pid [value: any]: nothing -> int {
    try { $value | into int } catch { 0 }
}

# Check if a process with given PID is still running (EPERM on Unix counts as alive, RFC-046)
export def check-process-alive [pid: int]: nothing -> bool {
    if $pid <= 0 {
        return false
    }
    if $nu.os-info.family == "windows" {
        let res = (try {
            ^tasklist /FI $"PID eq ($pid)" /FO CSV /NH | complete
        } catch {
            { exit_code: 1, stdout: "" }
        })
        if $res.exit_code != 0 {
            return false
        }
        let pids = ($res.stdout | lines | where { |l| $l | str trim | is-not-empty } | each { |l|
            let cols = (try { $l | from csv --noheaders } catch { [] })
            if ($cols | is-empty) { "" } else { $cols | first | get -o column1 | default "" | into string | str trim }
        })
        $pids | any { |c| $c == ($pid | into string) }
    } else {
        let res = (try {
            ^kill -0 $pid | complete
        } catch {
            { exit_code: 1, stderr: "" }
        })
        ($res.exit_code == 0) or ($res.stderr? | default "" | str contains "Operation not permitted")
    }
}

# Create hard link $link -> $target; true on success (fails if $link exists)
def hard-link-file [target: string, link: string]: nothing -> bool {
    let res = (try {
        if $nu.os-info.family == "windows" {
            ^cmd /c mklink /H (to-win32-path $link) (to-win32-path $target) | complete
        } else {
            ^ln $target $link | complete
        }
    } catch { { exit_code: 1 } })
    $res.exit_code == 0
}

# Acquire exclusive advisory host lock in $YGG_HOME/.state/host.lock (RFC-026, RFC-046)
export def acquire-host-lock [ygg_home: string, command: string, --no-lock]: nothing -> string {
    if $no_lock or (($env.YGG_NO_LOCK? | default "") == "1") {
        return ""
    }
    ensure-ygg-dirs $ygg_home
    let state_dir = ($ygg_home | path join ".state")
    let lock_file = ($state_dir | path join "host.lock")
    let my_host = (try { sys host | get hostname } catch { "" })

    # Legacy lock name: live PID refuses, otherwise removed (RFC-046 p.6)
    let legacy = ($state_dir | path join "ygg.lock")
    if ($legacy | path exists) {
        let ld = (try { open $legacy | from json | if (($in | describe) starts-with "record") { $in } else { {} } } catch { {} })
        let lpid = (coerce-pid ($ld.pid? | default 0))
        if (check-process-alive $lpid) {
            error make { msg: $"Host is locked by another ygg instance \(PID: ($lpid), legacy lock '($legacy)'\). Aborting." }
        }
        try { rm -f $legacy } catch { }
    }

    let payload = {
        pid: $nu.pid,
        timestamp: (date now | format date "%Y-%m-%dT%H:%M:%SZ"),
        command: $command,
        user: ($env.USER? | default ($env.USERNAME? | default "")),
        host: $my_host
    }
    let tmp = ($state_dir | path join $"host.lock.($nu.pid).(random int 0..2147483646)")
    $payload | to json | save -f $tmp

    let result = (try {
        mut taken = (hard-link-file $tmp $lock_file)
        if not $taken {
            let lock_data = (try { open $lock_file | from json | if (($in | describe) starts-with "record") { $in } else { {} } } catch { {} })
            let lock_pid = (coerce-pid ($lock_data.pid? | default 0))
            let lock_host = ($lock_data.host? | default $my_host)
            if $lock_host != $my_host {
                error make { msg: $"Host lock '($lock_file)' is held by another machine '($lock_host)' \(PID: ($lock_pid)\). Remove the file manually if it is stale." }
            }
            if (check-process-alive $lock_pid) {
                error make { msg: $"Host is locked by another ygg instance \(PID: ($lock_pid), Command: '($lock_data.command? | default "unknown")', Started: ($lock_data.timestamp? | default "")\). Aborting." }
            }
            print -e $"[ygg] Warning: Removing stale lock from terminated process \(PID ($lock_pid)\)."
            let stale = ($state_dir | path join $"host.lock.stale.(random int 0..2147483646)")
            let moved = (try { mv $lock_file $stale; true } catch { false })
            if $moved {
                let moved_pid = (coerce-pid (try { open $stale | from json | get -o pid | default 0 } catch { 0 }))
                if $moved_pid != $lock_pid {
                    # Took over a lock that was acquired meanwhile: put it back
                    hard-link-file $stale $lock_file | ignore
                    try { rm -f $stale } catch { }
                    error make { msg: "Host lock changed during stale takeover. Aborting." }
                }
                try { rm -f $stale } catch { }
                $taken = (hard-link-file $tmp $lock_file)
            }
            if not $taken {
                error make { msg: "Host is locked by another ygg instance (lost stale takeover race). Aborting." }
            }
        }
        { ok: true }
    } catch { |e|
        { ok: false, msg: ($e.msg? | default "lock failed") }
    })
    try { rm -f $tmp } catch { }
    if not $result.ok {
        error make { msg: $result.msg }
    }
    $lock_file
}

# Release advisory host lock; only if owned by the current process (RFC-026, RFC-046)
export def release-host-lock [lock_file: string]: nothing -> nothing {
    if ($lock_file != "") and ($lock_file | path exists) {
        let owner = (try { open $lock_file | from json | get -o pid | default 0 } catch { 0 })
        if $owner == $nu.pid {
            try { rm -f $lock_file } catch { }
        }
    }
}

# Begin transaction journal in $YGG_HOME/.state/journal.json (RFC-043)
export def begin-journal-transaction [ygg_home: string, plan: record, command: string = "apply"]: nothing -> string {
    ensure-ygg-dirs $ygg_home
    let state_dir = ($ygg_home | path join ".state")
    let journal_file = ($state_dir | path join "journal.json")
    let plan_str = ($plan | to json)
    let plan_hash = ($plan_str | hash sha256)
    let payload = {
        version: 2,
        pid: $nu.pid,
        command: $command,
        started: (date now | format date "%Y-%m-%dT%H:%M:%SZ"),
        plan_hash: $plan_hash,
        status: "in_progress",
        failed_step: "",
        error: "",
        steps: {
            prune_packages: "PENDING",
            packages: "PENDING",
            links: "PENDING",
            setup: "PENDING",
            env: "PENDING",
            services: "PENDING",
            finalize: "PENDING"
        }
    }
    let rand_id = (random chars --length 8)
    let tmp_file = ($state_dir | path join $"journal.json.tmp.($rand_id)")
    $payload | to json --indent 2 | save -f $tmp_file
    restrict-file-access $tmp_file | ignore
    mv -f $tmp_file $journal_file
    restrict-file-access $journal_file | ignore
    $journal_file
}

# Atomically update step status in transaction journal (RFC-043)
export def record-journal-step [ygg_home: string, step_name: string, status: string]: nothing -> nothing {
    let state_dir = ($ygg_home | path join ".state")
    let journal_file = ($state_dir | path join "journal.json")
    if not ($journal_file | path exists) {
        return
    }
    let loaded = (try {
        let val = (open $journal_file)
        if (($val | describe) starts-with "record") { $val } else { {} }
    } catch { {} })
    let steps = ($loaded.steps? | default {})
    let updated_steps = ($steps | upsert $step_name $status)
    let updated_payload = ($loaded | upsert steps $updated_steps)
    let rand_id = (random chars --length 8)
    let tmp_file = ($state_dir | path join $"journal.json.tmp.($rand_id)")
    $updated_payload | to json --indent 2 | save -f $tmp_file
    restrict-file-access $tmp_file | ignore
    mv -f $tmp_file $journal_file
    restrict-file-access $journal_file | ignore
}

# Fail transaction journal by recording failure status, failed step, and error message (RFC-043)
export def fail-journal-transaction [ygg_home: string, error_msg: string]: nothing -> nothing {
    let state_dir = ($ygg_home | path join ".state")
    let journal_file = ($state_dir | path join "journal.json")
    if not ($journal_file | path exists) {
        return
    }
    let loaded = (try {
        let val = (open $journal_file)
        if (($val | describe) starts-with "record") { $val } else { {} }
    } catch { {} })

    let steps = ($loaded.steps? | default {})
    let known_steps = ["prune_packages", "packages", "links", "setup", "env", "services", "finalize"]
    let cols = ($steps | columns)
    let step_keys = ($known_steps | where { |k| $k in $cols } | append ($cols | where { |k| $k not-in $known_steps }))

    mut failed_step = ""
    for k in $step_keys {
        let st = ($steps | get -o $k | default "PENDING")
        if $st in ["IN_PROGRESS", "FAILED"] {
            $failed_step = $k
            break
        }
    }
    if $failed_step == "" {
        for k in $step_keys {
            let st = ($steps | get -o $k | default "PENDING")
            if $st != "COMMITTED" {
                $failed_step = $k
                break
            }
        }
    }

    mut updated_steps = $steps
    if ($failed_step != "") {
        $updated_steps = ($updated_steps | upsert $failed_step "FAILED")
    }

    let updated_payload = ($loaded
        | upsert status "failed"
        | upsert failed_step $failed_step
        | upsert error $error_msg
        | upsert steps $updated_steps
    )

    let rand_id = (random chars --length 8)
    let tmp_file = ($state_dir | path join $"journal.json.tmp.($rand_id)")
    $updated_payload | to json --indent 2 | save -f $tmp_file
    restrict-file-access $tmp_file | ignore
    mv -f $tmp_file $journal_file
    restrict-file-access $journal_file | ignore
}

# Commit transaction journal by removing $YGG_HOME/.state/journal.json (RFC-043)
export def commit-journal-transaction [ygg_home: string]: nothing -> nothing {
    let journal_file = ($ygg_home | path join ".state" "journal.json")
    if ($journal_file | path exists) {
        try { rm -f $journal_file } catch { }
    }
}

# Check for transaction journal state in $YGG_HOME/.state/journal.json (RFC-043)
# State enum: "none" (file absent), "active" (in_progress with live PID),
# "interrupted" (in_progress with dead PID, v1 format, unreadable), "failed" (failed status)
export def check-pending-journal [ygg_home: string]: nothing -> record<state: string, started: string, failed_step: string, error: string, plan_hash: string> {
    let journal_file = ($ygg_home | path join ".state" "journal.json")
    if not ($journal_file | path exists) {
        return {
            state: "none",
            started: "",
            failed_step: "",
            error: "",
            plan_hash: "",
            steps: {}
        }
    }

    let data = (try {
        let val = (open $journal_file)
        if (($val | describe) starts-with "record") { $val } else { null }
    } catch { null })

    if ($data == null) {
        return {
            state: "interrupted",
            started: "",
            failed_step: "",
            error: "unreadable journal",
            plan_hash: "",
            steps: {}
        }
    }

    let started = ($data.started? | default ($data.timestamp? | default ""))
    let plan_hash = ($data.plan_hash? | default "")
    let steps = ($data.steps? | default {})
    let error_text = ($data.error? | default "")

    # v1 journal (missing version or not 2) is treated as interrupted
    if (($data.version? | default 0) != 2) {
        mut failed_step = ($data.failed_step? | default "")
        if $failed_step == "" {
            let cols = ($steps | columns)
            let known = ["prune_packages", "packages", "links", "setup", "env", "services", "finalize"]
            let order = ($known | where { |k| $k in $cols } | append ($cols | where { |k| $k not-in $known }))
            for k in $order {
                let st = ($steps | get -o $k | default "PENDING")
                if $st in ["IN_PROGRESS", "FAILED"] {
                    $failed_step = $k
                    break
                }
            }
            if $failed_step == "" {
                for k in $order {
                    let st = ($steps | get -o $k | default "PENDING")
                    if $st != "COMMITTED" {
                        $failed_step = $k
                        break
                    }
                }
            }
        }
        return {
            state: "interrupted",
            started: $started,
            failed_step: $failed_step,
            error: $error_text,
            plan_hash: $plan_hash,
            steps: $steps
        }
    }

    # Version 2
    let status = ($data.status? | default "")
    mut failed_step = ($data.failed_step? | default "")
    if $failed_step == "" {
        let cols = ($steps | columns)
        let known = ["prune_packages", "packages", "links", "setup", "env", "services", "finalize"]
        let order = ($known | where { |k| $k in $cols } | append ($cols | where { |k| $k not-in $known }))
        for k in $order {
            let st = ($steps | get -o $k | default "PENDING")
            if $st in ["IN_PROGRESS", "FAILED"] {
                $failed_step = $k
                break
            }
        }
        if $failed_step == "" {
            for k in $order {
                let st = ($steps | get -o $k | default "PENDING")
                if $st != "COMMITTED" {
                    $failed_step = $k
                    break
                }
            }
        }
    }

    let state = if $status == "failed" {
        "failed"
    } else if $status == "in_progress" {
        let pid = (coerce-pid ($data.pid? | default 0))
        let is_alive = (check-process-alive $pid)
        if $is_alive {
            "active"
        } else {
            "interrupted"
        }
    } else {
        "interrupted"
    }

    {
        state: $state,
        started: $started,
        failed_step: $failed_step,
        error: $error_text,
        plan_hash: $plan_hash,
        steps: $steps
    }
}

# Rotate old backups according to retention policy (RFC-028)
export def rotate-backups [
    ygg_home: string,
    --max-count: int = 20,
    --max-age-days: int = 30,
    --dry-run
]: nothing -> list<string> {
    let bkp_root = ($ygg_home | path join ".state" "backups")
    if not ($bkp_root | path exists) {
        return []
    }

    let entries = (try {
        ls $bkp_root | where type == "dir" | sort-by name --reverse
    } catch { [] })

    if ($entries | is-empty) {
        return []
    }

    let now = (date now)
    let has_age_limit = ($max_age_days > 0)
    let cutoff = if $has_age_limit {
        $now - ($max_age_days * 1day)
    } else {
        $now
    }

    let total = ($entries | length)
    mut to_remove = []

    for idx in 0..($total - 1) {
        let entry = ($entries | get $idx)
        let is_excess = if ($max_count > 0) { $idx >= $max_count } else { false }
        let is_expired = if $has_age_limit {
            let bname = ($entry.name | path basename)
            let parsed_date = (try {
                let m = ($bname | parse -r '^(?<y>\d{4})(?<m>\d{2})(?<d>\d{2})_(?<H>\d{2})(?<M>\d{2})(?<S>\d{2})')
                if ($m | is-not-empty) {
                    let r = ($m | first)
                    $"($r.y)-($r.m)-($r.d)T($r.H):($r.M):($r.S)Z" | into datetime
                } else {
                    $entry.modified
                }
            } catch {
                $entry.modified
            })
            $parsed_date < $cutoff
        } else {
            false
        }

        if $is_excess or $is_expired {
            $to_remove = ($to_remove | append $entry.name)
        }
    }

    let removed = ($to_remove | uniq)
    if not $dry_run {
        for p in $removed {
            try { rm -rf $p } catch { }
        }
    }

    $removed
}

# Garbage collect orphaned hashes from state.hashes by key namespace (RFC-028, RFC-053)
# pkg:/on_change:/svc: keys are removed unless active; setup:<module>:* only when the module
# is no longer in host.toml; keys with an unknown prefix are never removed.
export def gc-state-hashes [
    ygg_home: string,
    active_keys: list<string>,
    active_modules: list<string>,
    --dry-run
]: nothing -> int {
    let st = (load-state $ygg_home)
    let hashes = ($st.hashes? | default {})
    if not (($hashes | describe) starts-with "record") {
        return 0
    }

    let orphans = ($hashes | columns | where { |k|
        if (($k | str starts-with "pkg:") or ($k | str starts-with "on_change:") or ($k | str starts-with "svc:")) {
            $k not-in $active_keys
        } else if ($k | str starts-with "setup:") {
            let rest = ($k | str substring 6..)
            let mod = (($rest | split row ":" | first) | default "")
            $mod not-in $active_modules
        } else {
            false
        }
    })
    let count = ($orphans | length)

    if ($count == 0) {
        return 0
    }

    if not $dry_run {
        let cleaned = ($hashes | reject ...$orphans)
        save-state $ygg_home ($st | upsert hashes $cleaned)
    }

    $count
}

# Collect all active hash keys from the effective plan (RFC-028, RFC-053)
export def collect-active-hash-keys [plan: record]: nothing -> list<string> {
    mut active = []

    # 1. Package manager hashes: pkg:<mgr>
    for mgr in ($plan.packages? | default {} | columns) {
        $active = ($active | append $"pkg:($mgr)")
    }

    # 2. Links on_change hooks: on_change:<module>:<key>
    for l in ($plan.links? | default []) {
        if (($l.on_change? | default "") != "") {
            $active = ($active | append $"on_change:($l.module):($l.key)")
        }
    }

    # 3. Services: svc:<manager>:<service>
    let services = ($plan.services? | default {})
    if (($services | describe) starts-with "record") {
        let action_keys = ["enable", "reload_on_change", "restart_on_change"]
        mut groups = []
        for top_key in ($services | columns) {
            let top_val = ($services | get $top_key)
            if not (($top_val | describe) starts-with "record") { continue }
            let sub_cols = ($top_val | columns)
            if ($sub_cols | any { |c| $c in $action_keys }) {
                let mgr = if $top_key == "systemd" { "systemd-user" } else { $top_key }
                $groups = ($groups | append { manager: $mgr, data: $top_val })
            } else {
                for sub_key in $sub_cols {
                    let sub_val = ($top_val | get $sub_key)
                    if (($sub_val | describe) starts-with "record") {
                        $groups = ($groups | append { manager: $"($top_key)-($sub_key)", data: $sub_val })
                    }
                }
            }
        }
        for g in $groups {
            let en = ($g.data.enable? | default [])
            let en_list = if (($en | describe) starts-with "list") { $en } else { [$en] }
            for svc in $en_list {
                $active = ($active | append $"svc:($g.manager):($svc)")
            }
            for act in ["reload_on_change", "restart_on_change"] {
                let m = ($g.data | get -o $act | default {})
                if (($m | describe) starts-with "record") {
                    for svc in ($m | columns) {
                        $active = ($active | append $"svc:($g.manager):($svc)")
                    }
                }
            }
        }
    }

    $active | uniq
}
