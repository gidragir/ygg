# src/link.nu
# Yggdrasil configuration manager — File linker, unfolding, 3-way sync & safe pruning

use state.nu [load-state, save-state, expand-target-path, backup-existing, fs-windows, to-win32-path]
use env.nu [validate-secret-providers, load-secrets-env]

# Make a file executable (owner) if it is not already; chmod stderr is suppressed.
# In nu 0.116 `ls -lD` mode is a 9-char string ("rwxr-xr-x") without a type char.
# `ls -lD` is lstat: stat the resolved path so a symlinked source reports its real mode.
def ensure-executable [p: string]: nothing -> nothing {
    let mode = (try { ls -lD ($p | path expand) | get -o 0.mode | default "" } catch { "" })
    if ($mode | str length) >= 9 {
        let m9 = ($mode | str substring (($mode | str length) - 9)..)
        if not ($m9 =~ '^..x') {
            try { ^chmod +x $p | complete | ignore } catch { }
        }
    }
}

# Check if target path is a symlink or NTFS junction (including dangling ones).
# `path type` uses symlink_metadata: Rust reports name-surrogate reparse points (symlinks, junctions)
# as "symlink". Other reparse points (OneDrive/Cloud Files placeholders, WOF, AppExecLink) are real
# data and must NOT be treated as links, so no generic ReparsePoint attribute probe is done.
export def is-link-or-junction [path: string]: nothing -> bool {
    ($path | path type) == "symlink"
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
        if $is_link {
            # rmdir (strictly without /S!) removes a junction / directory symlink itself
            let rmdir_res = (try { ^cmd /c rmdir $win_path | complete } catch { { exit_code: 1, stderr: "" } })
            if $rmdir_res.exit_code != 0 {
                # `del` on a link to a directory deletes the files of its TARGET: only a file
                # symlink (or a dangling one) may fall back to del
                let points_to_dir = (try { ($path | path expand | path type) == "dir" } catch { false })
                if $points_to_dir {
                    error make { msg: $"Failed to remove directory link '($path)': ($rmdir_res.stderr | str trim)" }
                }
                try { ^cmd /c del /f /q $win_path | complete | ignore } catch { }
            }
        } else {
            try { ^cmd /c del /f /q $win_path | complete | ignore } catch { }
        }
        # cmd's del reports success even when nothing was removed
        if (($path | path type) != null) {
            error make { msg: $"Failed to remove link '($path)'" }
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
                        is_dir: (($it.name | path type) == "dir"),
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

# Move a real file or directory to $YGG_HOME/.state/backups/<timestamp>/ and report it (RFC-011)
export def backup-with-notice [ygg_home: string, target: string]: nothing -> string {
    let bkp = (backup-existing $ygg_home $target)
    if ($bkp != "") {
        print $"[ygg] Backed up existing '($target)' -> '($bkp)'"
    }
    $bkp
}

def has-wildcard [p: string]: nothing -> bool {
    ($p | str contains "*") or ($p | str contains "?")
}

def file-hash [p: string]: nothing -> string {
    if ($p | path exists) and (($p | path type) != "dir") {
        open --raw $p | hash sha256
    } else {
        ""
    }
}

# Read-only 3-way classification of a tracked copy ([save] and Windows single-file links).
# op: OK | COPY | CONFLICT; detail: seeded_host | seeded_module | pulled_to_module | pushed_to_host |
# force_to_host | force_to_module (COPY), already_synced | converged | none (OK), conflict (CONFLICT).
# copy_record.last_synced_hash is the hash both sides will have after run-copy-sync.
def plan-copy-sync [
    state: record,
    module_name: string,
    src: string,
    dest: string,
    force: bool
]: nothing -> record<op: string, detail: string, copy_record: record> {
    let last = (($state.copies | get -o $dest).last_synced_hash? | default "")
    let src_hash = (file-hash $src)
    let dest_hash = (file-hash $dest)
    let src_exists = ($src_hash != "")
    let dest_exists = ($dest_hash != "")
    let res = { |op: string, detail: string, h: string|
        { op: $op, detail: $detail, copy_record: { module: $module_name, src: $src, dest: $dest, last_synced_hash: $h } }
    }

    if $force and ($src_exists or $dest_exists) {
        if $src_exists and $dest_exists and ($src_hash == $dest_hash) {
            return (do $res "OK" "already_synced" $src_hash)
        }
        if $src_exists {
            return (do $res "COPY" "force_to_host" $src_hash)
        }
        return (do $res "COPY" "force_to_module" $dest_hash)
    }

    if not ($src_exists or $dest_exists) {
        return (do $res "OK" "none" $last)
    }
    if $src_exists and not $dest_exists {
        return (do $res "COPY" "seeded_host" $src_hash)
    }
    if $dest_exists and not $src_exists {
        return (do $res "COPY" "seeded_module" $dest_hash)
    }

    # Both sides exist
    if ($last == "") {
        if ($src_hash == $dest_hash) {
            return (do $res "OK" "already_synced" $src_hash)
        }
        return (do $res "CONFLICT" "conflict" "")
    }
    if ($dest_hash != $last) and ($src_hash == $last) {
        # Changed ONLY on host (e.g. GUI edit) -> pull into module repo
        return (do $res "COPY" "pulled_to_module" $dest_hash)
    }
    if ($dest_hash == $last) and ($src_hash != $last) {
        # Changed ONLY in module repo -> push to host
        return (do $res "COPY" "pushed_to_host" $src_hash)
    }
    if ($dest_hash != $last) and ($src_hash != $last) {
        if ($dest_hash == $src_hash) {
            return (do $res "OK" "converged" $dest_hash)
        }
        return (do $res "CONFLICT" "conflict" $last)
    }
    do $res "OK" "none" $last
}

# Execute the file transfer planned by plan-copy-sync
def run-copy-sync [p: record]: nothing -> nothing {
    let src = $p.copy_record.src
    let dest = $p.copy_record.dest
    match $p.detail {
        "seeded_host" | "pushed_to_host" | "force_to_host" => {
            mkdir ($dest | path dirname)
            cp -f $src $dest
        }
        "seeded_module" | "pulled_to_module" | "force_to_module" => {
            mkdir ($src | path dirname)
            cp -f $dest $src
        }
        _ => { }
    }
}

def warn-copy-conflict [dest: string]: nothing -> nothing {
    print -e $"[ygg] Warning: 3-way sync conflict on '($dest)' \(both host and module modified\). Preserving host version. Run 'ygg apply --force' to take the module version or 'ygg save --force' to keep the host version."
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

# Read-only classification of a stale tracked copy: rm_unchanged_copy | backup_edited_copy | forget
def copy-prune-detail [dest: string, last_synced_hash: string]: nothing -> string {
    if (is-link-or-junction $dest) or (($dest | path type) != "file") {
        return "forget"
    }
    if ($last_synced_hash != "") and ((open --raw $dest | hash sha256) == $last_synced_hash) {
        "rm_unchanged_copy"
    } else {
        "backup_edited_copy"
    }
}

# Safely prune a tracked file copy: delete cleanly if unedited on host, otherwise backup
def prune-copy [ygg_home: string, dest: string, last_synced_hash: string]: nothing -> nothing {
    match (copy-prune-detail $dest $last_synced_hash) {
        "rm_unchanged_copy" => { rm -f $dest }
        "backup_edited_copy" => { backup-with-notice $ygg_home $dest | ignore }
        _ => { }
    }
}

# Read-only classification of a stale state.links entry: unlink | backup_dir_copy | rm_unchanged_copy |
# backup_edited_copy | forget (record only, nothing on disk is touched)
def link-prune-detail [state: record, dest: string, entry: record]: nothing -> string {
    if (is-link-or-junction $dest) {
        return "unlink"
    }
    let t = ($entry.type? | default "")
    if ($t == "dir_copy") and (($dest | path type) == "dir") {
        return "backup_dir_copy"
    }
    if ($t == "copy") {
        let last = (($state.copies | get -o $dest).last_synced_hash? | default "")
        return (copy-prune-detail $dest $last)
    }
    "forget"
}

# Print one diagnostic line per destination for cross-module overrides (RFC-010)
export def report-collisions [resolved: record]: nothing -> nothing {
    for c in ($resolved.collisions? | default [] | group-by dest | values | each { |g| $g | last }) {
        print -e $"[ygg] Collision: destination '($c.dest)' claimed by '($c.loser_module)' is overridden by '($c.winner_module)'"
    }
}

# Expand [save] targets with wildcard destinations into concrete files
def expand-save-targets [save_targets: list]: nothing -> list {
    $save_targets | each { |s|
        let matches = if (has-wildcard $s.dest) { glob ($s.dest | str replace --all '\' '/') } else { [$s.dest] }
        $matches | each { |d| $s | merge { dest: $d } }
    } | flatten
}

# Build the operation plan (RFC-011). Only reads the filesystem and state.
# Rows: PRUNE first (stale state.links / state.copies), then one row per resolved.targets entry
# (same order), then one row per expanded [save] destination.
export def compute-link-ops [
    ygg_home: string,
    resolved: record,
    --force,
    --sandbox: string = ""
]: nothing -> table<op: string, dest: string, src: string, module: string, key: string, detail: string> {
    let state = (load-state $ygg_home)
    let is_windows = (fs-windows)
    let sep = if ($nu.os-info.family == "windows") { "\\" } else { "/" }
    let targets = ($resolved.targets? | default [])
    let target_dests = ($targets | each { |t| $t.dest })
    let save_rows = (expand-save-targets ($resolved.save_targets? | default []))
    let copy_dests = ($targets | where { |t| $is_windows and not $t.is_dir } | each { |t| $t.dest }
        | append ($save_rows | each { |r| $r.dest }))
    let link_keys = ($state.links | columns)

    mut ops = []
    # 1. PRUNE rows (executed first)
    for d in $link_keys {
        if $d not-in $target_dests {
            let entry = ($state.links | get $d)
            $ops = ($ops | append {
                op: "PRUNE", dest: $d, src: ($entry.src? | default ""), module: ($entry.module? | default ""),
                key: "", detail: (link-prune-detail $state $d $entry)
            })
        }
    }
    for d in ($state.copies | columns) {
        # A copy record whose dest is still a link target is only forgotten (the link op handles the disk)
        if ($d not-in $copy_dests) and ($d not-in $target_dests) and ($d not-in $link_keys) {
            let entry = ($state.copies | get $d)
            $ops = ($ops | append {
                op: "PRUNE", dest: $d, src: ($entry.src? | default ""), module: ($entry.module? | default ""),
                key: "", detail: (copy-prune-detail $d ($entry.last_synced_hash? | default ""))
            })
        }
    }
    # Only PRUNE rows that actually remove the path from disk free its subtree; a "forget" row (e.g. the
    # app replaced a managed link with a real directory) leaves it, so children use the normal table
    let prune_prefixes = ($ops
        | where { |o| $o.detail in ["unlink", "backup_dir_copy", "rm_unchanged_copy", "backup_edited_copy"] }
        | each { |o| (normalize-case $o.dest) + $sep })

    # 2. Link targets
    for t in $targets {
        let dest = $t.dest
        let existing_type = (($state.links | get -o $dest).type? | default "")
        let ptype: any = ($dest | path type)
        let under_prune = ($prune_prefixes | any { |p| (normalize-case $dest) | str starts-with $p })
        let r = if $under_prune {
            # Parent link is pruned first: the path will not exist when this target is created
            if $is_windows and not $t.is_dir { { op: "COPY", detail: "seeded_host" } } else { { op: "LINK", detail: "" } }
        } else if ($existing_type == "dir_copy") and ($ptype == "dir") and not (is-link-or-junction $dest) and not (link-target-matches $dest $t.src) {
            { op: "OK", detail: "dir_copy preserved" }
        } else if $is_windows and not $t.is_dir {
            let tracked = ($dest in ($state.copies | columns))
            let differs = ((file-hash $dest) != (file-hash $t.src))
            if (is-link-or-junction $dest) or ($ptype == "dir") {
                { op: "BACKUP_REPLACE", detail: "copy" }
            } else if ($ptype == "file") and $differs and ((not $tracked) or $force) {
                { op: "BACKUP_REPLACE", detail: "copy" }
            } else {
                let p = (plan-copy-sync $state $t.module $t.src $dest $force)
                { op: $p.op, detail: $p.detail }
            }
        } else if (link-target-matches $dest $t.src) and ($dest | path exists) {
            { op: "OK", detail: "" }
        } else if (is-link-or-junction $dest) {
            { op: "RELINK", detail: "" }
        } else if ($ptype != null) {
            { op: "BACKUP_REPLACE", detail: "" }
        } else {
            { op: "LINK", detail: "" }
        }
        $ops = ($ops | append { op: $r.op, dest: $dest, src: $t.src, module: $t.module, key: $t.key, detail: $r.detail })
    }

    # 3. [save] targets
    for s in $save_rows {
        let p = (plan-copy-sync $state $s.module $s.src $s.dest $force)
        $ops = ($ops | append { op: $p.op, dest: $s.dest, src: $s.src, module: $s.module, key: $s.key, detail: $p.detail })
    }
    $ops
}

# Apply resolved links (RFC-010 priorities) from the operation plan (RFC-011): pre-flight barrier,
# PRUNE first, idempotent/atomic symlinks (RFC-009), Windows junction fallback (RFC-006), .cmd shims,
# 3-way copy sync. Per-link failures are collected in `failed` instead of aborting.
export def apply-links [
    ygg_home: string,
    plan: record,
    --dry-run,
    --force,
    --sandbox: string = ""
]: nothing -> record<applied: list<string>, pruned: list<string>, copies: list<string>, failed: list<record<dest: string, src: string, module: string, stderr: string>>> {
    mut state = (load-state $ygg_home)
    let is_windows = (fs-windows)
    let effective_sandbox = if ($sandbox != "") { $sandbox } else { ($env.YGG_SANDBOX? | default "") }

    let resolved = (resolve-link-targets $plan --sandbox $effective_sandbox)
    let ops = (compute-link-ops $ygg_home $resolved --force=$force --sandbox $effective_sandbox)

    # 0. Barrier before any host mutation (also in dry-run)
    let problems = (preflight-check $ygg_home $plan $resolved $ops --force=$force --sandbox $effective_sandbox)
    if ($problems | is-not-empty) {
        error make { msg: (format-preflight-errors $problems) }
    }
    report-collisions $resolved

    let prune_ops = ($ops | where op == "PRUNE")
    if $dry_run {
        return { applied: [], pruned: ($prune_ops | get -o dest | default []), copies: [], failed: [] }
    }

    mut applied_links = []
    mut synced_copies = []
    mut pruned_links = []
    mut failed = []

    # 1. PRUNE first, so a dir link -> glob transition does not trip over its own old link
    for o in $prune_ops {
        let dest = $o.dest
        let link_entry = ($state.links | get -o $dest)
        let err = (try {
            match $o.detail {
                "unlink" => { remove-link-only $dest }
                "rm_unchanged_copy" => { rm -f $dest }
                "backup_edited_copy" | "backup_dir_copy" => { backup-with-notice $ygg_home $dest | ignore }
                _ => { }
            }
            let shim = ($link_entry.cmd_shim? | default "")
            if ($shim != "") and ($shim | path exists) {
                try { remove-link-only $shim }
            }
            ""
        } catch { |e| $e.msg })
        if ($err != "") {
            $failed = ($failed | append { dest: $dest, src: $o.src, module: $o.module, stderr: $err })
            continue
        }
        if ($link_entry != null) {
            $state.links = ($state.links | reject $dest)
            $pruned_links = ($pruned_links | append $dest)
        }
        if ($dest in ($state.copies | columns)) {
            $state.copies = ($state.copies | reject $dest)
        }
    }

    # 2. Glob destination directories are real directories
    for d in ($resolved.targets | where { |t| $t.glob_dest_dir != "" } | get -o glob_dest_dir | default [] | uniq) {
        if (($d | path type) == null) {
            mkdir $d
        }
    }

    # 3. Link targets (rows follow the PRUNE rows in resolved.targets order)
    let target_ops = ($ops | where op != "PRUNE" | first ($resolved.targets | length))
    mut active_copies = []
    for pair in ($resolved.targets | zip $target_ops) {
        let tgt = $pair.0
        let row = $pair.1
        let dest = $tgt.dest
        let src_path = $tgt.src
        let mod_name = $tgt.module
        let op = $row.op

        if $is_windows and not $tgt.is_dir {
            # Single file on Windows: 3-way copy sync (a link or directory in the way is replaced first)
            $active_copies = ($active_copies | append $dest)
            let res = (try {
                if ($op == "BACKUP_REPLACE") {
                    if (is-link-or-junction $dest) {
                        remove-link-only $dest
                    } else {
                        backup-with-notice $ygg_home $dest | ignore
                    }
                }
                mkdir ($dest | path dirname)
                let cmd_shim = (write-cmd-shim $dest)
                let p = (plan-copy-sync $state $mod_name $src_path $dest $force)
                run-copy-sync $p
                if ($p.op == "CONFLICT") {
                    warn-copy-conflict $dest
                }
                { err: "", shim: $cmd_shim, copy_record: $p.copy_record }
            } catch { |e| { err: $e.msg, shim: "", copy_record: {} } })
            if ($res.err != "") {
                $failed = ($failed | append { dest: $dest, src: $src_path, module: $mod_name, stderr: $res.err })
                continue
            }
            $state.copies = ($state.copies | upsert $dest $res.copy_record)
            $state.links = ($state.links | upsert $dest { module: $mod_name, src: $src_path, type: "copy", cmd_shim: $res.shim })
            if ($op != "OK") {
                $applied_links = ($applied_links | append $dest)
            }
            continue
        }

        if ($op == "OK") {
            let existing_type = (($state.links | get -o $dest).type? | default "")
            let keep_type = if ($row.detail == "dir_copy preserved") {
                print -e $"[ygg] Warning: '($dest)' is a directory copy \(dir_copy\) and is not synchronized automatically."
                "dir_copy"
            } else if $is_windows and ($existing_type in ["junction", "symlink"]) {
                $existing_type
            } else if $is_windows {
                "junction"
            } else {
                "symlink"
            }
            $state.links = ($state.links | upsert $dest { module: $mod_name, src: $src_path, type: $keep_type, cmd_shim: "" })
        } else {
            let res = (try {
                if ($op == "BACKUP_REPLACE") {
                    if (is-link-or-junction $dest) {
                        remove-link-only $dest
                    } else {
                        backup-with-notice $ygg_home $dest | ignore
                    }
                }
                if $is_windows {
                    if ($op == "RELINK") {
                        remove-link-only $dest
                    }
                    mkdir ($dest | path dirname)
                    create-windows-dir-link $src_path $dest
                } else if ($op == "RELINK") {
                    swap-symlink-atomic $src_path $dest
                    { ok: true, type: "symlink", stderr: "" }
                } else {
                    mkdir ($dest | path dirname)
                    if (($dest | path type) != null) {
                        # Defensive: never let `ln -s` drop a link INSIDE an existing directory
                        { ok: false, type: "", stderr: $"destination '($dest)' exists; refusing to link into it" }
                    } else {
                        let r = (^ln -s $src_path $dest | complete)
                        { ok: ($r.exit_code == 0), type: "symlink", stderr: ($r.stderr | str trim) }
                    }
                }
            } catch { |e| { ok: false, type: "", stderr: $e.msg } })
            if not $res.ok {
                $failed = ($failed | append { dest: $dest, src: $src_path, module: $mod_name, stderr: $res.stderr })
                continue
            }
            $state.links = ($state.links | upsert $dest { module: $mod_name, src: $src_path, type: $res.type, cmd_shim: "" })
            $applied_links = ($applied_links | append $dest)
        }

        if not $is_windows and not $tgt.is_dir and (($dest | path dirname | path basename) == "bin") {
            ensure-executable $src_path
        }
    }

    # 4. [save] targets (3-way sync copy)
    let save_ops = ($ops | where op != "PRUNE" | skip ($resolved.targets | length))
    for row in $save_ops {
        let dest_file = $row.dest
        $active_copies = ($active_copies | append $dest_file)
        let res = (try {
            let p = (plan-copy-sync $state $row.module $row.src $dest_file $force)
            run-copy-sync $p
            if ($p.op == "CONFLICT") {
                warn-copy-conflict $dest_file
            }
            { err: "", copy_record: $p.copy_record }
        } catch { |e| { err: $e.msg, copy_record: {} } })
        if ($res.err != "") {
            $failed = ($failed | append { dest: $dest_file, src: $row.src, module: $row.module, stderr: $res.err })
            continue
        }
        $state.copies = ($state.copies | upsert $dest_file $res.copy_record)
        $synced_copies = ($synced_copies | append $dest_file)
    }

    # 5. Forget copy records that are no longer copies (e.g. a Windows file turned into a directory link)
    let failed_dests = ($failed | each { |f| $f.dest })
    for d in ($state.copies | columns) {
        if ($d not-in $active_copies) and ($d not-in $failed_dests) {
            $state.copies = ($state.copies | reject $d)
        }
    }

    save-state $ygg_home $state

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
            glob ($expanded_dest | str replace --all '\' '/')
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
                    backup-with-notice $ygg_home $dest | ignore
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

# Relative paths of all files (hidden included, symlinks excluded) below `dir`, sorted (RFC-021)
def relative-files [dir: string]: nothing -> list<string> {
    if not ($dir | path exists) {
        return []
    }
    glob --no-dir --no-symlink (($dir | path join "**" "*") | str replace --all '\' '/')
    | each { |f| $f | path relative-to $dir }
    | sort
}

# Files of host directory `dest` that a directory link to `src` would hide (only relative paths compared)
export def shadowed-files [dest: string, src: string]: nothing -> list<string> {
    let tracked = (relative-files $src)
    relative-files $dest | where { |f| $f not-in $tracked }
}

# RFC-055: whitelist of service managers
export const SERVICE_MANAGERS = ["systemd-user", "systemd-system", "launchd", "windows"]

# Flatten `[services]` into [{manager, data}] (`systemd` with action keys = systemd-user; `<top>.<sub>` = `<top>-<sub>`)
export def parse-services-tree [services: record]: nothing -> list<record> {
    mut configs = []
    for top_key in ($services | columns) {
        let top_val = ($services | get $top_key)
        if not (($top_val | describe) starts-with "record") {
            continue
        }
        let sub_cols = ($top_val | columns)
        let has_action_keys = ($sub_cols | any { |c| $c in ["enable", "reload_on_change", "restart_on_change"] })
        if $has_action_keys {
            let mgr = if $top_key == "systemd" { "systemd-user" } else { $top_key }
            $configs = ($configs | append { manager: $mgr, data: $top_val })
        } else {
            for sub_key in $sub_cols {
                let sub_val = ($top_val | get $sub_key)
                if (($sub_val | describe) starts-with "record") {
                    $configs = ($configs | append { manager: $"($top_key)-($sub_key)", data: $sub_val })
                }
            }
        }
    }
    $configs
}

# Pre-flight validation of the plan before any host mutation (RFC-020). Read-only.
# Reasons: missing_source, invalid_mode_source, nesting_conflict, ownership_conflict, shadowed_files.
# --force only lifts shadowed_files (RFC-021, with a warning); --quiet suppresses that warning.
export def preflight-check [
    ygg_home: string,
    plan: record,
    resolved: record = {},
    ops: table = [],
    --force,
    --quiet,
    --sandbox: string = ""
]: nothing -> list<record<module: string, key: string, reason: string, detail: string>> {
    mut problems = []

    # 0. Module dependencies (RFC-031): all declared depends_on modules must be in active plan
    let active_mods = ($plan | get -o modules | default [])
    let active_names = ($active_mods | each { |m| $m.name })
    for m in $active_mods {
        let manifest = ($m | get -o manifest)
        let deps = ($m | get -o depends_on | default (if $manifest != null { $manifest | get -o depends_on | default [] } else { [] }))
        for dep in $deps {
            if ($dep not-in $active_names) {
                $problems = ($problems | append {
                    module: $m.name,
                    key: "depends_on",
                    reason: "missing_dependency",
                    detail: $"Module '($m.name)' depends on '($dep)', but '($dep)' is not in active modules"
                })
            }
        }
    }

    # 0b. Secret providers (RFC-041): CLI required for secret schemes in secrets.toml must exist in PATH
    let sec_errs = (validate-secret-providers $ygg_home)
    for err in $sec_errs {
        $problems = ($problems | append {
            module: "secrets",
            key: "secrets.toml",
            reason: "missing_secret_provider",
            detail: $err
        })
    }

    # 1. Every link candidate of the effective plan (losing candidates too: RFC-020 p.2 "all links")
    for link in ($plan.links? | default []) {
        let src = $link.src_path
        let exists = if (has-wildcard $src) {
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
        } else if (($link.mode? | default "") == "dir") and (($src | path type) != "dir") {
            $problems = ($problems | append {
                module: $link.module,
                key: $link.key,
                reason: "invalid_mode_source",
                detail: $"mode = \"dir\" requires a directory source, but '($src)' is a ($src | path type)"
            })
        }
    }

    # 2. Nested link targets (RFC-010 p.4)
    for n in ($resolved.nesting_conflicts? | default []) {
        $problems = ($problems | append {
            module: $n.module,
            key: $n.key,
            reason: "nesting_conflict",
            detail: $"Shared directory ownership conflict: '($n.child_dest)' is inside directory link '($n.parent_dest)' \(($n.parent_module? | default ''): ($n.parent_key? | default '')\)"
        })
    }

    let targets = ($resolved.targets? | default [])
    let prune_norms = ($ops | where { |o| $o.op == "PRUNE" } | each { |o| normalize-case $o.dest })

    # 3. Glob destination directory must not be a foreign link/junction (own stale link is PRUNEd first)
    for g in ($targets | where { |t| $t.glob_dest_dir != "" } | group-by glob_dest_dir | values) {
        let first_t = ($g | first)
        let dir = $first_t.glob_dest_dir
        if (is-link-or-junction $dir) and ((normalize-case $dir) not-in $prune_norms) {
            $problems = ($problems | append {
                module: $first_t.module,
                key: $first_t.key,
                reason: "ownership_conflict",
                detail: $"Shared directory ownership conflict: target '($dir)' is a link/junction not managed by this run"
            })
        }
    }

    # 4. Directory shadowing (RFC-021): a directory link replacing a real host directory
    let replace_dests = ($ops | where { |o| $o.op == "BACKUP_REPLACE" } | each { |o| $o.dest })
    for t in ($targets | where { |t| $t.is_dir and ($t.dest in $replace_dests) }) {
        let dest = $t.dest
        if (($dest | path type) != "dir") or (is-link-or-junction $dest) {
            continue
        }
        let extra = (shadowed-files $dest $t.src)
        if ($extra | is-empty) {
            continue
        }
        let shown = ($extra | first 20 | each { |f| "      " + $f } | str join "\n")
        let more = if (($extra | length) > 20) { "\n      ... and " + ((($extra | length) - 20) | into string) + " more" } else { "" }
        let confirmed = ((($t.mode? | default "") == "dir") or $force)
        if not $confirmed {
            let glob_key = (($t.key | str trim -r -c "/") + "/*")
            $problems = ($problems | append {
                module: $t.module,
                key: $t.key,
                reason: "shadowed_files",
                detail: ($"directory '($dest)' has ($extra | length) file\(s\) not present in '($t.src)' that the link would hide:\n" + $shown + $more
                    + "\n    Resolve with one of:\n"
                    + $"      1. link entries individually: \"($glob_key)\" = \"<target>/*\" \(or per-file links\)\n"
                    + "      2. confirm the replacement in the manifest: mode = \"dir\"\n"
                    + "      3. run with --force (the directory is moved to .state/backups/)")
            })
        } else if not $quiet {
            print -e ($"[ygg] Warning: directory '($dest)' will be replaced by a link; ($extra | length) host file\(s\) not in the module move to .state/backups/:\n" + $shown + $more)
        }
    }

    # 5. [services] (RFC-055): manager whitelist and service-name charset
    let svc_tree = ($plan.services? | default {})
    if (($svc_tree | describe) starts-with "record") {
        for cfg in (parse-services-tree $svc_tree) {
            if $cfg.manager not-in $SERVICE_MANAGERS {
                $problems = ($problems | append {
                    module: "services", key: "services", reason: "invalid_service_manager",
                    detail: $"Unsupported service manager '($cfg.manager)' \(allowed: ($SERVICE_MANAGERS | str join ', ')\)"
                })
                continue
            }
            let en = ($cfg.data.enable? | default [])
            let en_list = if (($en | describe) starts-with "list") { $en } else { [$en] }
            mut names = $en_list
            for a in ["reload_on_change", "restart_on_change"] {
                let m = ($cfg.data | get -o $a | default {})
                if (($m | describe) starts-with "record") {
                    $names = ($names | append ($m | columns))
                }
            }
            for n in $names {
                if not (($n | into string) =~ '^[A-Za-z0-9@._:][A-Za-z0-9@._:-]*$') {
                    $problems = ($problems | append {
                        module: "services", key: "services", reason: "invalid_service_name",
                        detail: $"Invalid service name '($n)' for manager '($cfg.manager)'"
                    })
                }
            }
        }
    }

    # 6. Environment variable and alias names (RFC-056)
    let env_tree = ($plan.env? | default {})
    if (($env_tree | describe) starts-with "record") {
        for k in ($env_tree | columns) {
            if not ($k =~ '^[A-Za-z_][A-Za-z0-9_]*$') {
                $problems = ($problems | append {
                    module: "env", key: "env", reason: "invalid_env_name",
                    detail: $"Invalid environment variable name '($k)'"
                })
            }
        }
    }
    for k in (load-secrets-env $ygg_home | columns) {
        if not ($k =~ '^[A-Za-z_][A-Za-z0-9_]*$') {
            $problems = ($problems | append {
                module: "secrets", key: "env", reason: "invalid_env_name",
                detail: $"Invalid environment variable name '($k)' in secrets.toml"
            })
        }
    }
    let alias_tree = ($plan.aliases? | default {})
    if (($alias_tree | describe) starts-with "record") {
        for k in ($alias_tree | columns) {
            if not ($k =~ '^[A-Za-z_][A-Za-z0-9_.-]*$') {
                $problems = ($problems | append {
                    module: "aliases", key: "aliases", reason: "invalid_alias_name",
                    detail: $"Invalid alias name '($k)'"
                })
            }
        }
    }

    $problems
}

export def format-preflight-errors [problems: list<record>]: nothing -> string {
    let lines = ($problems | each { |p| $"  - [($p.module)] '($p.key)' \(($p.reason)\): ($p.detail)" })
    "Pre-flight check failed:\n" + ($lines | str join "\n")
}
