# src/lint.nu
# Yggdrasil configuration manager — Static analysis, plan simulation & package probes for `ygg lint` (RFC-062)

use manifest.nu [load-module-manifest, eval-scope-expression, list-module-scopes, resolve-effective-plan, YGG_MANIFEST_KEYS, KNOWN_OS_VALUES, DISTRO_AUTO_SCOPES]
use link.nu [resolve-link-targets, compute-link-ops, preflight-check]
use state.nu [detect-host-os]
use pkg.nu [KNOWN_PKG_MANAGERS, probe-packages]
use container.nu [detect-container-runtime, run-compose, find-override-file]

const LINT_SRC_DIR = (path self | path dirname)

const COMPANION_TOMLS = ["packages.toml", "links.toml", "env.toml", "aliases.toml", "services.toml", "secrets.example.toml"]
const MANIFEST_COMPANIONS = ["packages.toml", "links.toml", "env.toml", "aliases.toml", "services.toml"]
const COMPOSE_DEFAULT_NAMES = ["compose.yaml", "compose.yml", "docker-compose.yaml", "docker-compose.yml"]

def is-record [v: any]: nothing -> bool {
    ($v | describe) starts-with "record"
}

def has-wildcard-chars [s: string]: nothing -> bool {
    ($s | str contains "*") or ($s | str contains "?") or ($s | str contains "[")
}

def has-win32-invalid-chars [s: string]: nothing -> bool {
    ($s | str contains "*") or ($s | str contains "?")
}

def native-rel [rel: string]: nothing -> string {
    $rel | str replace --all "/" (char path_sep) | str replace --all "\\" (char path_sep)
}

def to-str-list [v: any]: nothing -> list<string> {
    if $v == null {
        []
    } else if (($v | describe) starts-with "list") {
        $v | where { |x| ($x | describe) == "string" }
    } else if (($v | describe) == "string") {
        [$v]
    } else {
        []
    }
}

def safe-path-type [p: string]: nothing -> any {
    if ($p == "") or (has-win32-invalid-chars $p) {
        return null
    }
    try { $p | path type } catch { null }
}

def safe-path-exists [p: string]: nothing -> bool {
    if ($p == "") or (has-win32-invalid-chars $p) {
        return false
    }
    try { $p | path exists } catch { false }
}

def safe-dir-exists [p: string]: nothing -> bool {
    if not (safe-path-exists $p) {
        return false
    }
    try { ($p | path expand | path type) == "dir" } catch { false }
}

def safe-file-exists [p: string]: nothing -> bool {
    if not (safe-path-exists $p) {
        return false
    }
    try { ($p | path expand | path type) == "file" } catch { false }
}

# Construct a finding record matching `src/doctor.nu` schema
export def lint-finding [
    check: string,
    severity: string,
    target: string,
    detail: string,
    fix: string
]: nothing -> record<check: string, severity: string, target: string, detail: string, fix: string> {
    { check: $check, severity: $severity, target: $target, detail: $detail, fix: $fix }
}

def parse-toml-file [path: string, label: string]: nothing -> record<ok: bool, data: any, err: string> {
    let ptype = (safe-path-type $path)
    if ($ptype == "symlink") and (not (safe-path-exists $path)) {
        return { ok: false, data: null, err: $"($label) is a broken symlink" }
    }
    if not (safe-file-exists $path) {
        return { ok: false, data: null, err: $"($label) is not a regular file" }
    }
    try {
        let data = (open $path)
        if not (is-record $data) {
            { ok: false, data: null, err: $"($label) must parse as a TOML table" }
        } else {
            { ok: true, data: $data, err: "" }
        }
    } catch { |e|
        { ok: false, data: null, err: ($e.rendered? | default $e.msg) }
    }
}

def validate-os-field [os_raw: any]: nothing -> list<record> {
    if ($os_raw == null) or ($os_raw == []) or ($os_raw == "") {
        return []
    }
    let os_list = if (($os_raw | describe) starts-with "list") { $os_raw } else { [$os_raw] }
    mut out = []
    for val in $os_list {
        let ok = (($val | describe) == "string") and (($val | str lowercase) in $KNOWN_OS_VALUES)
        if not $ok {
            $out = ($out | append (lint-finding "schema" "error" "ygg.toml os" $"Unknown OS value '($val)' in ygg.toml" $"Use supported OS values: ($KNOWN_OS_VALUES | str join ', ')"))
        }
    }
    $out
}

def validate-pkg-managers [pkg_map: any, target_prefix: string]: nothing -> list<record> {
    if $pkg_map == null {
        return []
    }
    if not (is-record $pkg_map) {
        return [(lint-finding "schema" "error" $target_prefix $"($target_prefix) must be a table mapping package managers to package lists" $"Fix ($target_prefix) structure")]
    }
    mut out = []
    for mgr in ($pkg_map | columns) {
        if $mgr not-in $KNOWN_PKG_MANAGERS {
            let tgt = ($target_prefix + " " + $mgr)
            $out = ($out | append (lint-finding "schema" "error" $tgt $"Unknown package manager '($mgr)' in ($target_prefix)" $"Use a supported package manager: ($KNOWN_PKG_MANAGERS | str join ', ')"))
        }
    }
    $out
}

