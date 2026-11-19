# src/lint.nu
# Yggdrasil configuration manager — Static analysis stages (L1-L4, compose) for `ygg lint` (RFC-062)

use manifest.nu [load-module-manifest, eval-scope-expression, list-module-scopes, YGG_MANIFEST_KEYS, KNOWN_OS_VALUES]
use pkg.nu [KNOWN_PKG_MANAGERS]
use container.nu [detect-container-runtime, run-compose, find-override-file]

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
