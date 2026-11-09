# src/git.nu
# Yggdrasil configuration manager — Module Git Manager & local directory linker

use manifest.nu [load-host-config, save-host-config, load-module-manifest, validate-module-os]
use link.nu [unlink-module, is-link-or-junction, remove-link-only, backup-with-notice, link-target-matches]
use state.nu [detect-host-os, load-state, ensure-ygg-dirs, to-win32-path]

# Raise when a real (non-link) Git module directory has uncommitted changes.
# Shared guard of `add` (replacing the module) and `remove`.
def assert-module-clean [mod_dir: string, name: string, action: string]: nothing -> nothing {
    if not ($mod_dir | path exists) or (is-link-or-junction $mod_dir) {
        return
    }
    if not ($mod_dir | path join ".git" | path exists) {
        return
    }
    let st = (^git -C $mod_dir status --porcelain | complete)
    if ($st.exit_code == 0) and ($st.stdout | str trim | is-not-empty) {
        error make { msg: $"Cannot ($action) module '($name)': directory has uncommitted changes in '($mod_dir)'" }
    }
}

# True when a path canonicalizes (`path expand --strict`); YGG_MOCK_NO_CANONICALIZE=1 simulates
# a volume without canonicalization support, e.g. VirtIO-FS (RFC-025)
export def is-canonicalizable [path: string]: nothing -> bool {
    if (($env.YGG_MOCK_NO_CANONICALIZE? | default "") == "1") {
        return false
    }
    try { $path | path expand --strict | ignore; true } catch { false }
}

# Warn when a reachable module source cannot be canonicalized (RFC-025)
export def warn-if-not-canonicalizable [path: string]: nothing -> nothing {
    if (not (is-canonicalizable $path)) and ($path | path exists) {
        print -e $"[ygg] Warning: '($path)' is on a volume without path canonicalization support. Tools such as mise may ignore configs reached through it. Copy the module to a local NTFS disk and add it from there."
    }
}

# Remove the temporary clone of a staged module (no-op for local modules)
export def discard-staged-module [prep: record]: nothing -> nothing {
    let tmp = ($prep.tmp_clone? | default "")
    let safe_subpath = ([".state", "tmp"] | path join)
    let has_safe_prefix = ($tmp | str contains $safe_subpath)
    if ($tmp != "") and ($tmp | path exists) and $has_safe_prefix {
        rm -rf $tmp
    }
}

# Stage a module without touching modules/ or host.toml (RFC-012).
# Local directory: path = the expanded source; Git source: cloned into .state/tmp/clone-*.
def stage-module [ygg_home: string, source: string, scopes: list<string>, force: bool]: nothing -> record {
    # A local module directory must exist on disk, contain ygg.toml, and not be a bare/git repository
    let is_local_dir = (
        ($source | path exists) and
        ($source | path join "ygg.toml" | path exists) and
        not ($source | str ends-with ".git")
    )

    let staged = if $is_local_dir {
        { path: ($source | path expand), tmp_clone: "" }
    } else {
        # Remote Git repository or local bare git repository
        let git_url = if not ($source | path exists) and not ($source | str contains "://") and not ($source | str starts-with "git@") and not ($source | str starts-with "ssh://") {
            $"https://github.com/($source).git"
        } else {
            $source
        }

        let tmp_parent = ($ygg_home | path join ".state" "tmp")
        mkdir $tmp_parent
        let tmp_clone = ($tmp_parent | path join $"clone-(random chars --length 8)")

        let clone_res = (^git clone $git_url $tmp_clone | complete)
        if $clone_res.exit_code != 0 {
            discard-staged-module { tmp_clone: $tmp_clone }
            error make { msg: $"Failed to clone '($source)': ($clone_res.stderr)" }
        }
        { path: $tmp_clone, tmp_clone: $tmp_clone }
    }

    try {
        if not ($staged.path | path join "ygg.toml" | path exists) {
            error make { msg: $"Cloned repository '($source)' does not contain 'ygg.toml'" }
        }
        let manifest = (load-module-manifest $staged.path)
        let host_os = (detect-host-os)
        if not (validate-module-os $manifest $host_os) {
            error make { msg: $"Module '($manifest.name)' does not support host OS '($host_os.os)' \(required: ($manifest.os | to json -r)\)" }
        }
        let mod_dest = ($ygg_home | path join "modules" $manifest.name)
        let in_place = ($mod_dest | path exists) and (($mod_dest | path expand) == $staged.path)
        if (not $force) and (not $in_place) {
            assert-module-clean $mod_dest $manifest.name "replace"
        }
        { name: $manifest.name, path: $staged.path, scopes: $scopes, tmp_clone: $staged.tmp_clone }
    } catch { |e|
        discard-staged-module $staged
        error make { msg: $e.msg }
    }
}