def validate-scope-pkg-managers [scopes_rec: any]: nothing -> list<record> {
    if not (is-record $scopes_rec) {
        return []
    }
    mut out = []
    for s_name in ($scopes_rec | columns) {
        let s_val = ($scopes_rec | get $s_name)
        if (is-record $s_val) and ($s_val.packages? != null) {
            let prefix = ("[scope." + $s_name + ".packages]")
            $out = ($out | append (validate-pkg-managers $s_val.packages $prefix))
        }
    }
    $out
}

# L1: Validate ygg.toml, companion TOML files, top-level keys, OS values, and package managers
export def lint-schemas [mod_dir: string]: nothing -> record<findings: list<record>, manifest: any> {
    if not (safe-dir-exists $mod_dir) {
        return {
            findings: [(lint-finding "schema" "error" "ygg.toml" $"Module directory '($mod_dir)' does not exist or is not a directory" "Provide an existing module directory")],
            manifest: null
        }
    }

    let ygg_path = ($mod_dir | path join "ygg.toml")
    if (safe-path-type $ygg_path) == null {
        return {
            findings: [(lint-finding "schema" "error" "ygg.toml" $"Missing 'ygg.toml' in '($mod_dir)'" "Create a valid ygg.toml manifest")],
            manifest: null
        }
    }

    let ygg_parse = (parse-toml-file $ygg_path "ygg.toml")
    if not $ygg_parse.ok {
        return {
            findings: [(lint-finding "schema" "error" "ygg.toml" $"Failed to parse ygg.toml: ($ygg_parse.err)" "Fix TOML syntax in ygg.toml")],
            manifest: null
        }
    }

    let raw_ygg = $ygg_parse.data
    mut findings = []

    for k in ($raw_ygg | columns) {
        if $k not-in $YGG_MANIFEST_KEYS {
            $findings = ($findings | append (lint-finding "schema" "warn" $"ygg.toml ($k)" $"Unknown top-level key '($k)' in ygg.toml" $"Remove or rename unknown key '($k)' in ygg.toml"))
        }
    }

    mut manifest_companion_failed = false
    for fname in $COMPANION_TOMLS {
        let p = ($mod_dir | path join $fname)
        if (safe-path-type $p) != null {
            let res = (parse-toml-file $p $fname)
            if not $res.ok {
                $findings = ($findings | append (lint-finding "schema" "error" $fname $"Failed to parse ($fname): ($res.err)" $"Fix TOML syntax in ($fname)"))
                if $fname in $MANIFEST_COMPANIONS {
                    $manifest_companion_failed = true
                }
            }
        }
    }

    mut manifest: any = null
    if not $manifest_companion_failed {
        let loaded = (try {
            { ok: true, data: (load-module-manifest $mod_dir), err: "" }
        } catch { |e|
            { ok: false, data: null, err: ($e.rendered? | default $e.msg) }
        })
        if $loaded.ok {
            $manifest = $loaded.data
        } else {
            $findings = ($findings | append (lint-finding "schema" "error" "ygg.toml" $loaded.err "Fix manifest validation error in ygg.toml"))
        }
    }

    if $manifest != null {
        $findings = ($findings | append (validate-os-field $manifest.os))
        $findings = ($findings | append (validate-pkg-managers ($manifest.packages? | default {}) "[packages]"))
        $findings = ($findings | append (validate-scope-pkg-managers ($manifest.scope? | default {})))
    } else {
        $findings = ($findings | append (validate-os-field ($raw_ygg.os? | default null)))
        $findings = ($findings | append (validate-pkg-managers ($raw_ygg.packages? | default null) "[packages]"))
        $findings = ($findings | append (validate-scope-pkg-managers ($raw_ygg.scope? | default null)))
    }

    { findings: $findings, manifest: $manifest }
}

