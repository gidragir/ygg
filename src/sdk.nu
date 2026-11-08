# src/sdk.nu
# Yggdrasil configuration manager — Reactive SDK & setup.nu runner

use state.nu [get-ygg-home, load-state, save-state, expand-target-path]
use link.nu [is-link-or-junction, remove-link-only]

const YGG_SRC_DIR = (path self | path dirname)

# Check if a path string is absolute or home-relative
def is-path-absolute [p: string]: nothing -> bool {
    ($p | str starts-with "/") or ($p | str starts-with "\\") or ($p | str starts-with "~") or ($p =~ '^[A-Za-z]:')
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

    # 1. Collect all files matching watch_globs
    mut files: list<string> = []
    for pattern in $watch_globs {
        let resolved_pattern = if (is-path-absolute $pattern) {
            $pattern
        } else {
            ($mod_dir | path join $pattern)
        }

        if (($resolved_pattern | path exists) or (($resolved_pattern | path type) != null)) and not ($resolved_pattern | str contains "*") and not ($resolved_pattern | str contains "?") {
            let ptype = ($resolved_pattern | path type)
            if ($ptype == "dir") {
                let dir_files = (try { glob ($resolved_pattern | path join "**" "*") } catch { [] })
                for df in $dir_files {
                    if (($df | path type) == "file") {
                        $files = ($files | append ($df | path expand))
                    }
                }
            } else if ($ptype == "file") {
                $files = ($files | append ($resolved_pattern | path expand))
            }
        } else {
            let matched = (try { glob $resolved_pattern } catch { [] })
            for m in $matched {
                let ptype = ($m | path type)
                if ($ptype == "dir") {
                    let dir_files = (try { glob ($m | path join "**" "*") } catch { [] })
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

    # 2. Compute aggregate SHA-256 hash
    mut hash_entries = []
    for f in $unique_files {
        let rel = (try { $f | path relative-to $mod_dir } catch { $f })
        let content_hash = (try { open --raw $f | hash sha256 } catch { "" })
        $hash_entries = ($hash_entries | append $"($rel):($content_hash)")
    }
    let current_hash = ($hash_entries | str join "\n" | hash sha256)

    # 3. Check current state and target
    let state = (load-state $ygg_home)
    let prev_hash = ($state.hashes? | default {} | get -o $key | default "")

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

    # 4. Execute block
    do $block

    # 5. On success: update hash in state.json
    let st = (load-state $ygg_home)
    let updated_hashes = ($st.hashes? | default {} | upsert $key $current_hash)
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
    if not ($dest_dir | path exists) {
        mkdir $dest_dir
    }

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
        return
    }

    let sec_data = (try { open $sec_file } catch { {} })
    let sec_env = if "env" in $sec_data {
        $sec_data.env
    } else {
        $sec_data
    }

    if (not (($sec_env | describe) starts-with "record")) or ($sec_env | is-empty) {
        return
    }

    let available_keys = ($sec_env | columns)
    let target_keys = if ($keys | is-empty) {
        $available_keys
    } else {
        $keys | where { |k| $k in $available_keys }
    }

    mut lines: list<string> = []
    for k in $target_keys {
        let raw_val = ($sec_env | get $k | into string)
        let escaped_val = ($raw_val
            | str replace --all '\' '\\'
            | str replace --all "'" "\\'")
        $lines = ($lines | append $"($k)='($escaped_val)'")
    }

    let dest = (expand-target-path $dest_dotenv)
    let dest_dir = ($dest | path dirname)
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

    let ygg_src_dir = $YGG_SRC_DIR
    let is_dry = if $dry_run { "true" } else { ($env.YGG_DRY_RUN? | default "false") }
    let is_forced = if $force { "true" } else { ($env.YGG_FORCE? | default "false") }
    let sb = if ($sandbox != "") { $sandbox } else { ($env.YGG_SANDBOX? | default "") }

    let scopes_json = (($mod_plan.scopes? | default []) | to json -r)
    let config_json = (($mod_plan.config? | default {}) | to json -r)

    let env_vars = {
        YGG_HOME: $ygg_home,
        YGG_MODULE_DIR: $mod_dir,
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
