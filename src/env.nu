# src/env.nu
# Yggdrasil configuration manager — Environment, Aliases & Secrets Compiler

use state.nu [detect-host-os, expand-target-path]

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

    if $is_dry {
        return
    }

    # 1. Load secrets from $ygg_home/secrets.toml
    let sec_file = ($ygg_home | path join "secrets.toml")
    let sec_env = if ($sec_file | path exists) {
        let sec_data = (try { open $sec_file } catch { {} })
        let extracted = (if "env" in $sec_data { $sec_data.env } else { $sec_data })
        if (($extracted | describe) starts-with "record") {
            $extracted
        } else {
            {}
        }
    } else {
        {}
    }

    # 2. Merge plan environment with secrets (secrets take precedence)
    let plan_env = ($plan.env? | default {})
    let merged_env = ($plan_env | merge $sec_env)
    let merged_aliases = ($plan.aliases? | default {})

    # Normalize environment values to strings
    let clean_env = ($merged_env | transpose k v | reduce -f {} { |it, acc|
        $acc | upsert $it.k ($it.v | into string)
    })

    # 3. Ensure target directory exists
    let env_dir = ($ygg_home | path join ".state" "env")
    if not ($env_dir | path exists) {
        mkdir $env_dir
    }

    # 4. Generate env.nu
    let env_nu_path = ($env_dir | path join "env.nu")
    let env_nu_content = $"load-env \(($clean_env | to nuon))\n"
    $env_nu_content | save -f $env_nu_path

    # 5. Generate env.zsh
    let env_zsh_path = ($env_dir | path join "env.zsh")
    mut zsh_lines = []
    for k in ($clean_env | columns) {
        let v = ($clean_env | get $k)
        let esc = ($v | str replace --all "'" "'\\''")
        $zsh_lines = ($zsh_lines | append $"export ($k)='($esc)'")
    }
    let env_zsh_content = if ($zsh_lines | is-empty) { "" } else { ($zsh_lines | str join "\n") + "\n" }
    $env_zsh_content | save -f $env_zsh_path

    # 6. Generate env.ps1
    let env_ps1_path = ($env_dir | path join "env.ps1")
    mut ps1_lines = []
    for k in ($clean_env | columns) {
        let v = ($clean_env | get $k)
        let esc = ($v | str replace --all "'" "''")
        $ps1_lines = ($ps1_lines | append $"$env:($k) = '($esc)'")
    }
    let env_ps1_content = if ($ps1_lines | is-empty) { "" } else { ($ps1_lines | str join "\n") + "\n" }
    $env_ps1_content | save -f $env_ps1_path

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

    # 11. Restrict permissions to 0600 on Unix
    if ($nu.os-info.family != "windows") {
        let env_files = [
            $env_nu_path,
            $env_zsh_path,
            $env_ps1_path,
            $aliases_nu_path,
            $aliases_zsh_path,
            $aliases_ps1_path,
            $local_nu_path
        ]
        for f in $env_files {
            try { ^chmod 0600 $f | complete | ignore } catch { }
        }
    }

    # 12. Linux systemd environment.d/99-ygg.conf
    let host_os = (detect-host-os)
    if ($host_os.os == "linux") or ($nu.os-info.family != "windows") or ($sb != "") {
        let conf_path = (expand-target-path "~/.config/environment.d/99-ygg.conf" --sandbox $sb)
        let conf_dir = ($conf_path | path dirname)
        if not ($conf_dir | path exists) {
            mkdir $conf_dir
        }
        mut conf_lines = []
        for k in ($clean_env | columns) {
            let raw_val = ($clean_env | get $k)
            let esc_val = ($raw_val
                | str replace --all '\' '\\'
                | str replace --all '"' '\"'
                | str replace --all '$' '\$'
                | str replace --all "\n" '\n')
            $conf_lines = ($conf_lines | append $"($k)=\"($esc_val)\"")
        }
        let conf_content = if ($conf_lines | is-empty) { "" } else { ($conf_lines | str join "\n") + "\n" }
        $conf_content | save -f $conf_path
        if ($nu.os-info.family != "windows") {
            try { ^chmod 0600 $conf_path | complete | ignore } catch { }
        }
    }

    # 13. System session updates (strictly skipped under sandbox)
    if ($sb == "") {
        if ($host_os.os == "linux") {
            with-env $clean_env {
                try {
                    let env_keys = ($clean_env | columns)
                    if not ($env_keys | is-empty) {
                        ^systemctl --user import-environment ...$env_keys | complete | ignore
                    }
                } catch { }
            }
        } else if ($host_os.os == "windows") {
            for k in ($clean_env | columns) {
                let v = ($clean_env | get $k)
                let ps_cmd = $"[Environment]::SetEnvironmentVariable\('($k)', '($v | str replace --all "'" "''")', 'User'\)"
                try { ^powershell -NoProfile -Command $ps_cmd | complete | ignore } catch { }
            }
        }
    }
}
