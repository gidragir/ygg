# src/git.nu
# Yggdrasil configuration manager — Module Git Manager & local directory linker

use manifest.nu [load-host-config, save-host-config, load-module-manifest, validate-module-os]
use link.nu [unlink-module, is-link-or-junction, remove-link-only]
use state.nu [detect-host-os, load-state, ensure-ygg-dirs]

# Add a module from a local path or Git repository URL / shorthand (owner/repo)
export def add-module [
    ygg_home: string,
    source: string,
    --scopes: list<string> = []
]: nothing -> record {
    ensure-ygg-dirs $ygg_home

    # A local module directory must exist on disk, contain ygg.toml, and not be a bare/git repository
    let is_local_dir = (
        ($source | path exists) and
        ($source | path join "ygg.toml" | path exists) and
        not ($source | str ends-with ".git")
    )

    if $is_local_dir {
        let manifest = (load-module-manifest $source)
        let host_os = (detect-host-os)
        if not (validate-module-os $manifest $host_os) {
            error make { msg: $"Module '($manifest.name)' does not support host OS '($host_os.os)' \(required: ($manifest.os | to json -r)\)" }
        }

        let mod_dest = ($ygg_home | path join "modules" $manifest.name)
        if (is-link-or-junction $mod_dest) {
            remove-link-only $mod_dest
        } else if ($mod_dest | path exists) {
            rm -rf $mod_dest
        }

        let exp_src = ($source | path expand)
        if ($nu.os-info.family == "windows") {
            ^cmd /c $"mklink /J \"($mod_dest)\" \"($exp_src)\"" | complete | ignore
        } else {
            ^ln -sfn $exp_src $mod_dest
        }

        let host_cfg = (load-host-config $ygg_home)
        let cur_mods = ($host_cfg.modules? | default [])
        mut updated_mods = ($cur_mods | where { |m| $m.name != $manifest.name })
        mut mod_record = { name: $manifest.name }
        if ($scopes | is-not-empty) {
            $mod_record = ($mod_record | upsert scopes $scopes)
        }
        $updated_mods = ($updated_mods | append $mod_record)
        save-host-config $ygg_home ($host_cfg | upsert modules $updated_mods)

        return { name: $manifest.name, path: $mod_dest, scopes: $scopes }
    } else {
        # Remote Git repository or local bare git repository
        let git_url = if not ($source | path exists) and not ($source | str contains "://") and not ($source | str starts-with "git@") and not ($source | str starts-with "ssh://") {
            $"https://github.com/($source).git"
        } else {
            $source
        }

        let tmp_parent = ($ygg_home | path join ".state" "tmp")
        mkdir $tmp_parent
        let rand_id = (random chars --length 8)
        let tmp_clone = ($tmp_parent | path join $"clone-($rand_id)")

        let clone_res = (^git clone $git_url $tmp_clone | complete)
        if $clone_res.exit_code != 0 {
            try { rm -rf $tmp_clone }
            error make { msg: $"Failed to clone '($source)': ($clone_res.stderr)" }
        }

        if not ($tmp_clone | path join "ygg.toml" | path exists) {
            rm -rf $tmp_clone
            error make { msg: $"Cloned repository '($source)' does not contain 'ygg.toml'" }
        }

        let manifest = (try {
            load-module-manifest $tmp_clone
        } catch { |e|
            rm -rf $tmp_clone
            error make { msg: $e.msg }
        })

        let host_os = (detect-host-os)
        if not (validate-module-os $manifest $host_os) {
            rm -rf $tmp_clone
            error make { msg: $"Module '($manifest.name)' does not support host OS '($host_os.os)' \(required: ($manifest.os | to json -r)\)" }
        }

        let mod_dest = ($ygg_home | path join "modules" $manifest.name)
        if (is-link-or-junction $mod_dest) {
            remove-link-only $mod_dest
        } else if ($mod_dest | path exists) {
            rm -rf $mod_dest
        }

        mv $tmp_clone $mod_dest

        let host_cfg = (load-host-config $ygg_home)
        let cur_mods = ($host_cfg.modules? | default [])
        mut updated_mods = ($cur_mods | where { |m| $m.name != $manifest.name })
        mut mod_record = { name: $manifest.name }
        if ($scopes | is-not-empty) {
            $mod_record = ($mod_record | upsert scopes $scopes)
        }
        $updated_mods = ($updated_mods | append $mod_record)
        save-host-config $ygg_home ($host_cfg | upsert modules $updated_mods)

        return { name: $manifest.name, path: $mod_dest, scopes: $scopes }
    }
}