# Finish `add` for a staged module: put it into modules/<name> and register it in host.toml.
# A real module directory is moved to .state/backups/ (refused when dirty unless --force).
export def register-staged-module [ygg_home: string, prep: record, --force]: nothing -> record {
    ensure-ygg-dirs $ygg_home
    let mod_dest = ($ygg_home | path join "modules" $prep.name)
    let is_local = (($prep.tmp_clone? | default "") == "")

    try {
        # Re-adding a module from its own modules/<name> path keeps the directory as is
        let in_place = $is_local and (not (is-link-or-junction $mod_dest)) and ($mod_dest | path exists) and (($mod_dest | path expand) == $prep.path)
        if not $in_place {
            if (is-link-or-junction $mod_dest) {
                remove-link-only $mod_dest
            } else if (($mod_dest | path type) != null) {
                if not $force {
                    assert-module-clean $mod_dest $prep.name "replace"
                }
                backup-with-notice $ygg_home $mod_dest | ignore
            }

            if $is_local {
                if ($nu.os-info.family == "windows") {
                    # RFC-025: a failed junction must not register the module
                    let res = (^cmd /c mklink /J (to-win32-path $mod_dest) (to-win32-path $prep.path) | complete)
                    if $res.exit_code != 0 {
                        error make { msg: $"Failed to link module '($prep.name)' to '($prep.path)': ($res.stdout | str trim) ($res.stderr | str trim)" }
                    }
                } else {
                    ^ln -s $prep.path $mod_dest
                }
            } else {
                mv $prep.tmp_clone $mod_dest
            }
        }
    } catch { |e|
        discard-staged-module $prep
        error make { msg: $e.msg }
    }

    let host_cfg = (load-host-config $ygg_home)
    let cur_mods = ($host_cfg.modules? | default [])
    mut mod_record = { name: $prep.name }
    if ($prep.scopes | is-not-empty) {
        $mod_record = ($mod_record | upsert scopes $prep.scopes)
    }
    let updated_mods = ($cur_mods | where { |m| $m.name != $prep.name } | append $mod_record)
    save-host-config $ygg_home ($host_cfg | upsert modules $updated_mods)

    { name: $prep.name, path: $mod_dest, scopes: $prep.scopes, tmp_clone: "" }
}

# Add a module from a local path or Git repository URL / shorthand (owner/repo).
# --dry-run only stages it ({ name, path, scopes, tmp_clone }); the caller must call
# discard-staged-module afterwards. --force replaces a module directory with uncommitted changes.
export def add-module [
    ygg_home: string,
    source: string,
    --scopes: list<string> = [],
    --dry-run,
    --force
]: nothing -> record<name: string, path: string, scopes: list<string>, tmp_clone: string> {
    ensure-ygg-dirs $ygg_home
    let prep = (stage-module $ygg_home $source $scopes $force)
    if ($prep.tmp_clone == "") {
        warn-if-not-canonicalizable $prep.path
    }
    if $dry_run {
        return $prep
    }
    register-staged-module $ygg_home $prep --force=$force
}

