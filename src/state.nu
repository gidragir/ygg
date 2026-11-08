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
    let default_state = { links: {}, copies: {}, hashes: {} }

    if not ($state_file | path exists) {
        return $default_state
    }

    try {
        let loaded = (open $state_file)
        {
            links: ($loaded.links? | default {}),
            copies: ($loaded.copies? | default {}),
            hashes: ($loaded.hashes? | default {})
        }
    } catch {
        $default_state
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
        let rel = ($norm | str substring 2..)
        if ($sb != "") {
            return ($sb | path join $rel)
        } else {
            return (("~" | path expand) | path join $rel)
        }
    }

    if ($norm == "$APPDATA") or ($norm | str starts-with "$APPDATA/") or ($norm | str starts-with "$APPDATA\\") {
        let rel = if ($norm == "$APPDATA") { "" } else { ($norm | str substring 9..) }
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
        let rel = if ($norm == "$LOCALAPPDATA") { "" } else { ($norm | str substring 14..) }
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
        let rel = if ($norm == "$DOCUMENTS") { "" } else { ($norm | str substring 11..) }
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

# Check if a process with given PID is still running
export def check-process-alive [pid: int]: nothing -> bool {
    if $pid <= 0 {
        return false
    }
    if $nu.os-info.family == "windows" {
        let res = (try {
            ^tasklist /FI $"PID eq ($pid)" /FO CSV | complete
        } catch {
            { exit_code: 1, stdout: "" }
        })
        if $res.exit_code == 0 {
            ($res.stdout | str contains $"\"($pid)\"") or ($res.stdout | str contains ($pid | into string))
        } else {
            false
        }
    } else {
        let res = (try {
            ^kill -0 $pid | complete
        } catch {
            { exit_code: 1 }
        })
        $res.exit_code == 0
    }
}

# Acquire exclusive advisory host lock in $YGG_HOME/.state/ygg.lock (RFC-026)
export def acquire-host-lock [ygg_home: string, command: string, --no-lock]: nothing -> string {
    if $no_lock or (($env.YGG_NO_LOCK? | default "") == "1") {
        return ""
    }
    let lock_file = ($ygg_home | path join ".state" "ygg.lock")
    ensure-ygg-dirs $ygg_home

    if ($lock_file | path exists) {
        let lock_data = (try { open $lock_file | from json } catch { {} })
        let lock_pid = ($lock_data.pid? | default 0)
        let is_alive = (check-process-alive $lock_pid)
        if $is_alive {
            error make { msg: $"Host is locked by another ygg instance \(PID: ($lock_pid), Command: '($lock_data.command? | default "unknown")', Started: ($lock_data.timestamp? | default "")\). Aborting." }
        } else {
            print -e $"[ygg] Warning: Removing stale lock from terminated process \(PID ($lock_pid)\)."
            try { rm -f $lock_file } catch { }
        }
    }

    let payload = {
        pid: $nu.pid,
        timestamp: (date now | format date "%Y-%m-%dT%H:%M:%SZ"),
        command: $command,
        user: ($env.USER? | default ($env.USERNAME? | default ""))
    }
    $payload | to json | save -f $lock_file
    $lock_file
}

# Release advisory host lock (RFC-026)
export def release-host-lock [lock_file: string]: nothing -> nothing {
    if ($lock_file != "") and ($lock_file | path exists) {
        try { rm -f $lock_file } catch { }
    }
}

