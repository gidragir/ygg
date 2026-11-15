# src/container.nu
# Yggdrasil configuration manager — module containers (RFC-059): compose stack discovery

use pkg.nu [run-with-timeout]

# Whitelist of container runtimes (docker compose / podman compose)
export const CONTAINER_RUNTIMES = ["docker", "podman"]

const COMPOSE_DEFAULT_NAMES = ["compose.yaml" "compose.yml" "docker-compose.yaml" "docker-compose.yml"]

def native-rel-path [rel: string]: nothing -> string {
    $rel | str replace --all "\\" "/" | str replace --all "/" (char path_sep)
}

# Normalize a compose project name: lowercase, [a-z0-9_-] only, collapsed dashes, trimmed edges
export def normalize-project-name [raw: string]: nothing -> string {
    $raw
    | str downcase
    | str replace --all --regex '[^a-z0-9_-]' '-'
    | str replace --all --regex '-{2,}' '-'
    | str replace --all --regex '^[-_]+|[-_]+$' ''
}

# Absolute path of `<stem>.override.<ext>` next to the compose file, or "" if absent
export def find-override-file [file: string]: nothing -> string {
    let p = ($file | path parse)
    let ext = if ($p.extension | is-empty) { "" } else { $".($p.extension)" }
    let cand = ($p.parent | path join $"($p.stem).override($ext)")
    if ($cand | path type) == "file" { $cand } else { "" }
}

# Top-level `name:` of a compose file ("" if missing / unreadable); regex fallback for YAML tags
def read-compose-name [file: string]: nothing -> string {
    let raw = (try { open --raw $file } catch { return "" })
    let parsed = (try {
        let y = ($raw | from yaml)
        let n = (if (($y | describe) starts-with "record") { $y.name? } else { null })
        if ($n != null) and (($n | describe) == "string") { $n } else { "" }
    } catch {
        let m = ($raw | lines | each { |l| $l | parse --regex '^name:\s*(?<n>["\x27]?[A-Za-z0-9][^\s#]*)' } | flatten)
        if ($m | is-empty) { "" } else { ($m | first | get n | str trim --char '"' | str trim --char "'") }
    })
    $parsed
}

# Compose project name: top-level `name:` or `<module>[-<parent dir>]`, normalized
export def compose-project-name [module: string, mod_dir: string, file: string]: nothing -> string {
    let declared = (read-compose-name $file)
    let raw = if ($declared != "") {
        $declared
    } else {
        let rel_parts = (try { (($file | path expand -n | path relative-to ($mod_dir | path expand -n)) | str replace --all "\\" "/" | split row "/") } catch { [] })
        if ($rel_parts | length) <= 1 { $module } else { $"($module)-($rel_parts | drop 1 | last)" }
    }
    normalize-project-name $raw
}

# Discover compose stacks of a module (enabled flag is set by the caller)
export def discover-stacks [module: string, mod_dir: string, cfg: record, scope_files: list<string>]: nothing -> list<record> {
    let base = if ($cfg.files? != null) {
        let f = $cfg.files
        if (($f | describe) starts-with "list") { $f } else { [$f] }
    } else {
        let found = ($COMPOSE_DEFAULT_NAMES | where { |n| (($mod_dir | path join $n) | path type) == "file" })
        if ($found | is-empty) { [] } else { [($found | first)] }
    }
    $base | append $scope_files | each { |r| $r | str replace --all "\\" "/" | str replace --regex '^\./' '' } | uniq | each { |rel|
        let file = ($mod_dir | path join (native-rel-path $rel))
        {
            module: $module,
            rel: $rel,
            file: $file,
            override: (find-override-file $file),
            project: (compose-project-name $module $mod_dir $file),
            enabled: false
        }
    }
}