def check-source-key [
    mod_dir: string,
    target: string,
    key: string,
    mode: string = "",
    expect_file: bool = false
]: nothing -> list<record> {
    let clean = ($key | str replace --regex '^\.[\\/]' '')
    if $clean == "" {
        return [(lint-finding "source" "error" $target $"Empty source path '($key)'" "Specify a valid relative path inside the module")]
    }

    if $clean =~ '[\\/]\*$' {
        let base_rel = ($clean | str replace --regex '[\\/]\*$' '')
        if not (has-wildcard-chars $base_rel) {
            let full = if ($base_rel == "") { $mod_dir } else { $mod_dir | path join (native-rel $base_rel) }
            if not (safe-path-exists $full) {
                return [(lint-finding "source" "error" $target $"Glob source directory '($base_rel)' not found in module" $"Create directory '($base_rel)' or fix entry '($key)'")]
            }
            if not (safe-dir-exists $full) {
                return [(lint-finding "source" "error" $target $"Glob source '($key)' requires a directory, but '($base_rel)' is not a directory" $"Use a directory for '($base_rel)' or remove /*")]
            }
            return []
        }
    }

    if (has-wildcard-chars $clean) {
        let segs = ($clean | str replace --all "\\" "/" | split row "/")
        mut prefix_segs = []
        for seg in $segs {
            if (has-wildcard-chars $seg) {
                break
            }
            $prefix_segs = ($prefix_segs | append $seg)
        }
        let base_dir = if ($prefix_segs | is-empty) {
            $mod_dir
        } else {
            $mod_dir | path join (native-rel ($prefix_segs | str join "/"))
        }
        if not (safe-dir-exists $base_dir) {
            let base_desc = if ($prefix_segs | is-empty) { "." } else { $prefix_segs | str join "/" }
            return [(lint-finding "source" "error" $target $"Wildcard base directory '($base_desc)' not found in module" $"Create directory '($base_desc)' or fix pattern '($key)'")]
        }
        return []
    }

    let full = ($mod_dir | path join (native-rel $clean))
    let ptype = (safe-path-type $full)
    if not (safe-path-exists $full) {
        let detail = if ($ptype == "symlink") {
            $"Source '($clean)' is a broken symlink in module"
        } else {
            $"Source '($clean)' not found in module"
        }
        return [(lint-finding "source" "error" $target $detail $"Add '($clean)' to module or remove entry '($key)'")]
    }
    if ($mode == "dir") and ($ptype != "dir") {
        return [(lint-finding "source" "error" $target $"mode = \"dir\" requires a directory source, but '($clean)' is ($ptype)" $"Point '($key)' to a directory or remove mode = \"dir\"")]
    }
    if $expect_file and not (safe-file-exists $full) {
        return [(lint-finding "source" "error" $target $"Compose file '($clean)' is not a regular file" $"Provide a valid compose file at '($clean)'")]
    }
    []
}

def check-link-map [
    mod_dir: string,
    file_name: string,
    section: string,
    entries: any,
    --check-mode
]: nothing -> list<record> {
    if not (is-record $entries) {
        return []
    }
    mut out = []
    for key in ($entries | columns) {
        let val = ($entries | get $key)
        let mode = if $check_mode and (is-record $val) { ($val.mode? | default "") } else { "" }
        let tgt = ($file_name + " " + $section + " " + $key)
        $out = ($out | append (check-source-key $mod_dir $tgt $key $mode))
    }
    $out
}

def check-container-files [
    mod_dir: string,
    file_name: string,
    section: string,
    cfg: any
]: nothing -> list<record> {
    if not (is-record $cfg) {
        return []
    }
    mut out = []
    for cf in (to-str-list ($cfg.files? | default null)) {
        if $cf != "" {
            let tgt = ($file_name + " " + $section + " " + $cf)
            $out = ($out | append (check-source-key $mod_dir $tgt $cf "" true))
        }
    }
    $out
}

# L2: Traverse raw ygg.toml and links.toml directly to validate all declared sources across all scopes
export def lint-sources [mod_dir: string]: nothing -> list<record> {
    if not (safe-dir-exists $mod_dir) {
        return []
    }

    mut findings = []

    let ygg_path = ($mod_dir | path join "ygg.toml")
    if (safe-file-exists $ygg_path) {
        let ygg_res = (parse-toml-file $ygg_path "ygg.toml")
        if $ygg_res.ok {
            let raw = $ygg_res.data
            $findings = ($findings | append (check-link-map $mod_dir "ygg.toml" "[links]" ($raw.links? | default null) --check-mode))
            $findings = ($findings | append (check-link-map $mod_dir "ygg.toml" "[save]" ($raw.save? | default null)))
            $findings = ($findings | append (check-container-files $mod_dir "ygg.toml" "[containers]" ($raw.containers? | default null)))

            if (is-record ($raw.scope? | default null)) {
                for expr in ($raw.scope | columns) {
                    let sv = ($raw.scope | get $expr)
                    if (is-record $sv) {
                        $findings = ($findings | append (check-link-map $mod_dir "ygg.toml" ("[scope." + $expr + ".links]") ($sv.links? | default null) --check-mode))
                        $findings = ($findings | append (check-link-map $mod_dir "ygg.toml" ("[scope." + $expr + ".save]") ($sv.save? | default null)))
                        $findings = ($findings | append (check-container-files $mod_dir "ygg.toml" ("[scope." + $expr + ".containers]") ($sv.containers? | default null)))
                    }
                }
            }
        }
    }

    let links_path = ($mod_dir | path join "links.toml")
    if (safe-file-exists $links_path) {
        let links_res = (parse-toml-file $links_path "links.toml")
        if $links_res.ok {
            let raw = $links_res.data
            $findings = ($findings | append (check-link-map $mod_dir "links.toml" "[links]" ($raw.links? | default null) --check-mode))

            let root_entries = ($raw
                | columns
                | where { |c| $c not-in ["links", "scope", "services"] }
                | reduce -f {} { |c, acc| $acc | upsert $c ($raw | get $c) })
            $findings = ($findings | append (check-link-map $mod_dir "links.toml" "[links]" $root_entries --check-mode))

            if (is-record ($raw.scope? | default null)) {
                for expr in ($raw.scope | columns) {
                    let sv = ($raw.scope | get $expr)
                    if (is-record $sv) {
                        let s_links = if ($sv.links? != null) {
                            $sv.links
                        } else {
                            $sv | columns | where { |c| $c != "services" } | reduce -f {} { |c, acc| $acc | upsert $c ($sv | get $c) }
                        }
                        $findings = ($findings | append (check-link-map $mod_dir "links.toml" ("[scope." + $expr + "]") $s_links --check-mode))
                    }
                }
            }
        }
    }

    for cname in $COMPOSE_DEFAULT_NAMES {
        let cp = ($mod_dir | path join $cname)
        if ((safe-path-type $cp) == "symlink") and (not (safe-path-exists $cp)) {
            $findings = ($findings | append (lint-finding "source" "error" $cname $"Compose file '($cname)' is a broken symlink" $"Fix or remove broken symlink '($cname)'"))
        }
    }

    $findings
}

