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

# Normalize a path for comparison/grouping (RFC-009): on Windows strip \\?\ and UNC\ prefixes,
# unify separators to "\" and compare case-insensitively; on Unix only trim a trailing "/".
export def normalize-case [p: string]: nothing -> string {
    if ($nu.os-info.family == "windows") {
        $p | str replace --regex '^\\\\\?\\(UNC\\)?' '' | str replace -a "/" "\\" | str trim -r -c "\\" | str lowercase
    } else {
        $p | str trim -r -c "/"
    }
}

# Literal (unresolved) target of a link as an absolute path; "" when it cannot be read.
# On Windows `ls -lD` may leave `target` empty for NTFS junctions -> ask PowerShell (no $"..." with "[").
export def link-literal-target [dest: string]: nothing -> string {
    let t = (try { ls -lD $dest | get -o 0.target | default "" } catch { "" })
    let raw = if ($t != "") or ($nu.os-info.family != "windows") {
        $t
    } else {
        let esc = ($dest | str replace --all "'" "''")
        let cmd = ("(Get-Item -LiteralPath '" + $esc + "' -Force).Target | Select-Object -First 1")
        try { (^powershell -NoProfile -Command $cmd | complete).stdout | str trim } catch { "" }
    }
    if ($raw == "") or ($raw =~ '^(/|[A-Za-z]:|\\\\)') {
        $raw
    } else {
        $dest | path dirname | path join $raw
    }
}

# True when `dest` is a link/junction that already resolves to `src` (RFC-009):
# 1) literal target vs src without resolving symlinks; 2) both resolved paths (only if both exist).
export def link-target-matches [dest: string, src: string]: nothing -> bool {
    if not (is-link-or-junction $dest) {
        return false
    }
    let literal = (link-literal-target $dest)
    let lexical_src = (normalize-case ($src | path expand -n))
    if ($literal != "") and ((normalize-case ($literal | path expand -n)) == $lexical_src) {
        return true
    }
    if not (($dest | path exists) and ($src | path exists)) {
        return false
    }
    (normalize-case ($dest | path expand)) == (normalize-case ($src | path expand))
}

# Atomically replace an existing symlink on Unix: temp link in the same directory + rename(2).
# Nushell's builtin `mv` is forbidden here: with link -> dir it moves tmp INSIDE the directory.
export def swap-symlink-atomic [src: string, dest: string]: nothing -> nothing {
    let tmp = $"($dest).ygg-tmp-(random chars --length 8)"
    ^ln -s $src $tmp
    # GNU: -T; BSD/macOS: -h (Проверить на macOS)
    let no_follow = if ($nu.os-info.name == "macos") { "-hf" } else { "-Tf" }
    let res = (^mv $no_follow $tmp $dest | complete)
    if $res.exit_code != 0 {
        ^rm -f $tmp | complete | ignore
        ^ln -sfn $src $dest
    }
}

# Create a directory link on Windows without admin rights (RFC-006):
# mklink /J (junction) -> mklink /D (dir symlink) -> cp -r (type "dir_copy", not auto-synced).
# On a non-Windows host (YGG_HOST_OS_OVERRIDE=windows in tests) a symlink emulates the junction.
export def create-windows-dir-link [src: string, dest: string]: nothing -> record<ok: bool, type: string, stderr: string> {
    if ($nu.os-info.family != "windows") {
        let r = (^ln -sfn $src $dest | complete)
        return { ok: ($r.exit_code == 0), type: "junction", stderr: $r.stderr }
    }
    let win_dest = (to-win32-path $dest)
    let win_src = (to-win32-path $src)
    let res_j = (try { ^cmd /c mklink /J $win_dest $win_src | complete } catch { |e| { exit_code: 1, stdout: "", stderr: $e.msg } })
    if $res_j.exit_code == 0 {
        return { ok: true, type: "junction", stderr: "" }
    }
    let res_d = (try { ^cmd /c mklink /D $win_dest $win_src | complete } catch { |e| { exit_code: 1, stdout: "", stderr: $e.msg } })
    if $res_d.exit_code == 0 {
        return { ok: true, type: "symlink", stderr: "" }
    }
    try {
        cp -r $src $dest
        print -e $"[ygg] Warning: cannot create junction or symlink for '($dest)'; fell back to a directory copy \(dir_copy, not synchronized automatically\)."
        { ok: true, type: "dir_copy", stderr: "" }
    } catch { |e|
        { ok: false, type: "", stderr: ([$res_j.stderr, $res_d.stderr, $e.msg] | str join " | ") }
    }
}

