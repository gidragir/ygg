# src/link.nu
# Yggdrasil configuration manager — File linker, unfolding, 3-way sync & safe pruning

use state.nu [load-state, save-state, expand-target-path, backup-existing, detect-host-os, to-win32-path]

# Make a file executable (owner) if it is not already; chmod stderr is suppressed.
# In nu 0.116 `ls -lD` mode is a 9-char string ("rwxr-xr-x") without a type char.
def ensure-executable [p: string]: nothing -> nothing {
    let mode = (try { ls -lD $p | get -o 0.mode | default "" } catch { "" })
    if ($mode | str length) >= 9 {
        let m9 = ($mode | str substring (($mode | str length) - 9)..)
        if not ($m9 =~ '^..x') {
            try { ^chmod +x $p | complete | ignore } catch { }
        }
    }
}

# Check if target path is a symlink or NTFS junction (including dangling symlinks)
export def is-link-or-junction [path: string]: nothing -> bool {
    let ptype: any = ($path | path type)
    if ($ptype == "symlink") {
        return true
    }
    if ($ptype == null) {
        return false
    }

    # On Windows, check for ReparsePoint / Junction attribute without admin privileges
    if ($nu.os-info.family == "windows") {
        let parent = ($path | path dirname)
        let name = ($path | path basename)
        let win_parent = (to-win32-path $parent)
        let dir_res = (try {
            ^cmd /c dir /a:l /b $win_parent | complete
        } catch {
            { exit_code: 1, stdout: "" }
        })
        if ($dir_res.exit_code == 0) and ($name in ($dir_res.stdout | lines | str trim)) {
            return true
        }
        let escaped_path = ($path | str replace --all "'" "''")
        let ps_cmd = ("([System.IO.File]::GetAttributes('" + $escaped_path + "').HasFlag([System.IO.FileAttributes]::ReparsePoint))")
        let ps_res = (try {
            ^powershell -NoProfile -Command $ps_cmd | complete
        } catch {
            { exit_code: 1, stdout: "" }
        })
        if ($ps_res.exit_code == 0) and (($ps_res.stdout | str trim | str lowercase) == "true") {
            return true
        }
    }

    false
}

# Safely remove ONLY the symlink or junction without deleting target folder contents.
# Raises an error if called on a real directory.
export def remove-link-only [path: string]: nothing -> nothing {
    let is_link = (is-link-or-junction $path)
    let ptype: any = ($path | path type)

    if not $is_link {
        if ($ptype == "dir") {
            error make { msg: $"Cannot remove real directory '($path)' with remove-link-only" }
        }
    }

    if ($ptype == null) and not $is_link {
        return
    }

    if ($nu.os-info.family == "windows") {
        let win_path = (to-win32-path $path)
        if ($ptype == "dir") or $is_link {
            # Try rmdir (strictly without /S!) for NTFS junction
            let rmdir_res = (try { ^cmd /c rmdir $win_path | complete } catch { { exit_code: 1 } })
            if $rmdir_res.exit_code != 0 {
                # Fall back to del for file symlink
                try { ^cmd /c del /f /q $win_path | complete } catch { }
            }
        } else {
            try { ^cmd /c del /f /q $win_path | complete } catch { }
        }
    } else {
        # Unix: strictly rm without -r
        let rm_res = (^rm $path | complete)
        if $rm_res.exit_code != 0 {
            error make { msg: $"Failed to remove link '($path)': ($rm_res.stderr)" }
        }
    }
}

