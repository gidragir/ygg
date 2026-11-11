# src/env.nu
# Yggdrasil configuration manager — Environment, Aliases & Secrets Compiler

use state.nu [detect-host-os, expand-target-path, restrict-file-access]
use manifest.nu [load-host-config]

# Format consolidated PowerShell script to update Windows User Environment (HKCU\Environment)
export def format-windows-env-script [clean_env: record, path_entries: list<string>, user_home: string]: nothing -> string {
    mut lines = [
        "$ErrorActionPreference = 'Stop'"
    ]

    for k in ($clean_env | columns) {
        let v = ($clean_env | get $k | into string)
        let esc_k = ($k | str replace --all "'" "''")
        let esc_v = ($v | str replace --all "'" "''")
        let line = ("[Environment]::SetEnvironmentVariable('" + $esc_k + "', '" + $esc_v + "', 'User')")
        $lines = ($lines | append $line)
    }

    if not ($path_entries | is-empty) {
        let clean_home = ($user_home | str trim -r -c "/" | str trim -r -c "\\")
        mut want_items = []
        for entry in $path_entries {
            let resolved = if ($entry == "~") {
                $clean_home
            } else if ($entry | str starts-with "~/") or ($entry | str starts-with "~\\") {
                let rel = ($entry | str substring 2..)
                $"($clean_home)\\($rel)"
            } else {
                $entry
            }
            let with_backslashes = ($resolved | str replace --all "/" "\\")
            let esc_entry = ($with_backslashes | str replace --all "'" "''")
            $want_items = ($want_items | append ("'" + $esc_entry + "'"))
        }

        let want_str = ($want_items | str join ", ")
        let line_want = ("$want = @(" + $want_str + ")")
        let line_cur = ("$cur = " + "[Environment]::GetEnvironmentVariable('Path', 'User')")
        let line_items = "$items = @(if ($cur) { $cur -split ';' | Where-Object { $_ } })"
        let line_new = "$new = @($want + ($items | Where-Object { $want -notcontains $_ }))"
        let line_set = ("[Environment]::SetEnvironmentVariable('Path', ($new -join ';'), 'User')")

        $lines = ($lines | append [
            $line_want,
            $line_cur,
            $line_items,
            $line_new,
            $line_set
        ])
    }

    ($lines | str join "\n") + "\n"
}

# Expand a leading `~` or `$HOME` in an env value (sandbox-aware); everything else stays literal
def resolve-env-value [v: string, sb: string]: nothing -> string {
    if ($v == "~") or ($v | str starts-with "~/") or ($v | str starts-with "~\\") {
        expand-target-path $v --sandbox $sb
    } else if ($v == "$HOME") or ($v | str starts-with "$HOME/") or ($v | str starts-with "$HOME\\") {
        expand-target-path ("~" + ($v | str substring 5..)) --sandbox $sb
    } else {
        $v
    }
}

# Read secret key/value record from a TOML file ([env] section or top-level keys)
def secret-keys [p: string]: nothing -> record {
    if not ($p | path exists) {
        return {}
    }
    let d = (try { open $p } catch { {} })
    let extracted = if "env" in $d { $d.env } else { $d }
    if (($extracted | describe) starts-with "record") { $extracted } else { {} }
}

# Keys declared in a secrets template that are absent or empty in the secrets file (names only)
export def missing-secret-keys [template: string, secrets: string]: nothing -> list<string> {
    let have = (secret-keys $secrets)
    secret-keys $template
    | columns
    | where { |k| (($have | get -o $k | default "") | into string) == "" }
}