# Preflight validation of container stacks (RFC-059); only enabled stacks are checked for files/collisions
export def check-container-stacks [plan: record]: nothing -> list<record<module: string, key: string, reason: string, detail: string>> {
    mut problems = []
    let mods = ($plan.modules? | default [])
    let settings = ($plan.container_settings? | default { runtime: "", timeout: 600 })
    let rt = ($settings.runtime? | default "")
    if $rt != "" and ($rt not-in $CONTAINER_RUNTIMES) {
        $problems = ($problems | append {
            module: "containers", key: "runtime", reason: "invalid_container_runtime",
            detail: $"Unsupported container runtime '($rt)' \(allowed: ($CONTAINER_RUNTIMES | str join ', ')\)"
        })
    }
    for m in $mods {
        let raw = ($m.containers_raw? | default null)
        if $raw != null and (($raw | describe) != "bool") {
            $problems = ($problems | append {
                module: $m.name, key: "containers", reason: "invalid_containers_flag",
                detail: $"Module '($m.name)': 'containers' must be true or false, got '($raw)'"
            })
        }
    }
    let enabled = ($plan.containers? | default [] | where enabled == true)
    mut valid = []
    for st in $enabled {
        let mod_dir = ($mods | where name == $st.module | get -o 0.dir | default "")
        let rel = ($st.rel | str replace --all "\\" "/")
        let abs_rel = ($rel | str starts-with "/") or ($rel =~ '^[A-Za-z]:')
        let parts = ($rel | split row "/")
        let outside = $abs_rel or (".." in $parts) or ($mod_dir != "" and (not (($st.file | path expand -n) | str starts-with (($mod_dir | path expand -n) + (char path_sep)))))
        if $outside {
            $problems = ($problems | append {
                module: $st.module, key: $st.rel, reason: "container_path_outside_module",
                detail: $"Compose file '($st.rel)' is outside module '($st.module)'"
            })
        } else if (($st.file | path type) != "file") {
            $problems = ($problems | append {
                module: $st.module, key: $st.rel, reason: "container_file_missing",
                detail: $"Compose file '($st.rel)' of module '($st.module)' not found"
            })
        } else {
            $valid = ($valid | append $st)
        }
    }
    for g in ($valid | group-by project | transpose project stacks) {
        if ($g.stacks | length) > 1 {
            let who = ($g.stacks | each { |s| $"($s.module): ($s.rel)" } | str join ", ")
            $problems = ($problems | append {
                module: ($g.stacks | first | get module), key: $g.project, reason: "container_project_collision",
                detail: $"Compose project name '($g.project)' is used by several stacks \(($who)\)"
            })
        }
    }
    $problems
}

# True when `docker compose version` output reports Compose v2+ (v1 / podman-compose are rejected)
export def compose-version-ok [output: string]: nothing -> bool {
    let m = ($output | lines | each { |l| $l | parse --regex 'Docker Compose version v?(?<major>\d+)\.' } | flatten)
    if ($m | is-empty) { return false }
    ($m | first | get major | into int) >= 2
}

def container-sandbox [sandbox: string]: nothing -> string {
    if ($sandbox != "") { $sandbox } else { ($env.YGG_SANDBOX? | default "") }
}

# Probe a single runtime: ok | no_runtime | unsupported_provider | daemon_down
def probe-runtime [rt: string]: nothing -> record<runtime: string, status: string, detail: string> {
    if (which $rt | is-empty) {
        return { runtime: $rt, status: "no_runtime", detail: $"($rt) not found in PATH" }
    }
    let v = (run-with-timeout [$rt "compose" "version"] 30)
    if $v.exit_code != 0 or not (compose-version-ok ($v.stdout + "\n" + $v.stderr)) {
        return { runtime: $rt, status: "unsupported_provider", detail: "install the docker-compose v2 plugin" }
    }
    let d = (run-with-timeout [$rt "compose" "ls" "--format" "json"] 30)
    if $d.exit_code != 0 {
        return { runtime: $rt, status: "daemon_down", detail: ($d.stderr | str trim) }
    }
    { runtime: $rt, status: "ok", detail: "" }
}