# 3-way hash synchronization helper for copied files ([save] and Windows single-file links)
def sync-single-file [
    state: record,
    module_name: string,
    src: string,
    dest: string,
    force: bool
]: nothing -> record {
    let existing_copy = ($state.copies | get -o $dest)
    let last_synced_hash = ($existing_copy.last_synced_hash? | default "")

    let src_exists = ($src | path exists)
    let src_hash = if $src_exists { open --raw $src | hash sha256 } else { "" }

    let dest_exists = ($dest | path exists)
    let dest_hash = if $dest_exists { open --raw $dest | hash sha256 } else { "" }

    # Case 1: Force overwrite seeds host from module
    if $force {
        if $src_exists {
            mkdir ($dest | path dirname)
            cp -f $src $dest
            let new_hash = (open --raw $dest | hash sha256)
            return {
                copy_record: { module: $module_name, src: $src, dest: $dest, last_synced_hash: $new_hash },
                action: "force_to_host"
            }
        } else if $dest_exists {
            mkdir ($src | path dirname)
            cp -f $dest $src
            let new_hash = (open --raw $src | hash sha256)
            return {
                copy_record: { module: $module_name, src: $src, dest: $dest, last_synced_hash: $new_hash },
                action: "force_to_module"
            }
        }
    }

    # Case 2: Initial sync (no previous baseline hash recorded)
    if ($last_synced_hash == "") {
        if $dest_exists and $src_exists {
            if ($src_hash == $dest_hash) {
                return {
                    copy_record: { module: $module_name, src: $src, dest: $dest, last_synced_hash: $src_hash },
                    action: "already_synced"
                }
            } else {
                # Initial collision: both exist and differ without baseline
                return {
                    copy_record: { module: $module_name, src: $src, dest: $dest, last_synced_hash: "" },
                    action: "conflict"
                }
            }
        } else if $src_exists and not $dest_exists {
            mkdir ($dest | path dirname)
            cp -f $src $dest
            let new_hash = (open --raw $dest | hash sha256)
            return {
                copy_record: { module: $module_name, src: $src, dest: $dest, last_synced_hash: $new_hash },
                action: "seeded_host"
            }
        } else if $dest_exists and not $src_exists {
            mkdir ($src | path dirname)
            cp -f $dest $src
            let new_hash = (open --raw $src | hash sha256)
            return {
                copy_record: { module: $module_name, src: $src, dest: $dest, last_synced_hash: $new_hash },
                action: "seeded_module"
            }
        } else {
            return {
                copy_record: { module: $module_name, src: $src, dest: $dest, last_synced_hash: "" },
                action: "none"
            }
        }
    }

    # Case 3: 3-way synchronization with existing baseline
    if ($dest_hash != $last_synced_hash) and ($src_hash == $last_synced_hash) {
        # Changed ONLY on host (e.g. GUI edit) -> pull into module repo
        mkdir ($src | path dirname)
        cp -f $dest $src
        return {
            copy_record: { module: $module_name, src: $src, dest: $dest, last_synced_hash: $dest_hash },
            action: "pulled_to_module"
        }
    } else if ($dest_hash == $last_synced_hash) and ($src_hash != $last_synced_hash) {
        # Changed ONLY in module repo -> push to host
        mkdir ($dest | path dirname)
        cp -f $src $dest
        return {
            copy_record: { module: $module_name, src: $src, dest: $dest, last_synced_hash: $src_hash },
            action: "pushed_to_host"
        }
    } else if ($dest_hash != $last_synced_hash) and ($src_hash != $last_synced_hash) {
        if ($dest_hash == $src_hash) {
            # Both changed to identical content
            return {
                copy_record: { module: $module_name, src: $src, dest: $dest, last_synced_hash: $dest_hash },
                action: "converged"
            }
        } else {
            # Mutual edits conflict
            return {
                copy_record: { module: $module_name, src: $src, dest: $dest, last_synced_hash: $last_synced_hash },
                action: "conflict"
            }
        }
    } else {
        # Neither changed
        return {
            copy_record: { module: $module_name, src: $src, dest: $dest, last_synced_hash: $last_synced_hash },
            action: "none"
        }
    }
}