# Classify secret value by URI scheme prefix (RFC-041)
# kind in "literal" | "op" | "bw" | "pass" | "eval"
# ref: stripped string for literal:/pass:/eval:; untouched whole URI for op:// and bw://
export def classify-secret-value [raw: string]: nothing -> record<kind: string, ref: string> {
    if ($raw | str starts-with "literal:") {
        { kind: "literal", ref: ($raw | str substring 8..) }
    } else if ($raw | str starts-with "op://") {
        { kind: "op", ref: $raw }
    } else if ($raw | str starts-with "bw://") {
        { kind: "bw", ref: $raw }
    } else if ($raw | str starts-with "pass:") {
        { kind: "pass", ref: ($raw | str substring 5..) }
    } else if ($raw | str starts-with "eval:") {
        { kind: "eval", ref: ($raw | str substring 5..) }
    } else {
        { kind: "literal", ref: $raw }
    }
}

# Load secrets record from $ygg_home/secrets.toml ([env] section or top-level keys)
export def load-secrets-env [ygg_home: string]: nothing -> record {
    let sec_file = ($ygg_home | path join "secrets.toml")
    secret-keys $sec_file
}

# Validate that required CLIs for secret schemes in secrets.toml exist in PATH (RFC-041)
export def validate-secret-providers [ygg_home: string]: nothing -> list<string> {
    let sec_env = (load-secrets-env $ygg_home)
    if ($sec_env | is-empty) {
        return []
    }
    let kinds = ($sec_env
        | values
        | where { |v| not (($v | describe) starts-with "record") and not (($v | describe) starts-with "table") }
        | each { |v| (classify-secret-value ($v | into string)).kind }
        | uniq
    )

    let provider_map = {
        op: "op"
        bw: "bw"
        pass: "pass"
        eval: "nu"
    }

    mut missing = []
    for kind in $kinds {
        if $kind in $provider_map {
            let cli = ($provider_map | get $kind)
            let exists = (try {
                which $cli | where { |it| ($it.path? | default "" | str trim | is-not-empty) } | is-not-empty
            } catch { false })
            if not $exists {
                $missing = ($missing | append $"Required secret provider CLI '($cli)' for scheme '($kind)' is missing from PATH")
            }
        }
    }
    $missing
}

# Build provider command line arguments for lazy shell execution (RFC-042)
export def secret-provider-argv [kind: string, ref: string]: nothing -> list<string> {
    match $kind {
        "op" => {
            ["op", "read", $ref]
        }
        "bw" => {
            let stripped = if ($ref | str starts-with "bw://") { ($ref | str substring 5..) } else { $ref }
            let parts = ($stripped | split row "/")
            if ($parts | length) >= 2 {
                ["bw", "get", ($parts | get 1), ($parts | get 0)]
            } else {
                ["bw", "get", "password", ($parts | get 0)]
            }
        }
        "pass" => {
            let stripped = if ($ref | str starts-with "pass:") { ($ref | str substring 5..) } else { $ref }
            ["pass", "show", $stripped]
        }
        "eval" => {
            let stripped = if ($ref | str starts-with "eval:") { ($ref | str substring 5..) } else { $ref }
            ["nu", "-c", $stripped]
        }
        _ => {
            []
        }
    }
}