# Resolve link and save candidates into unique destinations (RFC-010). Does not touch the filesystem
# except for listing glob sources. Priority (low -> high): specificity (glob 0 < explicit 1),
# module_rank, origin_rank, key_order; the last row of each destination group wins.
export def resolve-link-targets [
    plan: record,
    --sandbox: string = ""
]: nothing -> record<targets: table, save_targets: table, collisions: table, nesting_conflicts: list<record>> {
    let effective_sandbox = if ($sandbox != "") { $sandbox } else { ($env.YGG_SANDBOX? | default "") }
    let sep = if ($nu.os-info.family == "windows") { "\\" } else { "/" }

    # 1. Expand candidates
    mut candidates = []
    for link in ($plan.links? | default []) {
        let base = {
            module: $link.module,
            module_rank: ($link.module_rank? | default 0),
            origin_rank: ($link.origin_rank? | default 0),
            key_order: ($link.key_order? | default 0),
            key: $link.key,
            on_change: ($link.on_change? | default ""),
            mode: ($link.mode? | default "")
        }
        let src_path = $link.src_path
        let has_wildcard = ($src_path | str contains "*") or ($src_path | str contains "?")
        if ($link.is_glob? | default false) {
            let clean_dest_raw = ($link.dest_raw | str replace --regex '[\\/]\*$' '')
            let dest_dir = (expand-target-path $clean_dest_raw --sandbox $effective_sandbox | str trim -r -c "/" | str trim -r -c "\\")
            let src_exists = if $has_wildcard { false } else { try { $src_path | path exists } catch { false } }
            if $src_exists {
                let items = (try { ls -a $src_path } catch { [] }
                    | where { |it| ($it.name | path basename) not-in [".", "..", ".git"] })
                for it in $items {
                    $candidates = ($candidates | append ($base | merge {
                        src: $it.name,
                        dest: ($dest_dir | path join ($it.name | path basename)),
                        is_dir: ($it.type == "dir"),
                        is_glob_child: true,
                        glob_dest_dir: $dest_dir,
                        specificity: 0
                    }))
                }
            }
        } else {
            let dest = (expand-target-path $link.dest_raw --sandbox $effective_sandbox)
            let src_type = if $has_wildcard { null } else { try { $src_path | path type } catch { null } }
            $candidates = ($candidates | append ($base | merge {
                src: $src_path,
                dest: $dest,
                is_dir: ($src_type == "dir"),
                is_glob_child: false,
                glob_dest_dir: "",
                specificity: 1
            }))
        }
    }

    # 2-3. Rank, group by normalized destination, collect cross-module collisions
    mut winners = []
    mut collisions = []
    let link_groups = ($candidates
        | each { |c| $c | insert norm (normalize-case $c.dest) }
        | sort-by specificity module_rank origin_rank key_order
        | group-by norm
        | values)
    for g in $link_groups {
        let winner = ($g | last)
        $winners = ($winners | append $winner)
        for loser in ($g | drop 1) {
            if ($loser.module != $winner.module) {
                $collisions = ($collisions | append {
                    dest: $winner.dest,
                    winner_module: $winner.module,
                    winner_key: $winner.key,
                    loser_module: $loser.module,
                    loser_key: $loser.key
                })
            }
        }
    }

    # 4. [save]: rules 2-5 and the same diagnostics
    let save_cands = ($plan.save? | default [] | each { |s|
        let dest = (expand-target-path $s.dest_raw --sandbox $effective_sandbox)
        {
            module: $s.module,
            module_rank: ($s.module_rank? | default 0),
            origin_rank: ($s.origin_rank? | default 0),
            key_order: ($s.key_order? | default 0),
            key: $s.key,
            src: $s.src_path,
            dest: $dest,
            norm: (normalize-case $dest)
        }
    })
    mut save_targets = []
    let save_groups = ($save_cands | sort-by module_rank origin_rank key_order | group-by norm | values)
    for g in $save_groups {
        let winner = ($g | last)
        $save_targets = ($save_targets | append ($winner | reject norm))
        for loser in ($g | drop 1) {
            if ($loser.module != $winner.module) {
                $collisions = ($collisions | append {
                    dest: $winner.dest,
                    winner_module: $winner.module,
                    winner_key: $winner.key,
                    loser_module: $loser.module,
                    loser_key: $loser.key
                })
            }
        }
    }

    # 5. Nesting: no directory-link winner may be a strict parent of another winner
    mut nesting = []
    let all_winners = $winners
    for parent in ($all_winners | where { |w| $w.is_dir }) {
        let prefix = ($parent.norm + $sep)
        for child in ($all_winners | where { |w| $w.norm | str starts-with $prefix }) {
            $nesting = ($nesting | append {
                module: $child.module,
                key: $child.key,
                parent_dest: $parent.dest,
                child_dest: $child.dest,
                parent_module: $parent.module,
                parent_key: $parent.key
            })
        }
    }

    {
        targets: ($winners | each { |w| $w | reject norm }),
        save_targets: $save_targets,
        collisions: $collisions,
        nesting_conflicts: $nesting
    }
}