# Generate a .cmd shim for .nu / .ps1 executable scripts in bin/ on Windows
def write-cmd-shim [dest: string]: nothing -> string {
    let ext = ($dest | path parse | get extension)
    let parent_name = ($dest | path dirname | path basename)
    if ($parent_name == "bin") and ($ext in ["nu", "ps1"]) {
        let stem = ($dest | path parse | get stem)
        let cmd_shim = (($dest | path dirname) | path join $"($stem).cmd")
        let shim_content = if ($ext == "nu") {
            $"@echo off\r\nnu \"%~dp0($dest | path basename)\" %*\r\n"
        } else {
            $"@echo off\r\npwsh -NoProfile -ExecutionPolicy Bypass -File \"%~dp0($dest | path basename)\" %*\r\n"
        }
        $shim_content | save -f $cmd_shim
        return $cmd_shim
    }
    ""
}

# Safely prune a tracked file copy: delete cleanly if unedited on host, otherwise backup
def prune-copy [ygg_home: string, dest: string, last_synced_hash: string]: nothing -> nothing {
    if (is-link-or-junction $dest) {
        return
    }
    let ptype: any = ($dest | path type)
    if ($ptype != "file") {
        return
    }

    let current_hash = (open --raw $dest | hash sha256)
    if ($last_synced_hash != "") and ($current_hash == $last_synced_hash) {
        try { rm -f $dest }
    } else {
        backup-existing $ygg_home $dest | ignore
    }
}

# Prepare destination before linking: remove link/junction, preserve tracked copy if unchanged, or backup
def prepare-dest [
    state: record,
    ygg_home: string,
    dest: string,
    keeps_copy: bool,
    force: bool
]: nothing -> nothing {
    if (is-link-or-junction $dest) {
        remove-link-only $dest
        return
    }

    let ptype: any = ($dest | path type)
    if ($ptype == null) {
        return
    }

    let is_tracked_copy = ($dest in ($state.copies | columns))
    if $keeps_copy and (not $force) and $is_tracked_copy and ($ptype == "file") {
        return
    }

    backup-existing $ygg_home $dest | ignore
}