# L3: Validate every declared scope expression via eval-scope-expression
export def lint-scopes [manifest: record]: nothing -> list<record> {
    mut findings = []
    for expr in (list-module-scopes $manifest) {
        if ($expr | str trim) == "" {
            $findings = ($findings | append (lint-finding "scope" "error" "[scope.]" "Empty scope expression" "Provide a non-empty scope name or boolean expression"))
            continue
        }
        let res = (try {
            eval-scope-expression $expr [] | ignore
            { ok: true, err: "" }
        } catch { |e|
            { ok: false, err: ($e.rendered? | default $e.msg) }
        })
        if not $res.ok {
            let tgt = ("[scope." + $expr + "]")
            $findings = ($findings | append (lint-finding "scope" "error" $tgt $"Invalid scope expression '($expr)': ($res.err)" "Fix boolean scope expression syntax (operators: and/&&, or/||, not/!, parentheses)"))
        }
    }
    $findings
}

# L4: Check setup.nu syntax via `nu-check --debug` with engine src include path
export def lint-setup [mod_dir: string, src_dir: string]: nothing -> list<record> {
    let setup_path = ($mod_dir | path join "setup.nu")
    let ptype = (safe-path-type $setup_path)
    if $ptype == null {
        return []
    }
    if ($ptype == "symlink") and (not (safe-path-exists $setup_path)) {
        return [(lint-finding "setup" "error" "setup.nu" "setup.nu is a broken symlink" "Fix or replace broken setup.nu symlink")]
    }
    if not (safe-file-exists $setup_path) {
        return [(lint-finding "setup" "error" "setup.nu" "setup.nu exists but is not a regular file" "Replace setup.nu with a valid Nushell script")]
    }

    let abs_src = ($src_dir | path expand)
    let abs_setup = ($setup_path | path expand -n)
    let res = (with-env { YGG_HOST_OS_OVERRIDE: null, YGG_LINT_SETUP: $abs_setup } {
        ^nu -I $abs_src -c 'nu-check --debug $env.YGG_LINT_SETUP' | complete
    })
    if $res.exit_code == 0 {
        return []
    }

    let ide = (with-env { YGG_HOST_OS_OVERRIDE: null } {
        ^nu -I $abs_src --ide-check 10 $abs_setup | complete
    })
    let ide_msgs = if ($ide.exit_code == 0) and (($ide.stdout | str trim) != "") {
        let diags = ($ide.stdout
            | lines
            | each { |l| try { $l | from json } catch { null } }
            | where { |x| ($x != null) and ($x.type? == "diagnostic") })
        let errs = ($diags | where { |d| ($d.severity? | default "") == "Error" })
        let chosen = if ($errs | is-not-empty) { $errs } else { $diags }
        $chosen | each { |d| $d.message? | default "" } | where { |m| $m != "" } | uniq
    } else {
        []
    }

    let diag = if ($ide_msgs | is-not-empty) {
        $ide_msgs | str join "; "
    } else {
        let raw_err = ($res.stderr | ansi strip | str trim)
        if $raw_err != "" { $raw_err } else { "Syntax or parse check failed in setup.nu" }
    }
    [(lint-finding "setup" "error" "setup.nu" $diag "Fix syntax error in setup.nu")]
}

def collect-compose-files [mod_dir: string, manifest: record]: nothing -> list<record<rel: string, full: string>> {
    let base_raw = ($manifest.containers?.files? | default null)
    let base_rels = if $base_raw != null {
        to-str-list $base_raw
    } else {
        $COMPOSE_DEFAULT_NAMES | where { |n| safe-file-exists ($mod_dir | path join $n) }
    }

    mut scope_rels = []
    let scopes = ($manifest.scope? | default {})
    if (is-record $scopes) {
        for s_val in ($scopes | values) {
            if (is-record $s_val) and ($s_val.containers?.files? != null) {
                $scope_rels = ($scope_rels | append (to-str-list $s_val.containers.files))
            }
        }
    }

    $base_rels
    | append $scope_rels
    | each { |r| $r | str replace --all "\\" "/" | str replace --regex '^\./' '' }
    | where { |r| $r != "" }
    | uniq
    | each { |rel| { rel: $rel, full: ($mod_dir | path join (native-rel $rel)) } }
    | where { |item| safe-file-exists $item.full }
}