# Detect the container runtime (docker -> podman unless forced by --runtime / settings.runtime)
export def detect-container-runtime [
    settings: record,
    --runtime: string = "",
    --sandbox: string = ""
]: nothing -> record<runtime: string, status: string, detail: string> {
    let forced = if ($runtime != "") { $runtime } else { ($settings.runtime? | default "") }
    let mock_log = ($env.YGG_MOCK_PKG_LOG? | default "")
    let sb = (container-sandbox $sandbox)
    let first_rt = if ($forced != "") { $forced } else { "docker" }
    if ($mock_log == "") and ($sb != "") {
        return { runtime: $first_rt, status: "skipped_sandbox", detail: "sandbox" }
    }
    if ($mock_log != "") {
        $"container-probe: ($first_rt) compose version\n" | save --append $mock_log
        let st = ($env.YGG_MOCK_CONTAINER_STATUS? | default "ok")
        return { runtime: $first_rt, status: (if ($st == "") { "ok" } else { $st }), detail: "mock" }
    }
    if ($forced != "") {
        return (probe-runtime $forced)
    }
    let results = ($CONTAINER_RUNTIMES | each { |r| probe-runtime $r })
    let ok = ($results | where status == "ok")
    if not ($ok | is-empty) { return ($ok | first) }
    let pick = ($results | where status != "no_runtime")
    if ($pick | is-empty) {
        { runtime: "", status: "no_runtime", detail: "neither docker nor podman found in PATH" }
    } else {
        $pick | first
    }
}

# argv for a compose action (no -v / --volumes / --rmi ever)
export def build-compose-argv [runtime: string, action: string, stack: record]: nothing -> list<string> {
    let files = (["-f" $stack.file] | append (if (($stack.override? | default "") != "") { ["-f" $stack.override] } else { [] }))
    match $action {
        "up" => ([$runtime "compose"] | append $files | append ["-p" $stack.project "up" "-d" "--remove-orphans"]),
        "down" => [$runtime "compose" "-p" $stack.project "down"],
        "pull" => ([$runtime "compose"] | append $files | append ["-p" $stack.project "pull" "--ignore-buildable"]),
        "build" => ([$runtime "compose"] | append $files | append ["-p" $stack.project "build" "--pull"]),
        _ => (error make { msg: $"Unknown compose action '($action)'" })
    }
}

# Execute a compose argv (mock / sandbox / dry-run aware)
export def run-compose [
    argv: list<string>,
    timeout: int,
    --dry-run,
    --sandbox: string = ""
]: nothing -> record<status: string, stderr: string> {
    if $dry_run { return { status: "dry_run", stderr: "" } }
    let mock_log = ($env.YGG_MOCK_PKG_LOG? | default "")
    let sb = (container-sandbox $sandbox)
    if ($mock_log == "") and ($sb != "") { return { status: "skipped_sandbox", stderr: "" } }
    let cmd_str = ($argv | str join " ")
    if ($mock_log != "") {
        let fails = ($env.YGG_MOCK_CONTAINER_FAIL? | default "" | split row "," | each { |c| $c | str trim } | where { |c| $c != "" })
        $"container: ($cmd_str)\n" | save --append $mock_log
        if ($fails | any { |f| $cmd_str | str contains $f }) {
            return { status: "failed", stderr: $"mock failure: ($cmd_str)" }
        }
        return { status: "ok", stderr: "" }
    }
    let r = (run-with-timeout $argv $timeout)
    if $r.exit_code == 0 { { status: "ok", stderr: "" } } else { { status: "failed", stderr: ($r.stderr | str trim) } }
}

# True when any service of the compose file declares `build`; YAML is parsed, regex fallback for tags
export def stack-has-build [file: string]: nothing -> bool {
    let raw = (try { open --raw $file } catch { return false })
    try {
        let y = ($raw | from yaml)
        let svc = (if (($y | describe) starts-with "record") { $y.services? } else { null })
        if $svc == null or not (($svc | describe) starts-with "record") { return false }
        $svc | values | any { |v| (($v | describe) starts-with "record") and ($v.build? != null) }
    } catch {
        $raw | lines | any { |l| $l =~ '^\s+build:' }
    }
}

# SHA-256 over compose file, override and sibling .env (missing files skipped)
export def stack-inputs-hash [stack: record]: nothing -> string {
    let dir = ($stack.file | path dirname)
    let cands = ([$stack.file ($stack.override? | default "") ($dir | path join ".env")] | where { |f| $f != "" })
    $cands | each { |f|
        if (($f | path type) == "file") { $"($f | path basename):(open --raw $f | hash sha256)" } else { null }
    } | compact | str join "\n" | hash sha256
}