# Apply planned links, /* unfolding, .cmd shims, 3-way copy sync, and prune stale links
export def apply-links [
    ygg_home: string,
    plan: record,
    --dry-run,
    --force,
    --sandbox: string = ""
]: nothing -> record {
    mut state = (load-state $ygg_home)
    let host_os = (detect-host-os)
    let is_windows = ($host_os.os == "windows")
    let effective_sandbox = if ($sandbox != "") { $sandbox } else { ($env.YGG_SANDBOX? | default "") }

    mut active_links = []
    mut active_copies = []
    mut applied_links = []
    mut synced_copies = []
    mut pruned_links = []

    # 1. Process plan.links
    let links_list = ($plan.links? | default [])
    for link in $links_list {
        let is_glob = ($link.is_glob? | default false)
        let dest_raw = $link.dest_raw
        let src_path = $link.src_path
        let mod_name = $link.module

        if $is_glob {
            let clean_dest_raw = ($dest_raw | str replace --regex '[\\/]\*$' '')
            let dest_dir = (expand-target-path $clean_dest_raw --sandbox $effective_sandbox | str trim -r -c "/" | str trim -r -c "\\")

            # Ownership conflict check: target directory must NOT be an existing link or junction
            if (is-link-or-junction $dest_dir) {
                error make { msg: $"Shared directory ownership conflict: target '($dest_dir)' is a link/junction" }
            }

            if not $dry_run {
                if not ($dest_dir | path exists) {
                    mkdir $dest_dir
                }
            }

            if ($src_path | path exists) {
                let items = (try { ls -a $src_path } catch { [] }
                    | where name !~ '^\.{1,2}$'
                    | where { |it| ($it.name | path basename) != ".git" })

                for it in $items {
                    let item_name = ($it.name | path basename)
                    let target_item = ($dest_dir | path join $item_name)
                    let src_item = $it.name
                    $active_links = ($active_links | append $target_item)

                    let is_item_dir = ($it.type == "dir")
                    let keeps_copy = ($is_windows and not $is_item_dir)

                    if not $dry_run {
                        prepare-dest $state $ygg_home $target_item $keeps_copy $force

                        if $is_windows {
                            if $is_item_dir {
                                if ($nu.os-info.family == "windows") {
                                    let win_target = (to-win32-path $target_item)
                                    let win_src = (to-win32-path $src_item)
                                    ^cmd /c mklink /J $win_target $win_src
                                } else {
                                    ^ln -sfn $src_item $target_item
                                }
                                let link_record = {
                                    module: $mod_name,
                                    src: $src_item,
                                    type: "junction",
                                    cmd_shim: ""
                                }
                                $state.links = ($state.links | upsert $target_item $link_record)
                                $applied_links = ($applied_links | append $target_item)
                            } else {
                                let cmd_shim = (write-cmd-shim $target_item)
                                let sync_res = (sync-single-file $state $mod_name $src_item $target_item $force)
                                if ($sync_res.action == "conflict") {
                                    print -e $"[ygg] Warning: 3-way sync conflict on '($target_item)' \(both host and module modified\). Preserving host version. Run 'ygg apply --force' to take the module version or 'ygg save --force' to keep the host version."
                                }
                                $state.copies = ($state.copies | upsert $target_item $sync_res.copy_record)
                                $active_copies = ($active_copies | append $target_item)

                                let link_record = {
                                    module: $mod_name,
                                    src: $src_item,
                                    type: "copy",
                                    cmd_shim: $cmd_shim
                                }
                                $state.links = ($state.links | upsert $target_item $link_record)
                                $applied_links = ($applied_links | append $target_item)
                            }
                        } else {
                            # Unix symlink
                            ^ln -sfn $src_item $target_item
                            let parent_name = ($target_item | path dirname | path basename)
                            if not $is_item_dir and ($parent_name == "bin") {
                                ensure-executable $src_item
                            }
                            let link_record = {
                                module: $mod_name,
                                src: $src_item,
                                type: "symlink",
                                cmd_shim: ""
                            }
                            $state.links = ($state.links | upsert $target_item $link_record)
                            $applied_links = ($applied_links | append $target_item)
                        }
                    }
                }
            }
        } else {
            # Single non-glob link
            let dest = (expand-target-path $dest_raw --sandbox $effective_sandbox)
            $active_links = ($active_links | append $dest)

            let is_src_dir = ((try { $src_path | path type }) == "dir")
            let keeps_copy = ($is_windows and not $is_src_dir)

            if not $dry_run {
                prepare-dest $state $ygg_home $dest $keeps_copy $force

                mkdir ($dest | path dirname)

                if $is_windows {
                    if $is_src_dir {
                        if ($nu.os-info.family == "windows") {
                            let win_dest = (to-win32-path $dest)
                            let win_src = (to-win32-path $src_path)
                            ^cmd /c mklink /J $win_dest $win_src
                        } else {
                            ^ln -sfn $src_path $dest
                        }
                        let link_record = {
                            module: $mod_name,
                            src: $src_path,
                            type: "junction",
                            cmd_shim: ""
                        }
                        $state.links = ($state.links | upsert $dest $link_record)
                        $applied_links = ($applied_links | append $dest)
                    } else {
                        # Single file on Windows: 3-way copy sync
                        let cmd_shim = (write-cmd-shim $dest)

                        let sync_res = (sync-single-file $state $mod_name $src_path $dest $force)
                        if ($sync_res.action == "conflict") {
                            print -e $"[ygg] Warning: 3-way sync conflict on '($dest)' \(both host and module modified\). Preserving host version. Run 'ygg apply --force' to take the module version or 'ygg save --force' to keep the host version."
                        }
                        $state.copies = ($state.copies | upsert $dest $sync_res.copy_record)
                        $active_copies = ($active_copies | append $dest)

                        let link_record = {
                            module: $mod_name,
                            src: $src_path,
                            type: "copy",
                            cmd_shim: $cmd_shim
                        }
                        $state.links = ($state.links | upsert $dest $link_record)
                        $applied_links = ($applied_links | append $dest)
                    }
                } else {
                    # Unix symlink
                    ^ln -sfn $src_path $dest
                    let parent_name = ($dest | path dirname | path basename)
                    if not $is_src_dir and ($parent_name == "bin") {
                        ensure-executable $src_path
                    }
                    let link_record = {
                        module: $mod_name,
                        src: $src_path,
                        type: "symlink",
                        cmd_shim: ""
                    }
                    $state.links = ($state.links | upsert $dest $link_record)
                    $applied_links = ($applied_links | append $dest)
                }
            }
        }
    }

    # 2. Process plan.save (3-way sync copy)
    let save_list = ($plan.save? | default [])
    for save_item in $save_list {
        let src_path = $save_item.src_path
        let dest_raw = $save_item.dest_raw
        let mod_name = $save_item.module
        let expanded_dest = (expand-target-path $dest_raw --sandbox $effective_sandbox)

        let dest_matches = if ($expanded_dest | str contains "*") or ($expanded_dest | str contains "?") {
            glob $expanded_dest
        } else {
            [$expanded_dest]
        }

        for dest_file in $dest_matches {
            $active_copies = ($active_copies | append $dest_file)
            if not $dry_run {
                let sync_res = (sync-single-file $state $mod_name $src_path $dest_file $force)
                if ($sync_res.action == "conflict") {
                    print -e $"[ygg] Warning: 3-way sync conflict on '($dest_file)' \(both host and module modified\). Preserving host version. Run 'ygg apply --force' to take the module version or 'ygg save --force' to keep the host version."
                }
                $state.copies = ($state.copies | upsert $dest_file $sync_res.copy_record)
                $synced_copies = ($synced_copies | append $dest_file)
            }
        }
    }

    # 3. Pruning stale links
    let old_links = ($state.links | columns)
    for old_dest in $old_links {
        if $old_dest not-in $active_links {
            if not $dry_run {
                let old_record = ($state.links | get $old_dest)
                if (is-link-or-junction $old_dest) {
                    remove-link-only $old_dest
                } else if ($old_record.type? == "copy") {
                    let copy_entry = ($state.copies | get -o $old_dest)
                    let last_hash = ($copy_entry.last_synced_hash? | default "")
                    prune-copy $ygg_home $old_dest $last_hash
                }
                let shim = ($old_record.cmd_shim? | default "")
                if ($shim != "") and ($shim | path exists) {
                    try { remove-link-only $shim }
                }
            }
            $state.links = ($state.links | reject $old_dest)
            $pruned_links = ($pruned_links | append $old_dest)
        }
    }

    # 4. Prune stale copies
    let old_copies = ($state.copies | columns)
    for old_dest in $old_copies {
        if $old_dest not-in $active_copies {
            if not $dry_run {
                let copy_entry = ($state.copies | get -o $old_dest)
                let last_hash = ($copy_entry.last_synced_hash? | default "")
                prune-copy $ygg_home $old_dest $last_hash
            }
            $state.copies = ($state.copies | reject $old_dest)
        }
    }

    if not $dry_run {
        save-state $ygg_home $state
    }

    {
        applied: $applied_links,
        pruned: $pruned_links,
        copies: $synced_copies
    }
}