# Validate module compose files via `<runtime> compose -f <file> config -q`
export def lint-compose [mod_dir: string, manifest: record]: nothing -> list<record> {
    let files = (collect-compose-files $mod_dir $manifest)
    if ($files | is-empty) {
        return []
    }

    with-env { YGG_HOST_OS_OVERRIDE: null } {
        let rt = (detect-container-runtime {})
        if $rt.status != "ok" {
            let rel_target = ($files | get rel | str join ", ")
            let why = if $rt.detail != "" { $"($rt.status): ($rt.detail)" } else { $rt.status }
            return [(lint-finding "compose" "info" $rel_target $"Container runtime unavailable \(($why)\); compose validation skipped" "Install or start Docker / Podman Compose v2+ to validate compose files")]
        }

        mut findings = []
        for item in $files {
            let override = (find-override-file $item.full)
            let argv = (
                [$rt.runtime, "compose", "-f", $item.full]
                | append (if $override != "" { ["-f", $override] } else { [] })
                | append ["config", "-q"]
            )
            let res = (run-compose $argv 30)
            if $res.status != "ok" {
                let err_detail = if $res.stderr != "" { $res.stderr } else { $"compose config -q failed with status '($res.status)'" }
                $findings = ($findings | append (lint-finding "compose" "error" $item.rel $err_detail $"Fix compose syntax or configuration in ($item.rel)"))
            }
        }
        $findings
    }
}

def extract-scope-tokens [expr: string]: nothing -> list<string> {
    let raw = ($expr | str trim)
    if $raw == "" {
        return []
    }
    $raw
    | str replace --all "(" " ( "
    | str replace --all ")" " ) "
    | str replace --all "!" " not "
    | str replace --all "&&" " and "
    | str replace --all "||" " or "
    | split row -r '\s+'
    | each { |t| $t | str lowercase | str replace --all '"' '' | str replace --all "'" "" }
    | where { |t| $t not-in ["and", "or", "not", "(", ")", ""] }
    | uniq
}

# Compute target OS/distro values to simulate in L5 from manifest.os and declared distro scopes
export def compute-lint-targets [manifest: record, os_filter: list<string> = []]: nothing -> list<string> {
    let base_os = (to-str-list ($manifest.os? | default [])
        | each { |s| $s | str lowercase }
        | where { |s| $s != "" })
    mut scope_distros = []
    for expr in (list-module-scopes $manifest) {
        for tok in (extract-scope-tokens $expr) {
            if $tok in $DISTRO_AUTO_SCOPES {
                $scope_distros = ($scope_distros | append $tok)
            }
        }
    }
    let targets = ($base_os | append $scope_distros | uniq)
    if ($os_filter | is-empty) {
        $targets
    } else {
        let norm_filter = ($os_filter | each { |s| $s | str lowercase } | where { |s| $s != "" })
        $targets | where { |t| $t in $norm_filter }
    }
}

# Compute default L5 scope sets: empty scopes plus each non-OS scope token individually
export def compute-scope-sets [manifest: record]: nothing -> list<list<string>> {
    mut user_scopes = []
    for expr in (list-module-scopes $manifest) {
        for tok in (extract-scope-tokens $expr) {
            if $tok not-in $KNOWN_OS_VALUES {
                $user_scopes = ($user_scopes | append $tok)
            }
        }
    }
    let unique_scopes = ($user_scopes | uniq)
    [[]] | append ($unique_scopes | each { |s| [$s] })
}

def is-git-url [src: string]: nothing -> bool {
    ($src | str starts-with "http://") or ($src | str starts-with "https://") or ($src | str starts-with "git@") or ($src | str starts-with "ssh://") or ($src | str starts-with "file://")
}

def clone-fixture-dep [
    rel_label: string,
    dep_name: string,
    git_url: string,
    ref: string,
    deps_dir: string
]: nothing -> record<ok: bool, path: string, findings: list<record>> {
    if ($dep_name == "") or ($dep_name | str contains "/") or ($dep_name | str contains "\\") or ($dep_name | str contains "..") or (has-win32-invalid-chars $dep_name) {
        return {
            ok: false,
            path: "",
            findings: [(lint-finding "fixture" "error" $rel_label $"Invalid dependency name '($dep_name)' in ($rel_label)" "Use a valid module name without path separators")]
        }
    }
    if ($git_url | str starts-with "-") or ($ref | str starts-with "-") {
        return {
            ok: false,
            path: "",
            findings: [(lint-finding "fixture" "error" $rel_label $"Invalid git source or ref for '($dep_name)' in ($rel_label)" "Provide a valid git URL and ref")]
        }
    }

    let dep_dir = ($deps_dir | path join $dep_name)
    if (safe-dir-exists $dep_dir) {
        return { ok: true, path: $dep_dir, findings: [] }
    }

    let argv = (
        ["clone", "--depth", "1"]
        | append (if $ref != "" { ["--branch", $ref] } else { [] })
        | append ["--", $git_url, $dep_dir]
    )
    let clone_res = (try {
        with-env { GIT_TERMINAL_PROMPT: "0" } {
            ^git ...$argv | complete
        }
    } catch { |e|
        { exit_code: 1, stdout: "", stderr: ($e.rendered? | default $e.msg) }
    })
    if $clone_res.exit_code != 0 {
        try { rm -rf $dep_dir } catch {}
        let err_tail = ($clone_res.stderr | ansi strip | str trim)
        let msg = if $err_tail != "" {
            $"Failed to clone dependency '($dep_name)' from '($git_url)': ($err_tail)"
        } else {
            $"Failed to clone dependency '($dep_name)' from '($git_url)'"
        }
        return {
            ok: false,
            path: "",
            findings: [(lint-finding "fixture" "error" $rel_label $msg $"Check 'source' and 'ref' for '($dep_name)' in ($rel_label)")]
        }
    }
    { ok: true, path: $dep_dir, findings: [] }
}