# Remove a module, safely unlinking files and guarding against uncommitted changes
export def remove-module [ygg_home: string, name: string]: nothing -> nothing {
    let mod_dir = ($ygg_home | path join "modules" $name)

    # If it is a real Git directory (not a symlink), guard against uncommitted changes
    if ($mod_dir | path exists) and not (is-link-or-junction $mod_dir) {
        if ($mod_dir | path join ".git" | path exists) {
            let st = (^git -C $mod_dir status --porcelain | complete)
            if ($st.exit_code == 0) and ($st.stdout | str trim | is-not-empty) {
                error make { msg: $"Cannot remove module '($name)': directory has uncommitted changes in '($mod_dir)'" }
            }
        }
    }

    # Safe unlinking of deployed links and copies
    unlink-module $ygg_home $name | ignore

    # Remove entry from host.toml
    let host_cfg = (load-host-config $ygg_home)
    let cur_mods = ($host_cfg.modules? | default [])
    let updated_mods = ($cur_mods | where { |m| $m.name != $name })
    save-host-config $ygg_home ($host_cfg | upsert modules $updated_mods)

    # Delete symlink or folder
    if (is-link-or-junction $mod_dir) {
        remove-link-only $mod_dir
    } else if ($mod_dir | path exists) {
        rm -rf $mod_dir
    }
}

# Update all Git-managed modules in $YGG_HOME/modules/ via rebase, aborting cleanly on conflict
export def update-modules [ygg_home: string]: nothing -> list<record> {
    let mods_dir = ($ygg_home | path join "modules")
    if not ($mods_dir | path exists) {
        return []
    }

    let entries = (try { ls $mods_dir } catch { [] })
    let mod_dirs = ($entries | where type in ["dir", "symlink"])
    mut results = []

    for entry in $mod_dirs {
        let mod_path = $entry.name
        let mod_name = ($mod_path | path basename)

        let git_dir = ($mod_path | path join ".git")
        if not ($git_dir | path exists) {
            continue
        }

        let remotes = (^git -C $mod_path remote | complete).stdout | str trim
        if ($remotes == "") {
            $results = ($results | append { name: $mod_name, status: "skipped", message: "no remotes configured" })
            continue
        }

        let head_before = (^git -C $mod_path rev-parse HEAD | complete).stdout | str trim
        let status_raw = (^git -C $mod_path status --porcelain | complete).stdout | str trim
        let is_dirty = ($status_raw != "")

        mut stashed = false
        if $is_dirty {
            let stash_res = (^git -C $mod_path stash push -u -m "ygg-update-stash" | complete)
            if $stash_res.exit_code == 0 {
                $stashed = true
            }
        }

        let pull_res = (^git -C $mod_path pull --rebase | complete)
        if $pull_res.exit_code != 0 {
            # Pull / rebase conflict
            ^git -C $mod_path rebase --abort | complete | ignore
            ^git -C $mod_path reset --hard $head_before | complete | ignore
            if $stashed {
                ^git -C $mod_path stash pop | complete | ignore
            }
            $results = ($results | append { name: $mod_name, status: "conflict", message: $pull_res.stderr })
            continue
        }

        if $stashed {
            let pop_res = (^git -C $mod_path stash pop | complete)
            if ($pop_res.exit_code != 0) or ($pop_res.stdout | str contains "CONFLICT") {
                # Stash pop conflicted with updated remote commits
                # Reset working directory to head_before (no conflict markers in working tree)
                ^git -C $mod_path reset --hard $head_before | complete | ignore
                # Pop the stash cleanly onto original HEAD
                ^git -C $mod_path stash pop | complete | ignore
                $results = ($results | append { name: $mod_name, status: "conflict", message: "Stash pop conflicted with upstream changes" })
                continue
            }
        }

        let head_after = (^git -C $mod_path rev-parse HEAD | complete).stdout | str trim
        $results = ($results | append {
            name: $mod_name,
            status: "ok",
            updated: ($head_before != $head_after),
            head: $head_after
        })
    }

    $results
}

# Return module status summary table
export def modules-status [ygg_home: string]: nothing -> table {
    let host_cfg = (load-host-config $ygg_home)
    let state = (load-state $ygg_home)

    mut rows = []

    for mod in ($host_cfg.modules? | default []) {
        let name = $mod.name
        let scopes = ($mod.scopes? | default [])
        let mod_path = if ($mod.path? != null) and ($mod.path != "") {
            $mod.path
        } else {
            ($ygg_home | path join "modules" $name)
        }

        let is_git = ($mod_path | path join ".git" | path exists)
        let branch = if $is_git {
            let br = (^git -C $mod_path branch --show-current | complete).stdout | str trim
            if ($br != "") {
                $br
            } else {
                (^git -C $mod_path rev-parse --short HEAD | complete).stdout | str trim
            }
        } else {
            ""
        }

        let dirty = if $is_git {
            ((^git -C $mod_path status --porcelain | complete).stdout | str trim) != ""
        } else {
            false
        }

        let mod_links = ($state.links | columns | where { |k| (($state.links | get $k | get -o module) == $name) })
        let links_ok = if ($mod_links | is-empty) {
            true
        } else {
            $mod_links | all { |dest| (is-link-or-junction $dest) or ($dest | path exists) }
        }

        $rows = ($rows | append {
            name: $name,
            scopes: $scopes,
            path: $mod_path,
            branch: $branch,
            dirty: $dirty,
            links_ok: $links_ok
        })
    }

    $rows
}
