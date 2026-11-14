# src/sdk.nu
# Yggdrasil configuration manager — Reactive SDK & setup.nu runner

use state.nu [get-ygg-home, load-state, save-state, expand-target-path]
use pkg.nu [run-with-timeout, sudo-available]
use link.nu [parse-services-tree, is-link-or-junction, remove-link-only, link-target-matches, swap-symlink-atomic, create-windows-dir-link, backup-with-notice]
use env.nu [resolve-secret-value]

const YGG_SRC_DIR = (path self | path dirname)

# Check if a path string is absolute or home-relative
def is-path-absolute [p: string]: nothing -> bool {
    ($p | str starts-with "/") or ($p | str starts-with "\\") or ($p | str starts-with "~") or ($p =~ '^[A-Za-z]:')
}

# Aggregate SHA-256 of all files matched by watch_globs (directories recursively).
# Relative globs are resolved against base_dir; entries are "<path relative to base_dir>:<sha256>".
export def hash-watch-set [watch_globs: list<string>, base_dir: string]: nothing -> string {
    mut files: list<string> = []
    for pattern in $watch_globs {
        let resolved_pattern = if (is-path-absolute $pattern) {
            $pattern
        } else {
            ($base_dir | path join $pattern)
        }

        # RFC-001: never call `path exists` / `path type` on a glob pattern (Win32 File API)
        let has_wildcard = ($resolved_pattern | str contains "*") or ($resolved_pattern | str contains "?")
        let is_exact = if not $has_wildcard {
            try { ($resolved_pattern | path exists) or (($resolved_pattern | path type) != null) } catch { false }
        } else {
            false
        }

        if $is_exact {
            let ptype = ($resolved_pattern | path type)
            if ($ptype == "dir") {
                let dir_files = (try { glob (($resolved_pattern | path join "**" "*") | str replace --all '\' '/') } catch { [] })
                for df in $dir_files {
                    if (($df | path type) == "file") {
                        $files = ($files | append ($df | path expand))
                    }
                }
            } else if ($ptype == "file") {
                $files = ($files | append ($resolved_pattern | path expand))
            }
        } else {
            let matched = (try { glob ($resolved_pattern | str replace --all '\' '/') } catch { [] })
            for m in $matched {
                let ptype = ($m | path type)
                if ($ptype == "dir") {
                    let dir_files = (try { glob (($m | path join "**" "*") | str replace --all '\' '/') } catch { [] })
                    for df in $dir_files {
                        if (($df | path type) == "file") {
                            $files = ($files | append ($df | path expand))
                        }
                    }
                } else if ($ptype == "file") {
                    $files = ($files | append ($m | path expand))
                }
            }
        }
    }
    let unique_files = ($files | uniq | sort)

    mut hash_entries = []
    for f in $unique_files {
        let rel = (try { $f | path relative-to $base_dir } catch { $f })
        let content_hash = (try { open --raw $f | hash sha256 } catch { "" })
        $hash_entries = ($hash_entries | append $"($rel):($content_hash)")
    }
    $hash_entries | str join "\n" | hash sha256
}

# Calculate hash of watch_globs and conditionally execute block.
# Returns true if executed, false if skipped.
export def onchange [
    key: string,
    watch_globs: list<string>,
    block: closure,
    --target: string = ""
]: nothing -> bool {
    let ygg_home = (get-ygg-home)
    let mod_dir = ($env.YGG_MODULE_DIR? | default ".")

    # 1-2. Aggregate hash of the watched files
    let current_hash = (hash-watch-set $watch_globs $mod_dir)

    # 3. Check current state and target
    let state = (load-state $ygg_home)
    let mod_name = ($env.YGG_MODULE_NAME? | default ($mod_dir | path expand | path basename))
    let state_key = $"setup:($mod_name):($key)"
    let hashes_now = ($state.hashes? | default {})
    let new_hash = ($hashes_now | get -o $state_key)
    let legacy_hash = ($hashes_now | get -o $key)
    let prev_hash = ($new_hash | default ($legacy_hash | default ""))
    # Migrate legacy bare key to the namespaced key, preserving the cache (RFC-053)
    if ($new_hash == null) and ($legacy_hash != null) and ((($env.YGG_DRY_RUN? | default "false") != "true")) {
        let migrated = ($hashes_now | reject -o $key | upsert $state_key $legacy_hash)
        save-state $ygg_home ($state | upsert hashes $migrated)
    }

    let is_force = (($env.YGG_FORCE? | default "false") == "true")
    let target_exists = if ($target != "") {
        let expanded_target = (expand-target-path $target)
        ($expanded_target | path exists)
    } else {
        true
    }

    if (not $is_force) and $target_exists and ($prev_hash != "") and ($prev_hash == $current_hash) {
        return false
    }

    let is_dry = (($env.YGG_DRY_RUN? | default "false") == "true")
    if $is_dry {
        print $"[ygg] dry-run: onchange '($key)' would run"
        return false
    }

    # 4. Execute block
    do $block

    # 5. On success: update hash in state.json
    let st = (load-state $ygg_home)
    let updated_hashes = ($st.hashes? | default {} | reject -o $key | upsert $state_key $current_hash)
    let updated_st = ($st | upsert hashes $updated_hashes)
    save-state $ygg_home $updated_st

    true
}

# Merge a JSON fragment into destination JSON file, preserving existing host keys and removing old symlinks.
export def merge-json [
    src_fragment: string,
    dest_json: string,
    --mode: string = "0600"
]: nothing -> nothing {
    # 1. Resolve source fragment
    let src_path = if (is-path-absolute $src_fragment) {
        $src_fragment
    } else {
        let mod_dir = ($env.YGG_MODULE_DIR? | default ".")
        ($mod_dir | path join $src_fragment)
    }

    let fragment = if ($src_path | path exists) {
        open $src_path
    } else {
        try {
            $src_fragment | from json
        } catch {
            error make { msg: $"Fragment file '($src_path)' does not exist and argument is not valid JSON" }
        }
    }

    if not (($fragment | describe) starts-with "record") {
        error make { msg: $"Source fragment '($src_fragment)' is not a JSON object/record" }
    }

    # 2. Resolve destination path with sandbox / token expansion
    let dest = (expand-target-path $dest_json)
    let dest_dir = ($dest | path dirname)

    # 3. Read existing JSON before making any changes
    mut existing_record = {}
    let is_link = (is-link-or-junction $dest)

    if ($dest | path exists) {
        let raw = (open --raw $dest)
        let trimmed = ($raw | str trim)
        if ($trimmed != "") {
            let parsed = (try {
                $raw | from json
            } catch {
                error make { msg: $"Destination file '($dest)' contains invalid JSON" }
            })
            if not (($parsed | describe) starts-with "record") {
                error make { msg: $"Destination file '($dest)' JSON is not an object/record" }
            }
            $existing_record = $parsed
        }
    } else if $is_link {
        # Dangling symlink produces empty record {}
        $existing_record = {}
    } else {
        # Missing destination produces empty record {}
        $existing_record = {}
    }

    let is_dry = (($env.YGG_DRY_RUN? | default "false") == "true")
    if $is_dry {
        print $"[ygg] dry-run: merge-json would write '($dest)'"
        return
    }

    if not ($dest_dir | path exists) {
        mkdir $dest_dir
    }

    # 4. Merge deep: existing host data + declarative module fragment
    let merged = ($existing_record | merge deep $fragment)

    # 5. Atomic write: write to tmp file in same directory, chmod, then mv -f
    let tmp_file = $"($dest).tmp.(random chars --length 8)"
    try {
        $merged | to json --indent 2 | save -f $tmp_file
        if ($nu.os-info.family != "windows") {
            try { ^chmod $mode $tmp_file | complete | ignore } catch { }
        }
        if $is_link {
            remove-link-only $dest
        }
        mv -f $tmp_file $dest
        if ($nu.os-info.family != "windows") {
            try { ^chmod $mode $dest | complete | ignore } catch { }
        }
    } catch { |err|
        if ($tmp_file | path exists) {
            rm -f $tmp_file
        }
        error make { msg: $err.msg }
    }
}

# Export secrets from $YGG_HOME/secrets.toml to a destination .env file with 0600 permissions.
# NOTE: Uses single quotes (KEY='value') with '\' -> '\\' and '\'' -> '\''.
# Limitation: python-dotenv interpolates ${VAR} even within single quotes; avoid ${...} in secrets or escape if needed.
export def export-secrets [
    dest_dotenv: string,
    --keys: list<string> = []
]: nothing -> nothing {
    let ygg_home = (get-ygg-home)
    let sec_file = ($ygg_home | path join "secrets.toml")

    if not ($sec_file | path exists) {
        if ($keys | is-not-empty) {
            print -e $"[ygg] Warning: export-secrets: secrets.toml not found, missing requested keys: ($keys | str join ', ')"
        }
        return
    }

    let sec_data = (try { open $sec_file } catch { {} })
    let sec_env = if "env" in $sec_data {
        $sec_data.env
    } else {
        $sec_data
    }

    if (not (($sec_env | describe) starts-with "record")) or ($sec_env | is-empty) {
        if ($keys | is-not-empty) {
            print -e $"[ygg] Warning: export-secrets: no secrets available, missing requested keys: ($keys | str join ', ')"
        }
        return
    }

    let available_keys = ($sec_env | columns)
    let target_keys = if ($keys | is-empty) {
        $available_keys
    } else {
        let missing_keys = ($keys | where { |k| (($sec_env | get -o $k | default "") | into string) == "" })
        if ($missing_keys | is-not-empty) {
            print -e $"[ygg] Warning: export-secrets: missing or empty requested keys: ($missing_keys | str join ', ')"
        }
        $keys | where { |k| not ($k in $missing_keys) }
    }

    mut lines: list<string> = []
    for k in $target_keys {
        let raw_val = ($sec_env | get $k | into string)
        let resolved_val = (resolve-secret-value $raw_val)
        let escaped_val = ($resolved_val
            | str replace --all '\' '\\'
            | str replace --all "'" "\\'")
        $lines = ($lines | append $"($k)='($escaped_val)'")
    }

    let dest = (expand-target-path $dest_dotenv)
    let dest_dir = ($dest | path dirname)

    let is_dry = (($env.YGG_DRY_RUN? | default "false") == "true")
    if $is_dry {
        print $"[ygg] dry-run: export-secrets would write '($dest)'"
        return
    }

    if not ($dest_dir | path exists) {
        mkdir $dest_dir
    }

    let content = if ($lines | is-empty) { "" } else { ($lines | str join "\n") + "\n" }
    $content | save -f $dest

    if ($nu.os-info.family != "windows") {
        try { ^chmod 0600 $dest | complete | ignore } catch { }
    }
}

# Run a module's setup.nu procedural script in an isolated subshell with standard YGG environment variables.
export def run-module-setup [
    ygg_home: string,
    mod_plan: record,
    --dry-run,
    --force,
    --sandbox: string = ""
]: nothing -> nothing {
    let mod_dir = ($mod_plan.dir? | default ($ygg_home | path join "modules" ($mod_plan.name? | default "")))
    let setup_script = ($mod_dir | path join "setup.nu")

    if not ($setup_script | path exists) {
        return
    }

    let is_dry = if $dry_run { "true" } else { ($env.YGG_DRY_RUN? | default "false") }
    let is_safe = ($mod_plan.manifest?.setup?.dry_run_safe?
        | default ($mod_plan.setup?.dry_run_safe?
        | default ($mod_plan.dry_run_safe?
        | default (try {
            let ygg_toml = ($mod_dir | path join "ygg.toml")
            if ($ygg_toml | path exists) {
                (open $ygg_toml).setup?.dry_run_safe? | default false
            } else {
                false
            }
        } catch { false }))))

    if ($is_dry == "true") and (not $is_safe) {
        let mod_name = ($mod_plan.name? | default ($mod_dir | path basename))
        print $"[ygg] \(dry-run\) SETUP ($mod_name) \(skipped\)"
        return
    }

    let ygg_src_dir = ($YGG_SRC_DIR | path expand)
    let is_forced = if $force { "true" } else { ($env.YGG_FORCE? | default "false") }
    let sb = if ($sandbox != "") { $sandbox } else { ($env.YGG_SANDBOX? | default "") }

    let scopes_json = (($mod_plan.scopes? | default []) | to json -r)
    let config_json = (($mod_plan.config? | default {}) | to json -r)

    let env_vars = {
        YGG_HOME: $ygg_home,
        YGG_MODULE_DIR: $mod_dir,
        YGG_MODULE_NAME: ($mod_plan.name? | default ($mod_dir | path basename)),
        YGG_SCOPES: $scopes_json,
        YGG_MOD_CONFIG: $config_json,
        YGG_DRY_RUN: $is_dry,
        YGG_FORCE: $is_forced,
        YGG_SANDBOX: $sb
    }

    with-env $env_vars {
        let res = (^nu -I $ygg_src_dir $setup_script | complete)
        if ($res.stdout | str trim) != "" {
            print -n $res.stdout
        }
        if $res.exit_code != 0 {
            if ($res.stderr | str trim) != "" {
                print -e $res.stderr
            }
            error make {
                msg: $"setup.nu for module '($mod_plan.name? | default ($mod_dir | path basename))' failed with exit code ($res.exit_code): ($res.stderr)"
            }
        }
    }
}

# Idempotent link for setup.nu scripts (RFC-023), same state table as apply (RFC-009):
# matching link -> no-op; other/dangling link -> atomic swap; real file/dir -> backup-with-notice, then link.
# A relative `src` is written literally and checked against dest's parent directory.
# Not recorded in state.links and never PRUNEd: setup.nu owns these links.
export def safe-link [src: string, dest: string]: nothing -> nothing {
    let ygg_home = (get-ygg-home)
    let is_dry = (($env.YGG_DRY_RUN? | default "false") == "true")
    let is_windows = ($nu.os-info.family == "windows")
    let target_dest = (expand-target-path $dest)
    let dest_parent = ($target_dest | path dirname)
    let is_abs = (is-path-absolute $src) or ($src | str starts-with "$")
    let check_src = if $is_abs {
        expand-target-path $src
    } else {
        $dest_parent | path join $src
    }
    # Literal link value: relative stays as is; ~ / tokens / absolute are written expanded
    let link_src = if $is_abs { $check_src } else { $src }

    if not ($check_src | path exists) {
        error make { msg: $"safe-link: source '($src)' \(resolved to '($check_src)'\) does not exist" }
    }
    if $is_windows and (($check_src | path type) != "dir") {
        error make { msg: $"safe-link: '($src)' is a file; on Windows only directories can be linked, use [save] for files" }
    }
    if (link-target-matches $target_dest $check_src) and ($target_dest | path exists) {
        return
    }
    if $is_dry {
        print $"[ygg] dry-run: safe-link '($target_dest)' -> '($link_src)'"
        return
    }

    mkdir $dest_parent
    if (is-link-or-junction $target_dest) {
        if $is_windows {
            remove-link-only $target_dest
            make-safe-dir-link $check_src $target_dest
        } else {
            swap-symlink-atomic $link_src $target_dest
        }
    } else {
        if (($target_dest | path type) != null) {
            backup-with-notice $ygg_home $target_dest | ignore
        }
        if $is_windows {
            make-safe-dir-link $check_src $target_dest
        } else {
            let res = (^ln -s $link_src $target_dest | complete)
            if $res.exit_code != 0 {
                error make { msg: $"safe-link: failed to link '($target_dest)' -> '($link_src)': ($res.stderr)" }
            }
        }
    }
}

# Windows: a junction needs an absolute target (to-win32-path inside create-windows-dir-link)
def make-safe-dir-link [src: string, dest: string]: nothing -> nothing {
    let res = (create-windows-dir-link ($src | path expand -n) $dest)
    if not $res.ok {
        error make { msg: $"safe-link: failed to link '($dest)' -> '($src)': ($res.stderr)" }
    }
}

# RFC-015: run `on_change` hooks of resolved link targets as the last step of `apply`.
# A hook fires when the hash of its sources changed, when its key got a LINK / RELINK /
# BACKUP_REPLACE op, or with --force. An identical command runs once per call; the hashes of all
# its keys (state.hashes."on_change:<module>:<key>") are recorded only on success.
# --dry-run: nothing runs or is recorded (status "dry_run"). YGG_MOCK_PKG_LOG: "hook: <cmd>" is
# logged instead of running (YGG_MOCK_HOOK_FAIL: comma-separated commands that fail in the mock).
# Sandbox without the mock log: nothing runs (status "skipped_sandbox").
export def run-link-hooks [
    ygg_home: string,
    targets: table,
    ops: table,
    --dry-run,
    --force,
    --sandbox: string = ""
]: nothing -> list<record<module: string, keys: list<string>, cmd: string, status: string, stderr: string>> {
    let hook_rows = ($targets | default [] | where { |t| ($t.on_change? | default "") != "" })
    if ($hook_rows | is-empty) {
        return []
    }
    let sb = if ($sandbox != "") { $sandbox } else { ($env.YGG_SANDBOX? | default "") }
    let mock_log = ($env.YGG_MOCK_PKG_LOG? | default "")
    let mock_fail = ($env.YGG_MOCK_HOOK_FAIL? | default "" | split row "," | each { |c| $c | str trim } | where { |c| $c != "" })
    let hashes = ((load-state $ygg_home).hashes? | default {})
    let changed_ops = ["LINK", "RELINK", "BACKUP_REPLACE"]

    # 1-3. One group per (module, key, command); keep the groups that have to fire
    mut fired = []
    for g in ($hook_rows | group-by --to-table module key on_change) {
        let rows = $g.items
        let first_row = ($rows | first)
        let module = $first_row.module
        let key = $first_row.key
        let cmd = $first_row.on_change
        let base_dir = ($ygg_home | path join "modules" $module | path expand)
        let current = (hash-watch-set ($rows | get src | uniq) $base_dir)
        let hkey = ("on_change:" + $module + ":" + $key)
        let prev = ($hashes | get -o $hkey | default "")
        let op_hit = ($ops | default [] | any { |o| ($o.module == $module) and ($o.key == $key) and ($o.op in $changed_ops) })
        if $force or ($current != $prev) or $op_hit {
            $fired = ($fired | append { module: $module, key: $key, cmd: $cmd, hkey: $hkey, hash: $current })
        }
    }

    # 4-5. Deduplicate by command, run once, record the hashes of all keys on success
    mut results = []
    mut new_hashes = {}
    for c in ($fired | group-by --to-table cmd) {
        let items = $c.items
        let cmd = $c.cmd
        let modules = ($items | get module | uniq | str join ",")
        let keys = ($items | get key)
        let outcome = if $dry_run {
            { status: "dry_run", stderr: "" }
        } else if ($mock_log != "") {
            $"hook: ($cmd)\n" | save --append $mock_log
            if ($cmd in $mock_fail) {
                { status: "failed", stderr: "mock hook failure" }
            } else {
                { status: "ok", stderr: "" }
            }
        } else if ($sb != "") {
            { status: "skipped_sandbox", stderr: "" }
        } else {
            let res = (run-with-timeout ["nu", "-c", $cmd] 30)
            if $res.exit_code == 0 {
                { status: "ok", stderr: "" }
            } else {
                let err = ($res.stderr | str trim)
                { status: "failed", stderr: (if ($err != "") { $err } else { $"exit code ($res.exit_code)" }) }
            }
        }
        if ($outcome.status == "failed") {
            for k in $keys {
                print -e $"[ygg] Warning: on_change for '($k)' failed: ($outcome.stderr)"
            }
        }
        if ($outcome.status == "ok") {
            for it in $items {
                $new_hashes = ($new_hashes | upsert $it.hkey $it.hash)
            }
        }
        $results = ($results | append { module: $modules, keys: $keys, cmd: $cmd, status: $outcome.status, stderr: $outcome.stderr })
    }

    if ($new_hashes | columns | is-not-empty) {
        let st = (load-state $ygg_home)
        save-state $ygg_home ($st | upsert hashes (($st.hashes? | default {}) | merge $new_hashes))
    }
    $results
}

def to-str-list [value: any]: nothing -> list<string> {
    if $value == null {
        []
    } else if (($value | describe) starts-with "list") {
        $value
    } else {
        [$value]
    }
}

# RFC-055 p.1/p.2 + RFC-057 p.4: managers are whitelisted (SERVICE_MANAGERS); the service name is
# validated in preflight-check, on Windows it is passed as an argument (never interpolated).
def build-service-cmd [manager: string, action: string, service: string]: nothing -> list<string> {
    if $manager == "systemd-user" {
        ["systemctl", "--user", $action, $service]
    } else if $manager == "systemd-system" {
        ["sudo", "systemctl", $action, $service]
    } else if $manager == "windows" {
        if $action == "enable" {
            ["powershell", "-NoProfile", "-Command", "Set-Service -Name $args[0] -StartupType Automatic", $service]
        } else {
            ["powershell", "-NoProfile", "-Command", "Restart-Service -Name $args[0]", $service]
        }
    } else if $manager == "launchd" {
        # RFC-055 p.7: the manifest names only the label; the plist path and the gui/<uid> domain
        # target are derived here (argv runs without a shell, so `~` would never expand).
        # `load -w` is kept over `bootstrap`: it is idempotent for an already loaded agent.
        if $action == "enable" {
            ["launchctl", "load", "-w", ($nu.home-dir | path join "Library" "LaunchAgents" $"($service).plist")]
        } else {
            ["launchctl", "kickstart", "-k", $"gui/(^id -u | str trim)/($service)"]
        }
    } else {
        error make { msg: $"unsupported service manager '($manager)'" }
    }
}

# RFC-055 p.4: a trigger matches when it equals the link key, its raw destination or the expanded destination.
# No basename / suffix matching.
def service-trigger-matches [changed_ops: any, triggers: any, raw_by_link: record = {}]: nothing -> bool {
    let trig_list = (to-str-list $triggers | each { |t| $t | into string })
    let ops_list = ($changed_ops | default [])
    if ($trig_list | is-empty) or ($ops_list | is-empty) {
        return false
    }

    $ops_list | any { |op|
        let key = ($op.key? | default "")
        let dest = ($op.dest? | default "")
        let raws = ([($op.dest_raw? | default "")] | append ($raw_by_link | get -o $"($op.module? | default "")\u{1f}($key)" | default []) | where { |r| $r != "" })
        $trig_list | any { |trig|
            ($key == $trig) or ($dest == $trig) or ($trig in $raws)
        }
    }
}

# RFC-037: Declarative management of system daemons and services
export def run-service-actions [
    ygg_home: string,
    plan: record,
    ops: any,
    --dry-run,
    --force,
    --sandbox: string = ""
]: nothing -> list<record> {
    let services = ($plan.services? | default {})
    if not (($services | describe) starts-with "record") or ($services | columns | is-empty) {
        return []
    }

    let changed_ops = (
        $ops
        | default []
        | where { |o| ($o.op? | default "") in ["LINK", "RELINK", "BACKUP_REPLACE", "COPY_CREATE", "COPY_UPDATE"] }
    )

    let configs = (parse-services-tree $services)
    if ($configs | is-empty) {
        return []
    }

    let mock_log = ($env.YGG_MOCK_PKG_LOG? | default "")
    let mock_fail = ($env.YGG_MOCK_SERVICE_FAIL? | default "" | split row "," | each { |c| $c | str trim } | where { |c| $c != "" })
    let sb = if ($sandbox != "") { $sandbox } else { ($env.YGG_SANDBOX? | default "") }

    let hashes = ((load-state $ygg_home).hashes? | default {})
    mut raw_by_link = {}
    for l in ($plan.links? | default []) {
        let k = $"($l.module? | default "")\u{1f}($l.key? | default "")"
        $raw_by_link = ($raw_by_link | upsert $k (($raw_by_link | get -o $k | default []) | append ($l.dest_raw? | default "")))
    }

    mut scheduled = []

    for cfg in $configs {
        let data = $cfg.data
        let mgr = $cfg.manager

        # 1. enable
        let enable_list = (to-str-list ($data.enable? | default []))
        for svc in $enable_list {
            # RFC-055 p.3: enable runs once (svc:<mgr>:<svc> in state.hashes); --force resets the cache
            if (not $force) and (($hashes | get -o $"svc:($mgr):($svc)") != null) { continue }
            $scheduled = ($scheduled | append { service: $svc, action: "enable", manager: $mgr })
        }

        # 2. reload_on_change
        let reload_map = ($data.reload_on_change? | default {})
        if (($reload_map | describe) starts-with "record") {
            for svc in ($reload_map | columns) {
                let triggers = ($reload_map | get $svc)
                if (service-trigger-matches $changed_ops $triggers $raw_by_link) {
                    $scheduled = ($scheduled | append { service: $svc, action: "reload", manager: $mgr })
                }
            }
        }

        # 3. restart_on_change
        let restart_map = ($data.restart_on_change? | default {})
        if (($restart_map | describe) starts-with "record") {
            for svc in ($restart_map | columns) {
                let triggers = ($restart_map | get $svc)
                if (service-trigger-matches $changed_ops $triggers $raw_by_link) {
                    $scheduled = ($scheduled | append { service: $svc, action: "restart", manager: $mgr })
                }
            }
        }
    }

    if ($scheduled | is-empty) {
        return []
    }

    # Deduplicate scheduled actions by (service, action, manager)
    let deduped = ($scheduled | uniq-by service action manager)

    mut results = []
    for item in $deduped {
        let svc = $item.service
        let action = $item.action
        let mgr = $item.manager
        let cmd_argv = (build-service-cmd $mgr $action $svc)
        let cmd_str = ($cmd_argv | str join " ")

        let outcome = if $dry_run {
            print $"[ygg] \(dry-run\) SERVICE ($svc) \(($action) ($mgr)\)"
            { status: "dry_run", stderr: "" }
        } else if ($mock_log == "") and ($sb != "") {
            { status: "skipped_sandbox", stderr: "" }
        } else if ($mgr == "systemd-system") and not (sudo-available) {
            { status: "failed", stderr: "sudo is not available without a password (non-interactive)" }
        } else if ($mock_log != "") {
            $"service: ($cmd_str)\n" | save --append $mock_log
            if ($svc in $mock_fail) or ($cmd_str in $mock_fail) {
                { status: "failed", stderr: "mock service failure" }
            } else {
                { status: "ok", stderr: "" }
            }
        } else {
            try {
                let res = (run-with-timeout $cmd_argv 30)
                if $res.exit_code == 0 {
                    { status: "ok", stderr: "" }
                } else {
                    let err = ($res.stderr | str trim)
                    { status: "failed", stderr: (if ($err != "") { $err } else { $"exit code ($res.exit_code)" }) }
                }
            } catch { |e|
                { status: "failed", stderr: $e.msg }
            }
        }

        if ($outcome.status == "ok") and ($action == "enable") {
            let st = (load-state $ygg_home)
            save-state $ygg_home ($st | upsert hashes (($st.hashes? | default {}) | upsert $"svc:($mgr):($svc)" "enabled"))
        }

        if ($outcome.status == "failed") {
            print -e $"[ygg] Warning: service action failed for '($svc)': ($outcome.stderr)"
        }

        $results = ($results | append {
            service: $svc,
            action: $action,
            manager: $mgr,
            cmd: $cmd_str,
            status: $outcome.status,
            stderr: $outcome.stderr
        })
    }

    $results
}