# Remove a module, safely unlinking files and guarding against uncommitted changes
export def remove-module [ygg_home: string, name: string]: nothing -> nothing {
    let mod_dir = ($ygg_home | path join "modules" $name)

    # If it is a real Git directory (not a symlink), guard against uncommitted changes
    assert-module-clean $mod_dir $name "remove"

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

# Update a single Git-managed module via rebase, respecting pin = true in host.toml
export def update-module [ygg_home: string, name: string]: nothing -> record {
    let mod_path = ($ygg_home | path join "modules" $name)
    if not ($mod_path | path exists) {
        return { name: $name, status: "skipped", message: "module directory not found" }
    }

    let host_cfg = (try { load-host-config $ygg_home } catch { {} })
    let host_mods = ($host_cfg.modules? | default [])
    let mod_cfg = ($host_mods | where name == $name | get -o 0)
    if (($mod_cfg.pin? | default false) == true) {
        return { name: $name, status: "skipped", message: "module pinned" }
    }

    let git_dir = ($mod_path | path join ".git")
    if not ($git_dir | path exists) {
        return { name: $name, status: "skipped", message: "not a git repository" }
    }

    let remotes = (^git -C $mod_path remote | complete).stdout | str trim
    if ($remotes == "") {
        return { name: $name, status: "skipped", message: "no remotes configured" }
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
        return { name: $name, status: "conflict", message: $pull_res.stderr }
    }

    if $stashed {
        let pop_res = (^git -C $mod_path stash pop | complete)
        if ($pop_res.exit_code != 0) or ($pop_res.stdout | str contains "CONFLICT") {
            # Stash pop conflicted with updated remote commits
            # Reset working directory to head_before (no conflict markers in working tree)
            ^git -C $mod_path reset --hard $head_before | complete | ignore
            # Pop the stash cleanly onto original HEAD
            ^git -C $mod_path stash pop | complete | ignore
            return { name: $name, status: "conflict", message: "Stash pop conflicted with upstream changes" }
        }
    }

    let head_after = (^git -C $mod_path rev-parse HEAD | complete).stdout | str trim
    {
        name: $name,
        status: "ok",
        updated: ($head_before != $head_after),
        head: $head_after
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

        let res = (update-module $ygg_home $mod_name)
        $results = ($results | append $res)
    }

    $results
}

# Read-only 3-way status of every tracked copy (RFC-004):
# conflict = both sides differ from each other and from the baseline (or no baseline yet);
# pending_save = changed only on the host. Rows: { dest, module, status } for those two cases.
export def copy-sync-status [state: record]: nothing -> table<dest: string, module: string, status: string> {
    mut rows = []
    for dest in ($state.copies | columns) {
        let entry = ($state.copies | get $dest)
        let src = ($entry.src? | default "")
        let baseline = ($entry.last_synced_hash? | default "")
        if ($src == "") or (($src | path type) != "file") or (($dest | path type) != "file") {
            continue
        }
        let host_hash = (open --raw $dest | hash sha256)
        let mod_hash = (open --raw $src | hash sha256)
        if $host_hash == $mod_hash {
            continue
        }
        let status = if ($baseline == "") or (($host_hash != $baseline) and ($mod_hash != $baseline)) {
            "conflict"
        } else if ($host_hash != $baseline) and ($mod_hash == $baseline) {
            "pending_save"
        } else {
            ""
        }
        if $status != "" {
            $rows = ($rows | append { dest: $dest, module: ($entry.module? | default ""), status: $status })
        }
    }
    $rows
}

# True when a state.links entry is really in place (RFC-004): a link/junction must point at its
# source and resolve (a dangling link matches literally); copies only need to exist.
export def link-entry-ok [dest: string, entry: record]: nothing -> bool {
    let t = ($entry.type? | default "symlink")
    if ($t in ["copy", "dir_copy"]) {
        $dest | path exists
    } else {
        (link-target-matches $dest ($entry.src? | default "")) and ($dest | path exists)
    }
}

# Return module status summary table:
# name, scopes, path, target, branch, dirty, links_ok, sync_conflicts, pending_save
export def modules-status [ygg_home: string]: nothing -> table {
    let host_cfg = (load-host-config $ygg_home)
    let state = (load-state $ygg_home)
    let sync = (copy-sync-status $state)
    let has_git = (which git | is-not-empty)

    mut rows = []

    for mod in ($host_cfg.modules? | default []) {
        let name = $mod.name
        let scopes = ($mod.scopes? | default [])
        let mod_path = if ($mod.path? != null) and ($mod.path != "") {
            $mod.path
        } else {
            ($ygg_home | path join "modules" $name)
        }
        # Resolved location (worktree vs main checkout); the literal path when it does not resolve
        let target = (try { $mod_path | path expand } catch { $mod_path })

        let is_git = ($mod_path | path join ".git" | path exists) and $has_git
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
        let links_ok = ($mod_links | all { |dest| link-entry-ok $dest ($state.links | get $dest) })
        let mod_sync = ($sync | where { |r| $r.module == $name })

        $rows = ($rows | append {
            name: $name,
            scopes: $scopes,
            path: $mod_path,
            target: $target,
            branch: $branch,
            dirty: $dirty,
            links_ok: $links_ok,
            sync_conflicts: ($mod_sync | where { |r| $r.status == "conflict" } | length),
            pending_save: ($mod_sync | where { |r| $r.status == "pending_save" } | length)
        })
    }

    $rows
}

# Generate or update ygg.lock fixing exact commits of all Git modules in plan (RFC-032)
export def generate-ygg-lock [ygg_home: string, plan: record]: nothing -> record {
    let plan_mods = ($plan.modules? | default [])
    mut locked_mods = []

    for mod in $plan_mods {
        let mod_name = $mod.name
        let mod_dir = if ($mod.dir? != null) and ($mod.dir != "") {
            $mod.dir
        } else {
            ($ygg_home | path join "modules" $mod_name)
        }

        let git_dir = ($mod_dir | path join ".git")
        if not ($git_dir | path exists) {
            continue
        }

        let commit_res = (^git -C $mod_dir rev-parse HEAD | complete)
        if $commit_res.exit_code != 0 {
            continue
        }
        let commit = ($commit_res.stdout | str trim)
        if ($commit == "") {
            continue
        }

        let remote_res = (^git -C $mod_dir config --get remote.origin.url | complete)
        let source = if $remote_res.exit_code == 0 {
            $remote_res.stdout | str trim
        } else {
            ""
        }

        let timestamp = (date now | format date "%Y-%m-%dT%H:%M:%SZ")

        $locked_mods = ($locked_mods | append {
            name: $mod_name,
            source: $source,
            commit: $commit,
            timestamp: $timestamp
        })
    }

    let lock_data = {
        version: 1,
        modules: $locked_mods
    }

    let lock_file = ($ygg_home | path join "ygg.lock")
    $"# ygg.lock — generated automatically, do not edit\n\n($lock_data | to toml)" | save -f $lock_file

    $lock_data
}

# Verify that all Git modules in plan match commits recorded in ygg.lock (RFC-032)
export def verify-ygg-lock [ygg_home: string, plan: record]: nothing -> list<string> {
    let lock_file = ($ygg_home | path join "ygg.lock")
    if not ($lock_file | path exists) {
        return [$"Lockfile not found at '($lock_file)'. Run 'ygg apply' first to generate ygg.lock."]
    }

    let lock = (try { open --raw $lock_file | from toml } catch { |e| return [$"Failed to parse '($lock_file)': ($e.msg)"] })
    let locked_mods = ($lock.modules? | default ($lock.module? | default []))

    let plan_mods = ($plan.modules? | default [])
    mut errors = []

    for mod in $plan_mods {
        let mod_name = $mod.name
        let mod_dir = if ($mod.dir? != null) and ($mod.dir != "") {
            $mod.dir
        } else {
            ($ygg_home | path join "modules" $mod_name)
        }

        let git_dir = ($mod_dir | path join ".git")
        if not ($git_dir | path exists) {
            continue
        }

        let commit_res = (^git -C $mod_dir rev-parse HEAD | complete)
        if $commit_res.exit_code != 0 {
            $errors = ($errors | append $"Failed to get HEAD commit for module '($mod_name)'")
            continue
        }
        let current_commit = ($commit_res.stdout | str trim)
        let locked = ($locked_mods | where name == $mod_name | get -o 0)

        if ($locked == null) {
            $errors = ($errors | append $"Module '($mod_name)' is not locked in '($lock_file)'")
        } else if ($locked.commit? | default "") != $current_commit {
            $errors = ($errors | append $"Module '($mod_name)' commit mismatch: expected ($locked.commit? | default ''), found ($current_commit)")
        }
    }

    $errors
}