def load-lint-fixtures [
    mod_dir: string,
    mod_name: string,
    deps_dir: string
]: nothing -> record<has_fixtures: bool, fixtures: list<record>, findings: list<record>> {
    let hosts_dir = ($mod_dir | path join "ci" "hosts")
    if not (safe-dir-exists $hosts_dir) {
        return { has_fixtures: false, fixtures: [], findings: [] }
    }

    let files = (try { ls -a $hosts_dir } catch { [] }
        | where { |it|
            let b = ($it.name | path basename)
            ($b not-in [".", ".."]) and ($b | str ends-with ".toml")
        }
        | sort-by name)

    if ($files | is-empty) {
        return { has_fixtures: false, fixtures: [], findings: [] }
    }

    mut fixtures = []
    mut findings = []

    for f in $files {
        let fname = ($f.name | path basename)
        let rel_label = $"ci/hosts/($fname)"
        let parsed = (parse-toml-file $f.name $rel_label)
        if not $parsed.ok {
            $findings = ($findings | append (lint-finding "fixture" "error" $rel_label $"Failed to parse ($rel_label): ($parsed.err)" $"Fix TOML syntax in ($rel_label)"))
            continue
        }

        let data = $parsed.data
        let has_os = ($data.os? != null)
        let fx_os = if $has_os {
            to-str-list $data.os | each { |s| $s | str lowercase } | where { |s| $s != "" } | uniq
        } else {
            []
        }

        let raw_mods = ($data.modules? | default [])
        let mods_desc = ($raw_mods | describe)
        if not (($mods_desc starts-with "list") or ($mods_desc starts-with "table")) {
            $findings = ($findings | append (lint-finding "fixture" "error" $rel_label $"Invalid 'modules' in ($rel_label): expected array of tables [[modules]]" $"Fix [[modules]] structure in ($rel_label)"))
            continue
        }

        mut extra_mods = []
        mut self_scopes = []
        mut has_self = false
        mut fx_ok = true

        for entry in $raw_mods {
            if not (is-record $entry) {
                $findings = ($findings | append (lint-finding "fixture" "error" $rel_label $"Each [[modules]] entry in ($rel_label) must be a TOML table" $"Fix [[modules]] entry in ($rel_label)"))
                $fx_ok = false
                continue
            }

            let entry_name = ($entry.name? | default "" | into string | str trim)
            if $entry_name == "" {
                $findings = ($findings | append (lint-finding "fixture" "error" $rel_label $"Module entry in ($rel_label) missing required field 'name'" $"Add 'name' to each [[modules]] entry in ($rel_label)"))
                $fx_ok = false
                continue
            }

            let scopes = (to-str-list ($entry.scopes? | default []))
            if $entry_name == $mod_name {
                $has_self = true
                $self_scopes = $scopes
                $extra_mods = ($extra_mods | append ($entry | upsert name $entry_name | upsert path $mod_dir | upsert scopes $scopes))
            } else {
                let src = ($entry.source? | default "" | into string | str trim)
                if $src == "" {
                    $findings = ($findings | append (lint-finding "fixture" "error" $rel_label $"Dependency '($entry_name)' in ($rel_label) is missing 'source'" $"Specify 'source' (relative path or git URL) for '($entry_name)' in ($rel_label)"))
                    $fx_ok = false
                    continue
                }

                let ref = ($entry.ref? | default "" | into string | str trim)
                if (is-git-url $src) {
                    let cloned = (clone-fixture-dep $rel_label $entry_name $src $ref $deps_dir)
                    if not $cloned.ok {
                        $findings = ($findings | append $cloned.findings)
                        $fx_ok = false
                        continue
                    }
                    $extra_mods = ($extra_mods | append ($entry | upsert name $entry_name | upsert path $cloned.path | upsert scopes $scopes))
                } else {
                    let rel_path = ($mod_dir | path join (native-rel $src) | path expand -n)
                    if not (safe-dir-exists $rel_path) {
                        $findings = ($findings | append (lint-finding "fixture" "error" $rel_label $"Dependency '($entry_name)' source '($src)' not found at '($rel_path)'" $"Fix relative 'source' path for '($entry_name)' in ($rel_label)"))
                        $fx_ok = false
                        continue
                    }
                    $extra_mods = ($extra_mods | append ($entry | upsert name $entry_name | upsert path $rel_path | upsert scopes $scopes))
                }
            }
        }

        if not $has_self {
            $extra_mods = ($extra_mods | append { name: $mod_name, path: $mod_dir, scopes: [] })
        }

        if $fx_ok {
            $fixtures = ($fixtures | append {
                file: $rel_label,
                has_os: $has_os,
                os: $fx_os,
                self_scopes: $self_scopes,
                extra_modules: $extra_mods
            })
        }
    }

    { has_fixtures: true, fixtures: $fixtures, findings: $findings }
}