# Create or keep a Unix symlink idempotently (RFC-009). Returns the operation: OK | LINK | RELINK | BACKUP_REPLACE.
def link-unix [ygg_home: string, src: string, dest: string]: nothing -> string {
    if (link-target-matches $dest $src) {
        return "OK"
    }
    if (is-link-or-junction $dest) {
        swap-symlink-atomic $src $dest
        return "RELINK"
    }
    if (($dest | path type) != null) {
        backup-existing $ygg_home $dest | ignore
        ^ln -s $src $dest
        return "BACKUP_REPLACE"
    }
    mkdir ($dest | path dirname)
    ^ln -s $src $dest
    "LINK"
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

# Apply resolved links (RFC-010 priorities), idempotent/atomic symlinks (RFC-009), Windows junction
# fallback (RFC-006), .cmd shims, 3-way copy sync, and prune stale links
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

    let resolved = (resolve-link-targets $plan --sandbox $effective_sandbox)

    # 0. Checks before any host mutation (also in dry-run)
    if ($resolved.nesting_conflicts | is-not-empty) {
        let lines = ($resolved.nesting_conflicts | each { |n|
            $"  - '($n.child_dest)' \(($n.module): ($n.key)\) is inside directory link '($n.parent_dest)' \(($n.parent_module): ($n.parent_key)\)"
        })
        error make { msg: ("Shared directory ownership conflict: nested link targets\n" + ($lines | str join "\n")) }
    }

    let glob_dirs = ($plan.links? | default []
        | where { |l| $l.is_glob? | default false }
        | each { |l|
            let clean_dest_raw = ($l.dest_raw | str replace --regex '[\\/]\*$' '')
            expand-target-path $clean_dest_raw --sandbox $effective_sandbox | str trim -r -c "/" | str trim -r -c "\\"
        }
        | uniq)
    for dest_dir in $glob_dirs {
        # Ownership conflict check: target directory must NOT be an existing link or junction
        if (is-link-or-junction $dest_dir) {
            error make { msg: $"Shared directory ownership conflict: target '($dest_dir)' is a link/junction" }
        }
    }

    # One diagnostic line per destination for cross-module overrides
    for c in ($resolved.collisions | group-by dest | values | each { |g| $g | last }) {
        print -e $"[ygg] Collision: destination '($c.dest)' claimed by '($c.loser_module)' is overridden by '($c.winner_module)'"
    }

    mut active_links = []
    mut active_copies = []
    mut applied_links = []
    mut synced_copies = []
    mut pruned_links = []
    mut failed = []

    if not $dry_run {
        for dest_dir in $glob_dirs {
            if not ($dest_dir | path exists) {
                mkdir $dest_dir
            }
        }
    }

    # 1. Process resolved link targets (winners only)
    for tgt in $resolved.targets {
        let dest = $tgt.dest
        let src_path = $tgt.src
        let mod_name = $tgt.module
        let is_src_dir = $tgt.is_dir
        $active_links = ($active_links | append $dest)

        if $dry_run {
            continue
        }

        if $is_windows {
            if $is_src_dir {
                let existing = ($state.links | get -o $dest)
                let existing_type = ($existing.type? | default "")
                if (link-target-matches $dest $src_path) {
                    # OK: no rmdir/mklink, only refresh the state record
                    let keep_type = if ($existing_type in ["junction", "symlink"]) { $existing_type } else { "junction" }
                    $state.links = ($state.links | upsert $dest { module: $mod_name, src: $src_path, type: $keep_type, cmd_shim: "" })
                } else if ($existing_type == "dir_copy") and (($dest | path type) == "dir") and not (is-link-or-junction $dest) {
                    # RFC-006: dir_copy is not re-created automatically (host edits must survive)
                    print -e $"[ygg] Warning: '($dest)' is a directory copy \(dir_copy\) and is not synchronized automatically."
                    $state.links = ($state.links | upsert $dest { module: $mod_name, src: $src_path, type: "dir_copy", cmd_shim: "" })
                } else {
                    let prep_err = (try {
                        if (is-link-or-junction $dest) {
                            remove-link-only $dest
                        } else if (($dest | path type) != null) {
                            backup-existing $ygg_home $dest | ignore
                        }
                        mkdir ($dest | path dirname)
                        ""
                    } catch { |e| $e.msg })
                    let res = if ($prep_err == "") {
                        create-windows-dir-link $src_path $dest
                    } else {
                        { ok: false, type: "", stderr: $prep_err }
                    }
                    if $res.ok {
                        $state.links = ($state.links | upsert $dest { module: $mod_name, src: $src_path, type: $res.type, cmd_shim: "" })
                        $applied_links = ($applied_links | append $dest)
                    } else {
                        print -e $"[ygg] Warning: failed to link '($dest)' -> '($src_path)': ($res.stderr)"
                        $failed = ($failed | append { dest: $dest, src: $src_path, module: $mod_name, stderr: $res.stderr })
                    }
                }
            } else {
                # Single file on Windows: 3-way copy sync
                prepare-dest $state $ygg_home $dest true $force
                mkdir ($dest | path dirname)
                let cmd_shim = (write-cmd-shim $dest)
                let sync_res = (sync-single-file $state $mod_name $src_path $dest $force)
                if ($sync_res.action == "conflict") {
                    print -e $"[ygg] Warning: 3-way sync conflict on '($dest)' \(both host and module modified\). Preserving host version. Run 'ygg apply --force' to take the module version or 'ygg save --force' to keep the host version."
                }
                $state.copies = ($state.copies | upsert $dest $sync_res.copy_record)
                $active_copies = ($active_copies | append $dest)
                $state.links = ($state.links | upsert $dest { module: $mod_name, src: $src_path, type: "copy", cmd_shim: $cmd_shim })
                $applied_links = ($applied_links | append $dest)
            }
        } else {
            # Unix symlink: no-op when already correct, atomic swap otherwise
            let op = (link-unix $ygg_home $src_path $dest)
            let parent_name = ($dest | path dirname | path basename)
            if not $is_src_dir and ($parent_name == "bin") {
                ensure-executable $src_path
            }
            $state.links = ($state.links | upsert $dest { module: $mod_name, src: $src_path, type: "symlink", cmd_shim: "" })
            if ($op != "OK") {
                $applied_links = ($applied_links | append $dest)
            }
        }
    }

    # 2. Process resolved [save] targets (3-way sync copy)
    for save_item in $resolved.save_targets {
        let src_path = $save_item.src
        let mod_name = $save_item.module
        let expanded_dest = $save_item.dest

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
                } else if ($old_record.type? == "dir_copy") and (($old_dest | path type) == "dir") {
                    # RFC-006: a directory copy is never deleted, only moved to backups
                    backup-existing $ygg_home $old_dest | ignore
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
        copies: $synced_copies,
        failed: $failed
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

    # 2. Check any remaining matching [save] entries from the resolved plan (RFC-010 winners only)
    let save_list = (resolve-link-targets $plan --sandbox $effective_sandbox).save_targets
    for save_item in $save_list {
        let src = $save_item.src
        let expanded_dest = $save_item.dest

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
            } else if ($entry.type? == "dir_copy") {
                # RFC-006: a directory copy is never deleted, only moved to backups
                if (($dest | path type) == "dir") {
                    backup-existing $ygg_home $dest | ignore
                }
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