# Reverse capture from host to module repository for all tracked copies and [save] entries
export def save-copied-files [
    ygg_home: string,
    plan: record,
    --sandbox: string = "",
    --force
]: nothing -> list<string> {
    let effective_sandbox = if ($sandbox != "") { $sandbox } else { ($env.YGG_SANDBOX? | default "") }
    mut state = (load-state $ygg_home)
    mut saved = []

    # 1. Update from state.copies
    let tracked_copies = ($state.copies | columns)
    for dest in $tracked_copies {
        let entry = ($state.copies | get $dest)
        let src = $entry.src
        if ($dest | path exists) {
            let last_hash = ($entry.last_synced_hash? | default "")
            if ($last_hash == "") and (not $force) {
                print -e $"[ygg] Warning: Skipping conflict on '($dest)' \(no baseline\). Use 'ygg save --force' to overwrite module with host version."
                continue
            }
            let host_content = (open --raw $dest)
            let host_hash = ($host_content | hash sha256)
            let src_hash = if ($src | path exists) { open --raw $src | hash sha256 } else { "" }

            if ($host_hash != $src_hash) {
                mkdir ($src | path dirname)
                $host_content | save -f $src
                $state.copies = ($state.copies | upsert $dest {
                    module: $entry.module,
                    src: $src,
                    dest: $dest,
                    last_synced_hash: $host_hash
                })
                $saved = ($saved | append $src)
            }
        }
    }

    # 2. Check any remaining matching [save] entries from plan
    let save_list = ($plan.save? | default [])
    for save_item in $save_list {
        let src = $save_item.src_path
        let dest_raw = $save_item.dest_raw
        let expanded_dest = (expand-target-path $dest_raw --sandbox $effective_sandbox)

        let matches = if ($expanded_dest | str contains "*") or ($expanded_dest | str contains "?") {
            glob $expanded_dest
        } else {
            if ($expanded_dest | path exists) { [$expanded_dest] } else { [] }
        }

        for dest in $matches {
            if $dest not-in $tracked_copies {
                let host_content = (open --raw $dest)
                let host_hash = ($host_content | hash sha256)
                let src_hash = if ($src | path exists) { open --raw $src | hash sha256 } else { "" }

                if ($host_hash != $src_hash) {
                    mkdir ($src | path dirname)
                    $host_content | save -f $src
                    $state.copies = ($state.copies | upsert $dest {
                        module: $save_item.module,
                        src: $src,
                        dest: $dest,
                        last_synced_hash: $host_hash
                    })
                    $saved = ($saved | append $src)
                }
            }
        }
    }

    save-state $ygg_home $state
    $saved | uniq
}