def map-preflight-fix [reason: string]: nothing -> string {
    match $reason {
        "missing_dependency" => "Add a ci/hosts/*.toml fixture declaring this dependency, or add the module to host.toml",
        "nesting_conflict" => "Do not link both a parent directory and a path inside it; split the directory link into per-file links or glob /*",
        "ownership_conflict" => "Point the glob destination to a regular directory instead of an unmanaged symlink/junction",
        "missing_source" => "Add the missing source file/directory to the module or fix the link key",
        "invalid_mode_source" => "Point the link key to a directory or remove mode = \"dir\"",
        "shadowed_files" => "Link entries individually (glob /*) or confirm replacement with mode = \"dir\"",
        _ => "Resolve pre-flight conflict shown in detail"
    }
}

def run-single-plan-check [
    mod_name: string,
    target_os: string,
    scopes: list<string>,
    extra_mods: list<record>,
    has_fixture: bool,
    native: record,
    tmp_ygg: string,
    tmp_sb: string,
    tmp_mock_log: string
]: nothing -> list<record> {
    let is_cross_os = (
        ($target_os != $native.os)
        and ($target_os != $native.distro)
        and ($target_os not-in $native.auto_scopes)
    )
    let cross_note = if $is_cross_os {
        $" [план для ($target_os) построен на ($native.os); окончательная проверка — нативный прогон в CI]"
    } else {
        ""
    }
    let prev_override = ($env.YGG_HOST_OS_OVERRIDE? | default null)
    let plan_override = if $is_cross_os { $target_os } else { $prev_override }

    let res = (with-env {
        YGG_HOME: $tmp_ygg,
        YGG_SANDBOX: $tmp_sb,
        YGG_MOCK_PKG_LOG: $tmp_mock_log,
        YGG_HOST_OS_OVERRIDE: $plan_override
    } {
        try {
            let plan = (resolve-effective-plan $tmp_ygg --extra-modules $extra_mods)
            let resolved = (resolve-link-targets $plan --sandbox $tmp_sb)
            let ops = (compute-link-ops $tmp_ygg $resolved --sandbox $tmp_sb)
            let problems = (preflight-check $tmp_ygg $plan $resolved $ops --sandbox $tmp_sb --quiet)
            { ok: true, collisions: ($resolved.collisions? | default []), problems: $problems, err: "" }
        } catch { |e|
            { ok: false, collisions: [], problems: [], err: ($e.rendered? | default $e.msg) }
        }
    })

    if not $res.ok {
        let detail = ($res.err + $cross_note)
        return [((lint-finding "plan" "error" $"($mod_name): plan" $detail "Fix manifest or scope configuration causing plan resolution failure")
            | merge { os: $target_os, scopes: $scopes, cross_os: $is_cross_os })]
    }

    mut findings = []

    for c in $res.collisions {
        let target = $"($c.winner_module): ($c.winner_key)"
        let detail = ($"Target collision for '($c.dest)': '($c.winner_module): ($c.winner_key)' overrides '($c.loser_module): ($c.loser_key)'" + $cross_note)
        $findings = ($findings | append (
            (lint-finding "plan" "error" $target $detail "Remove or exclude the conflicting link/save target in one of the modules or adjust module scopes")
            | merge { os: $target_os, scopes: $scopes, cross_os: $is_cross_os }
        ))
    }

    for p in $res.problems {
        let is_unverified_dep = (not $has_fixture) and ($p.reason == "missing_dependency")
        let sev = if $is_unverified_dep { "warn" } else { "error" }
        let target = $"($p.module): ($p.key)"
        let base_detail = if $is_unverified_dep {
            $"($p.detail) \(dependency not verified without ci/hosts/ fixture\)"
        } else {
            $p.detail
        }
        let detail = ($base_detail + $cross_note)
        $findings = ($findings | append (
            (lint-finding "plan" $sev $target $detail (map-preflight-fix $p.reason))
            | merge { os: $target_os, scopes: $scopes, cross_os: $is_cross_os }
        ))
    }

    $findings
}