# Format command line for lazy shell evaluation across supported shells (RFC-042)
def format-lazy-provider-cmd [shell: string, argv: list<string>]: nothing -> string {
    if ($argv | is-empty) {
        return ""
    }
    let cmd = ($argv | first)
    if ($argv | length) == 1 {
        return (if $shell == "nu" { $"^($cmd)" } else { $cmd })
    }
    let subcmds = ($argv | skip 1 | drop 1)
    let sub_str = if ($subcmds | is-empty) { "" } else { " " + ($subcmds | str join " ") }
    let target = ($argv | last)

    match $shell {
        "zsh" => {
            let esc_target = ($target | str replace --all "'" "'\\''")
            $"($cmd)($sub_str) '($esc_target)'"
        }
        "fish" => {
            let esc_target = ($target | str replace --all '\' '\\' | str replace --all "'" "\\'")
            $"($cmd)($sub_str) '($esc_target)'"
        }
        "ps1" => {
            let esc_target = ($target | str replace --all "'" "''")
            $"($cmd)($sub_str) '($esc_target)'"
        }
        "nu" => {
            let esc_target = if not ($target | str contains "'") {
                $"'($target)'"
            } else {
                $"\"($target | str replace --all '\\' '\\\\' | str replace --all '\"' '\\\"')\""
            }
            $"^($cmd)($sub_str) ($esc_target) | str trim"
        }
        _ => {
            $"($cmd)($sub_str) '($target)'"
        }
    }
}

# Resolve secret value using external resolvers if URI prefix is present (RFC-034, RFC-041)
# Supported schemas:
#   - `op://<vault>/<item>/<field>` -> 1Password CLI: `^op read ...`
#   - `bw://<item>/<field>` -> Bitwarden CLI: `^bw get ...`
#   - `pass:<path>` -> Pass: `^pass show ...`
#   - `eval:<command>` -> In-memory execution: `nu -c ... | complete`
#   - `literal:<val>` -> Strips literal: prefix, returns remaining string untouched
export def resolve-secret-value [raw: string]: nothing -> string {
    let classified = (classify-secret-value $raw)
    let argv = (secret-provider-argv $classified.kind $classified.ref)
    match $classified.kind {
        "op" => {
            let res = try {
                ^($argv.0) ...($argv | skip 1) | complete
            } catch { |err|
                { exit_code: 1, stdout: "", stderr: ($err | into string) }
            }
            if $res.exit_code != 0 {
                let err_msg = if ($res.stderr | str trim | is-not-empty) {
                    $res.stderr | str trim
                } else {
                    $"command exited with code ($res.exit_code)"
                }
                error make { msg: $"Failed to resolve 1Password secret '($classified.ref)': ($err_msg)" }
            }
            ($res.stdout | str trim -r -c "\r" | str trim -r -c "\n")
        }
        "bw" => {
            let res = try {
                ^($argv.0) ...($argv | skip 1) | complete
            } catch { |err|
                { exit_code: 1, stdout: "", stderr: ($err | into string) }
            }
            if $res.exit_code != 0 {
                let err_msg = if ($res.stderr | str trim | is-not-empty) {
                    $res.stderr | str trim
                } else {
                    $"command exited with code ($res.exit_code)"
                }
                error make { msg: $"Failed to resolve Bitwarden secret '($classified.ref)': ($err_msg)" }
            }
            ($res.stdout | str trim -r -c "\r" | str trim -r -c "\n")
        }
        "pass" => {
            let res = try {
                ^($argv.0) ...($argv | skip 1) | complete
            } catch { |err|
                { exit_code: 1, stdout: "", stderr: ($err | into string) }
            }
            if $res.exit_code != 0 {
                let err_msg = if ($res.stderr | str trim | is-not-empty) {
                    $res.stderr | str trim
                } else {
                    $"command exited with code ($res.exit_code)"
                }
                error make { msg: $"Failed to resolve Pass secret '($classified.ref)': ($err_msg)" }
            }
            ($res.stdout | lines | first | default "")
        }
        "eval" => {
            let res = try {
                ^($argv.0) ...($argv | skip 1) | complete
            } catch { |err|
                { exit_code: 1, stdout: "", stderr: ($err | into string) }
            }
            if $res.exit_code != 0 {
                let err_msg = if ($res.stderr | str trim | is-not-empty) {
                    $res.stderr | str trim
                } else {
                    $"command exited with code ($res.exit_code)"
                }
                error make { msg: $"Failed to resolve eval secret '($classified.ref)': ($err_msg)" }
            }
            ($res.stdout | str trim -r -c "\r" | str trim -r -c "\n")
        }
        _ => {
            $classified.ref
        }
    }
}

# Compile environment variables, secrets, and aliases across active modules and hosts
export def compile-environment [
    ygg_home: string,
    plan: record,
    --dry-run,
    --force,
    --sandbox: string = ""
]: nothing -> nothing {
    let is_dry = if $dry_run { true } else { (($env.YGG_DRY_RUN? | default "false") == "true") }
    let sb = if ($sandbox != "") { $sandbox } else { ($env.YGG_SANDBOX? | default "") }

    # 0. Audit secrets against module templates (read-only, names only; also runs in dry-run)
    let audit_secrets = ($ygg_home | path join "secrets.toml")
    for mod_entry in ($plan.modules? | default []) {
        let tmpl = ($mod_entry.dir | path join "secrets.example.toml")
        if ($tmpl | path exists) {
            let missing = (missing-secret-keys $tmpl $audit_secrets)
            if not ($missing | is-empty) {
                print -e $"[ygg] Warning: module '($mod_entry.name)' is missing secrets: ($missing | str join ', ')"
            }
        }
    }

    if $is_dry {
        return
    }

    # 1. Load secrets from $ygg_home/secrets.toml (RFC-041)
    let sec_env = (load-secrets-env $ygg_home)

    # Read materialize flag (RFC-042)
    let host_cfg = (try { load-host-config $ygg_home } catch { {} })
    let materialize = ($host_cfg | get -o ygg.secrets.materialize | default false)

    # 2. Build environment items { key, kind, value_or_argv }
    let plan_env = ($plan.env? | default {})
    let merged_aliases = ($plan.aliases? | default {})

    mut env_map = {}
    for row in ($plan_env | transpose k v) {
        if not (($row.v | describe) starts-with "record") and not (($row.v | describe) starts-with "table") {
            let lit_val = ($row.v | into string)
            $env_map = ($env_map | upsert $row.k {
                key: $row.k,
                kind: "literal",
                value_or_argv: (resolve-env-value $lit_val $sb)
            })
        }
    }

    for row in ($sec_env | transpose k v) {
        if not (($row.v | describe) starts-with "record") and not (($row.v | describe) starts-with "table") {
            let raw_str = ($row.v | into string)
            let classified = (classify-secret-value $raw_str)
            if $materialize {
                let resolved = (resolve-secret-value $raw_str)
                $env_map = ($env_map | upsert $row.k {
                    key: $row.k,
                    kind: "literal",
                    value_or_argv: (resolve-env-value $resolved $sb)
                })
            } else if $classified.kind == "literal" {
                $env_map = ($env_map | upsert $row.k {
                    key: $row.k,
                    kind: "literal",
                    value_or_argv: (resolve-env-value $classified.ref $sb)
                })
            } else {
                let argv = (secret-provider-argv $classified.kind $classified.ref)
                $env_map = ($env_map | upsert $row.k {
                    key: $row.k,
                    kind: $classified.kind,
                    value_or_argv: $argv
                })
            }
        }
    }

    let items = ($env_map | values)

    # 3. Ensure target directory exists
    let env_dir = ($ygg_home | path join ".state" "env")
    if not ($env_dir | path exists) {
        mkdir $env_dir
    }

    # 4. Generate env.nu
    let env_nu_path = ($env_dir | path join "env.nu")
    mut nu_lines = []
    let nu_literals = ($items | where kind == "literal" | reduce -f {} { |it, acc| $acc | upsert $it.key $it.value_or_argv })
    $nu_lines = ($nu_lines | append $"load-env \(($nu_literals | to nuon))")
    for it in ($items | where kind != "literal") {
        let cmd = (format-lazy-provider-cmd "nu" $it.value_or_argv)
        $nu_lines = ($nu_lines | append $"$env.($it.key) = \(($cmd))")
    }
    let env_nu_content = ($nu_lines | str join "\n") + "\n"
    $env_nu_content | save -f $env_nu_path

    # 5. Generate env.zsh
    let env_zsh_path = ($env_dir | path join "env.zsh")
    mut zsh_lines = []
    for it in $items {
        if $it.kind == "literal" {
            let esc = ($it.value_or_argv | str replace --all "'" "'\\''")
            $zsh_lines = ($zsh_lines | append $"export ($it.key)='($esc)'")
        } else {
            let cmd = (format-lazy-provider-cmd "zsh" $it.value_or_argv)
            $zsh_lines = ($zsh_lines | append $"export ($it.key)=\"$\(($cmd))\"")
        }
    }
    let env_zsh_content = if ($zsh_lines | is-empty) { "" } else { ($zsh_lines | str join "\n") + "\n" }
    $env_zsh_content | save -f $env_zsh_path

    # 6. Generate env.ps1
    let env_ps1_path = ($env_dir | path join "env.ps1")
    mut ps1_lines = []
    for it in $items {
        if $it.kind == "literal" {
            let esc = ($it.value_or_argv | str replace --all "'" "''")
            $ps1_lines = ($ps1_lines | append $"$env:($it.key) = '($esc)'")
        } else {
            let cmd = (format-lazy-provider-cmd "ps1" $it.value_or_argv)
            $ps1_lines = ($ps1_lines | append $"$env:($it.key) = \(& ($cmd))")
        }
    }
    let env_ps1_content = if ($ps1_lines | is-empty) { "" } else { ($ps1_lines | str join "\n") + "\n" }
    $env_ps1_content | save -f $env_ps1_path

    # 6b. Generate env.fish
    let env_fish_path = ($env_dir | path join "env.fish")
    mut fish_lines = []
    for it in $items {
        if $it.kind == "literal" {
            let esc = ($it.value_or_argv | str replace --all '\' '\\' | str replace --all "'" "\\'")
            $fish_lines = ($fish_lines | append $"set -gx ($it.key) '($esc)'")
        } else {
            let cmd = (format-lazy-provider-cmd "fish" $it.value_or_argv)
            $fish_lines = ($fish_lines | append $"set -gx ($it.key) \(($cmd))")
        }
    }
    let env_fish_content = if ($fish_lines | is-empty) { "" } else { ($fish_lines | str join "\n") + "\n" }
    $env_fish_content | save -f $env_fish_path

    # 7. Generate aliases.nu
    let aliases_nu_path = ($env_dir | path join "aliases.nu")
    mut nu_alias_lines = []
    for k in ($merged_aliases | columns) {
        let v = ($merged_aliases | get $k | into string)
        $nu_alias_lines = ($nu_alias_lines | append $"alias ($k) = ($v)")
    }
    let aliases_nu_content = if ($nu_alias_lines | is-empty) { "" } else { ($nu_alias_lines | str join "\n") + "\n" }
    $aliases_nu_content | save -f $aliases_nu_path

    # 8. Generate aliases.zsh
    let aliases_zsh_path = ($env_dir | path join "aliases.zsh")
    mut zsh_alias_lines = []
    for k in ($merged_aliases | columns) {
        let v = ($merged_aliases | get $k | into string)
        let esc = ($v | str replace --all "'" "'\\''")
        $zsh_alias_lines = ($zsh_alias_lines | append $"alias ($k)='($esc)'")
    }
    let aliases_zsh_content = if ($zsh_alias_lines | is-empty) { "" } else { ($zsh_alias_lines | str join "\n") + "\n" }
    $aliases_zsh_content | save -f $aliases_zsh_path

    # 8b. Generate aliases.fish
    let aliases_fish_path = ($env_dir | path join "aliases.fish")
    mut fish_alias_lines = []
    for k in ($merged_aliases | columns) {
        let v = ($merged_aliases | get $k | into string)
        let esc = ($v | str replace --all '\' '\\' | str replace --all "'" "\\'")
        $fish_alias_lines = ($fish_alias_lines | append $"alias ($k) '($esc)'")
    }
    let aliases_fish_content = if ($fish_alias_lines | is-empty) { "" } else { ($fish_alias_lines | str join "\n") + "\n" }
    $aliases_fish_content | save -f $aliases_fish_path

    # 9. Generate aliases.ps1 (function wrapper with recursion guard)
    let aliases_ps1_path = ($env_dir | path join "aliases.ps1")
    mut ps1_alias_lines = []
    for k in ($merged_aliases | columns) {
        let cmd = ($merged_aliases | get $k | into string)
        let parts = ($cmd | split row -r '\s+' | where { |it| $it != "" })
        let first_word = ($parts | first | default "")
        if ($first_word == $k) {
            let rest = ($cmd | str substring (($first_word | str length)..) | str trim)
            let rest_part = if ($rest == "") { "" } else { " " + $rest }
            let ps_line = ("function " + $k + " { &(Get-Command -CommandType Application -Name '" + $k + "')" + $rest_part + " @args }")
            $ps1_alias_lines = ($ps1_alias_lines | append $ps_line)
        } else {
            let ps_line = ("function " + $k + " { " + $cmd + " @args }")
            $ps1_alias_lines = ($ps1_alias_lines | append $ps_line)
        }
    }
    let aliases_ps1_content = if ($ps1_alias_lines | is-empty) { "" } else { ($ps1_alias_lines | str join "\n") + "\n" }
    $aliases_ps1_content | save -f $aliases_ps1_path

    # 10. Ensure local.nu exists (never overwrite existing)
    let local_nu_path = ($env_dir | path join "local.nu")
    if not ($local_nu_path | path exists) {
        "" | save -f $local_nu_path
    }

    # 11. Restrict permissions (0600 on Unix, inheritance reset & owner:F on Windows) (RFC-049)
    let env_files = [
        $env_nu_path,
        $env_zsh_path,
        $env_ps1_path,
        $env_fish_path,
        $aliases_nu_path,
        $aliases_zsh_path,
        $aliases_ps1_path,
        $aliases_fish_path,
        $local_nu_path
    ]
    for f in $env_files {
        restrict-file-access $f | ignore
    }

    # 12. Linux systemd environment.d/99-ygg.conf (static receivers filter kind != "literal", RFC-042)
    let skipped_external = ($items | where kind != "literal")
    for it in $skipped_external {
        print -e $"[ygg] Warning: external secret '($it.key)' skipped for static environment receivers"
    }

    let static_env = ($items | where kind == "literal" | reduce -f {} { |it, acc| $acc | upsert $it.key $it.value_or_argv })

    let host_os = (detect-host-os)
    if ($host_os.os == "linux") or ($nu.os-info.family != "windows") or ($sb != "") {
        let conf_path = (expand-target-path "~/.config/environment.d/99-ygg.conf" --sandbox $sb)
        let conf_dir = ($conf_path | path dirname)
        if not ($conf_dir | path exists) {
            mkdir $conf_dir
        }
        mut conf_lines = []
        for k in ($static_env | columns) {
            let raw_val = ($static_env | get $k)
            let esc_val = ($raw_val
                | str replace --all '\' '\\'
                | str replace --all '"' '\"'
                | str replace --all '$' '\$'
                | str replace --all "\n" '\n')
            $conf_lines = ($conf_lines | append $"($k)=\"($esc_val)\"")
        }
        let conf_content = if ($conf_lines | is-empty) { "" } else { ($conf_lines | str join "\n") + "\n" }
        $conf_content | save -f $conf_path
        restrict-file-access $conf_path | ignore
    }

    # 13. System session updates (strictly skipped under sandbox)
    if ($sb == "") {
        if ($host_os.os == "linux") {
            with-env $static_env {
                try {
                    let env_keys = ($static_env | columns)
                    if not ($env_keys | is-empty) {
                        ^systemctl --user import-environment ...$env_keys | complete | ignore
                    }
                } catch { }
            }
        } else if ($host_os.os == "windows") and ($nu.os-info.family == "windows") {
            let path_entries = ($plan.path? | default [])
            let user_home = ($env.USERPROFILE? | default ($env.HOME? | default ("~" | path expand)))
            let script = (format-windows-env-script $static_env $path_entries $user_home)
            let res = (^powershell -NoProfile -Command $script | complete)
            if $res.exit_code != 0 {
                error make { msg: $"Failed to update Windows environment: ($res.stderr)" }
            }
        }
    }
}