# Safely unlink all links, .cmd shims and copy tracking for a given module
export def unlink-module [ygg_home: string, module_name: string]: nothing -> int {
    mut state = (load-state $ygg_home)
    mut count = 0

    let link_keys = ($state.links | columns)
    for dest in $link_keys {
        let entry = ($state.links | get $dest)
        if ($entry.module? | default "") == $module_name {
            if (is-link-or-junction $dest) {
                remove-link-only $dest
            } else {
                let copy_entry = ($state.copies | get -o $dest)
                let last_hash = ($copy_entry.last_synced_hash? | default "")
                prune-copy $ygg_home $dest $last_hash
            }

            let shim = ($entry.cmd_shim? | default "")
            if ($shim != "") and ($shim | path exists) {
                try { remove-link-only $shim }
            }

            $state.links = ($state.links | reject $dest)
            $count = $count + 1
        }
    }

    let copy_keys = ($state.copies | columns)
    for dest in $copy_keys {
        let entry = ($state.copies | get $dest)
        if ($entry.module? | default "") == $module_name {
            $state.copies = ($state.copies | reject $dest)
        }
    }

    save-state $ygg_home $state
    $count
}

# Pre-flight validation of the plan before any host mutation (Stage 0: missing link sources)
export def preflight-check [
    ygg_home: string,
    plan: record,
    resolved: record = {},
    ops: table = [],
    --force,
    --sandbox: string = ""
]: nothing -> list<record<module: string, key: string, reason: string, detail: string>> {
    mut problems = []
    for link in ($plan.links? | default []) {
        let src = $link.src_path
        let has_wildcard = ($src | str contains "*") or ($src | str contains "?")
        let exists = if $has_wildcard {
            false
        } else {
            try { ($src | path exists) } catch { false }
        }
        if not $exists {
            $problems = ($problems | append {
                module: $link.module,
                key: $link.key,
                reason: "missing_source",
                detail: $"Source path '($src)' does not exist"
            })
        }
    }
    $problems
}

export def format-preflight-errors [problems: list<record>]: nothing -> string {
    let lines = ($problems | each { |p| $"  - [($p.module)] '($p.key)' \(($p.reason)\): ($p.detail)" })
    "Pre-flight check failed:\n" + ($lines | str join "\n")
}