def lint-plan [
    mod_dir: string,
    manifest: record,
    native: record,
    os_filter: list<string>,
    tmp_ygg: string,
    tmp_sb: string,
    deps_dir: string,
    tmp_mock_log: string
]: nothing -> list<record> {
    let fx_res = (load-lint-fixtures $mod_dir $manifest.name $deps_dir)
    mut findings = $fx_res.findings

    if not $fx_res.has_fixtures {
        let targets = (compute-lint-targets $manifest $os_filter)
        let scope_sets = (compute-scope-sets $manifest)
        for target_os in $targets {
            for scopes in $scope_sets {
                let extra_mods = [{ name: $manifest.name, path: $mod_dir, scopes: $scopes }]
                $findings = ($findings | append (
                    run-single-plan-check $manifest.name $target_os $scopes $extra_mods false $native $tmp_ygg $tmp_sb $tmp_mock_log
                ))
            }
        }
        return $findings
    }

    let norm_filter = ($os_filter | each { |s| $s | str lowercase } | where { |s| $s != "" })
    let default_targets = (compute-lint-targets $manifest $os_filter)

    for fx in $fx_res.fixtures {
        let fx_targets = if $fx.has_os {
            if ($norm_filter | is-empty) {
                $fx.os
            } else {
                $fx.os | where { |t| $t in $norm_filter }
            }
        } else {
            $default_targets
        }
        for target_os in $fx_targets {
            $findings = ($findings | append (
                run-single-plan-check $manifest.name $target_os $fx.self_scopes $fx.extra_modules true $native $tmp_ygg $tmp_sb $tmp_mock_log
            ))
        }
    }

    $findings
}

def merge-pkg-map [acc: record, pkg_map: any]: nothing -> record {
    if not (is-record $pkg_map) {
        return $acc
    }
    mut out = $acc
    for mgr in ($pkg_map | columns) {
        let pkgs = (to-str-list ($pkg_map | get $mgr) | where { |p| $p != "" })
        if ($pkgs | is-not-empty) {
            let cur = ($out | get -o $mgr | default [])
            $out = ($out | upsert $mgr ($cur | append $pkgs | uniq))
        }
    }
    $out
}

def collect-module-packages [manifest: record]: nothing -> record {
    mut all_pkgs = (merge-pkg-map {} ($manifest.packages? | default {}))
    let scopes = ($manifest.scope? | default {})
    if (is-record $scopes) {
        for s_val in ($scopes | values) {
            if (is-record $s_val) {
                $all_pkgs = (merge-pkg-map $all_pkgs ($s_val.packages? | default null))
            }
        }
    }
    $all_pkgs
}

def lint-packages [manifest: record, native: record]: nothing -> list<record> {
    let all_pkgs = (collect-module-packages $manifest)
    if ($all_pkgs | is-empty) {
        return []
    }
    let probed = (probe-packages $all_pkgs --host-os $native)
    mut findings = []
    for r in $probed {
        if $r.status == "ok" {
            continue
        }
        let target = $"($r.mgr): ($r.pkg)"
        if $r.status == "not_found" {
            $findings = ($findings | append (lint-finding "packages" "error" $target $r.detail $"Verify package name/ID for ($r.mgr) or remove it from manifest"))
        } else if $r.status == "info" {
            $findings = ($findings | append (lint-finding "packages" "info" $target $r.detail $"Package manager ($r.mgr) is verified natively on its target OS in CI"))
        } else {
            $findings = ($findings | append (lint-finding "packages" "warn" $target $r.detail $"Ensure ($r.mgr) is installed and reachable, or re-run in CI"))
        }
    }
    $findings
}

# Run full read-only lint pipeline (L1-L5, compose, optional L6 --packages) in isolated temp sandbox
export def run-lint [
    mod_dir: string,
    --packages,
    --os: list<string> = [],
    --src-dir: string = ""
]: nothing -> list<record> {
    let native = (detect-host-os)
    let eff_src = if ($src_dir == "") { $LINT_SRC_DIR } else { $src_dir }
    let tmp_root = (mktemp -d -t ygg-lint-XXXXXX)

    let findings = (try {
        let tmp_ygg = ($tmp_root | path join "ygg")
        let tmp_sb = ($tmp_root | path join "sandbox")
        let deps_dir = ($tmp_root | path join "deps")
        let tmp_mock_log = ($tmp_root | path join "mock.log")
        mkdir $tmp_ygg
        mkdir $tmp_sb
        mkdir $deps_dir
        "" | save -f $tmp_mock_log

        let l1 = (lint-schemas $mod_dir)
        mut out = $l1.findings
        if $l1.manifest != null {
            let manifest = $l1.manifest
            let abs_mod_dir = ($mod_dir | path expand -n)
            $out = ($out | append (lint-sources $abs_mod_dir))
            $out = ($out | append (lint-scopes $manifest))
            $out = ($out | append (lint-setup $abs_mod_dir $eff_src))
            $out = ($out | append (lint-plan $abs_mod_dir $manifest $native $os $tmp_ygg $tmp_sb $deps_dir $tmp_mock_log))
            $out = ($out | append (lint-compose $abs_mod_dir $manifest))
            if $packages {
                $out = ($out | append (lint-packages $manifest $native))
            }
        }
        $out
    } catch { |e|
        try { rm -rf $tmp_root } catch {}
        error make { msg: ($e.rendered? | default $e.msg) }
    })

    try { rm -rf $tmp_root } catch {}
    $findings
}
