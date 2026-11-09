#!/usr/bin/env nu
# bin/ygg.nu — Yggdrasil CLI Router

use ../src *

const YGG_VERSION = "0.1.0"

# Print ygg version (with short git commit when run from a git checkout)
def "main version" [] {
    let root = ($env.FILE_PWD? | default "." | path dirname)
    let commit = (try {
        (^git -C $root rev-parse --short HEAD | complete).stdout | str trim
    } catch { "" })

    if ($commit != "") {
        print $"ygg ($YGG_VERSION) \(commit ($commit)\)"
    } else {
        print $"ygg ($YGG_VERSION)"
    }
}

def main [--version (-v)] {
    if $version {
        main version
        return
    }
    print "Yggdrasil (ygg) — Minimalist cross-platform modular configuration manager"
    print ""
    print "Usage:"
    print "  ygg init [name] [--os <os_list>]        Initialize a new module with ygg.toml and .gitignore"
    print "  ygg add <source> [--scope <scopes>] [--dry-run] [--force]  Add local directory or git repo and apply"
    print "      [--no-lock]"
    print "  ygg remove <name> [--no-lock]            Remove a module and unlink its files"
    print "  ygg apply [--dry-run] [--force] [--all]  Apply configurations, links, packages and setup"
    print "      [--pkg <m1,m2>] [--pkg-timeout <sec>] [--refresh-packages] [--skip-packages] [--no-lock] [--locked]"
    print "  ygg diff [--all] [--pkg <m1,m2>]         Show planned changes without modifying anything"
    print "  ygg update [--no-lock]                   Update git modules via rebase and apply"
    print "  ygg save [--no-lock]                     Save reverse-copied GUI/app edits back to modules"
    print "  ygg clean [--backups] [--hashes] [--dry-run] [--no-lock]  Clean old backups and orphaned state hashes"
    print "  ygg status [--json]                      Display module sync and git status table"
    print "  ygg doctor [--json]                      Read-only host audit (exit code 1 on errors)"
    print "  ygg version                              Print version (also --version / -v)"
    print ""
    print "SDK Subcommands (for setup.nu scripts):"
    print "  ygg onchange <key> <watch> <cmd>         Conditionally run command if watched files change"
    print "  ygg merge-json <fragment> <target>       Deep-merge JSON fragment into target file"
    print "  ygg export-secrets <dotenv>              Export selected secrets to environment dotenv"
    print "  ygg safe-link <src> <dest>               Link dest to src, backing up a real file/dir at dest"
}

# Initialize a new module in the current directory
def "main init" [
    name?: string,
    --os: string = "linux"
] {
    let mod_name = if ($name != null) and ($name != "") {
        $name
    } else {
        ($env.PWD | path basename)
    }

    let os_list = ($os | split row "," | each { |s| $s | str trim } | where { |s| $s != "" })
    let os_json = ($os_list | to json -r)

    let manifest_file = ($env.PWD | path join "ygg.toml")
    if not ($manifest_file | path exists) {
        let manifest_content = $"name = \"($mod_name)\"\nos = ($os_json)\ndescription = \"\"\n"
        $manifest_content | save -f $manifest_file
        print $"Created ($manifest_file)"
    } else {
        print $"Manifest already exists at ($manifest_file)"
    }

    let gitignore_file = ($env.PWD | path join ".gitignore")
    let default_ignore = "*local*\n*.db*\n*.sqlite*\n__pycache__/\nlogs/\n"
    if not ($gitignore_file | path exists) {
        $default_ignore | save -f $gitignore_file
        print $"Created ($gitignore_file)"
    } else {
        let existing = (open --raw $gitignore_file)
        mut to_append = []
        for pattern in ["*local*", "*.db*", "*.sqlite*", "__pycache__/", "logs/"] {
            if not ($existing | str contains $pattern) {
                $to_append = ($to_append | append $pattern)
            }
        }
        if ($to_append | is-not-empty) {
            $"\n($to_append | str join "\n")\n" | save --append $gitignore_file
        }
    }
}

# Add a module from local directory or git repo, and immediately apply
def "main add" [
    source: string,
    --scope (-s): string = "",
    --dry-run (-n),
    --force (-f),
    --skip-packages (-S),
    --pkg: string = "",
    --pkg-timeout: int = -1,
    --refresh-packages,
    --sandbox: string = "",
    --no-lock
] {
    assert-pkg-flags $pkg $skip_packages
    let effective_sandbox = if ($sandbox != "") { $sandbox } else { ($env.YGG_SANDBOX? | default "") }
    assert-sandbox-home $effective_sandbox

    let ygg_home = (get-ygg-home)
    ensure-ygg-dirs $ygg_home

    let lock_file = (acquire-host-lock $ygg_home "add" --no-lock=($no_lock or $dry_run))
    try {
        # Parse inline scope suffix, e.g. "repo@s1,s2"
        let parts = ($source | split row "@")
        let clean_source = ($parts | first)
        let inline_scopes = if ($parts | length) > 1 {
            ($parts | skip 1 | str join "@" | split row "," | each { |s| $s | str trim } | where { |s| $s != "" })
        } else {
            []
        }

        let flag_scopes = if ($scope != "") {
            ($scope | split row "," | each { |s| $s | str trim } | where { |s| $s != "" })
        } else {
            []
        }

        let all_scopes = ($inline_scopes | append $flag_scopes | uniq)

        # RFC-012: stage first (no change to modules/ or host.toml), check the plan with the module
        # as a virtual entry, and register only after pre-flight passed (RFC-020).
        let prep = (add-module $ygg_home $clean_source --scopes $all_scopes --dry-run --force=$force)
        let extra = [{ name: $prep.name, path: $prep.path, scopes: $all_scopes }]

        if $dry_run {
            try {
                apply-plan --dry-run --force=$force --skip-packages=$skip_packages --pkg=$pkg --pkg-timeout=$pkg_timeout --refresh-packages=$refresh_packages --sandbox=$effective_sandbox --extra-modules $extra
            } catch { |e|
                discard-staged-module $prep
                error make { msg: $e.msg }
            }
            discard-staged-module $prep
            release-host-lock $lock_file
            return
        }

        try {
            let plan = (resolve-effective-plan $ygg_home --extra-modules $extra)
            let resolved = (resolve-link-targets $plan --sandbox=$effective_sandbox)
            let ops = (compute-link-ops $ygg_home $resolved --force=$force --sandbox=$effective_sandbox)
            let problems = (preflight-check $ygg_home $plan $resolved $ops --force=$force --quiet --sandbox=$effective_sandbox)
            if ($problems | is-not-empty) {
                error make { msg: (format-preflight-errors $problems) }
            }
        } catch { |e|
            discard-staged-module $prep
            error make { msg: $e.msg }
        }

        let add_res = (register-staged-module $ygg_home $prep --force=$force)
        print $"Added module ($add_res.name)"

        apply-plan --force=$force --skip-packages=$skip_packages --pkg=$pkg --pkg-timeout=$pkg_timeout --refresh-packages=$refresh_packages --sandbox=$effective_sandbox
        release-host-lock $lock_file
    } catch { |e|
        release-host-lock $lock_file
        error make $e
    }
}

# RFC-013: manager selection and --skip-packages are mutually exclusive
def assert-pkg-flags [pkg: string, skip_packages: bool] {
    if ($pkg | str trim | is-not-empty) and $skip_packages {
        error make { msg: "--pkg cannot be combined with --skip-packages" }
    }
}

# Remove a module and unlink its managed files
def "main remove" [
    name: string,
    --no-lock
] {
    let ygg_home = (get-ygg-home)
    ensure-ygg-dirs $ygg_home
    let lock_file = (acquire-host-lock $ygg_home "remove" --no-lock=$no_lock)
    try {
        remove-module $ygg_home $name
        print $"Removed module ($name)"
        release-host-lock $lock_file
    } catch { |e|
        release-host-lock $lock_file
        error make $e
    }
}

# Print one planned operation line: "  <OP>  <dest>  (<module>: <key>) <detail>"
def print-op-line [o: record] {
    let owner = if ($o.key != "") { $o.module + ": " + $o.key } else { $o.module }
    let detail = if ($o.detail != "") { " " + $o.detail } else { "" }
    print ("  " + ($o.op | fill --alignment left --width 15) + " " + $o.dest + "  (" + $owner + ")" + $detail)
}

# Apply configurations, links, packages and setup across all modules
def "main apply" [
    --dry-run (-n),
    --force (-f),
    --all (-a),
    --skip-packages (-S),
    --pkg: string = "",
    --pkg-timeout: int = -1,
    --refresh-packages,
    --sandbox: string = "",
    --no-lock,
    --locked
] {
    let effective_sandbox = if ($sandbox != "") { $sandbox } else { ($env.YGG_SANDBOX? | default "") }
    assert-sandbox-home $effective_sandbox

    let ygg_home = (get-ygg-home)
    ensure-ygg-dirs $ygg_home

    let lock_file = (acquire-host-lock $ygg_home "apply" --no-lock=($no_lock or $dry_run))
    try {
        apply-plan --dry-run=$dry_run --force=$force --all=$all --skip-packages=$skip_packages --pkg=$pkg --pkg-timeout=$pkg_timeout --refresh-packages=$refresh_packages --sandbox=$sandbox --locked=$locked
        release-host-lock $lock_file
    } catch { |e|
        release-host-lock $lock_file
        error make $e
    }
}

# Apply pipeline shared by `apply`, `diff` and `add` (--extra-modules: virtual modules, RFC-012)
def apply-plan [
    --dry-run,
    --force,
    --all,
    --skip-packages,
    --pkg: string = "",
    --pkg-timeout: int = -1,
    --refresh-packages,
    --sandbox: string = "",
    --extra-modules: list<record> = [],
    --locked
] {
    assert-pkg-flags $pkg $skip_packages
    let effective_sandbox = if ($sandbox != "") {
        $sandbox
    } else {
        ($env.YGG_SANDBOX? | default "")
    }
    assert-sandbox-home $effective_sandbox

    let ygg_home = (get-ygg-home)
    ensure-ygg-dirs $ygg_home

    let plan = (resolve-effective-plan $ygg_home --extra-modules $extra_modules)

    if $locked {
        let lock_errors = (verify-ygg-lock $ygg_home $plan)
        if ($lock_errors | is-not-empty) {
            error make { msg: ($lock_errors | str join "; ") }
        }
    }

    let state = (load-state $ygg_home)
    let plan_mods = ($plan.modules? | default [])
    let state_links = ($state.links? | default {})
    if ($plan_mods | is-empty) and ($state_links | columns | is-not-empty) and (not $force) {
        error make { msg: "Plan contains 0 modules but active links exist. Refusing to prune all links without --force." }
    }

    # 0. Pre-flight barrier (RFC-020): before package managers and before any link change.
    # On a real run the shadowing warning is printed later by apply-links.
    let resolved = (resolve-link-targets $plan --sandbox=$effective_sandbox)
    let ops = (compute-link-ops $ygg_home $resolved --force=$force --sandbox=$effective_sandbox)
    let problems = (preflight-check $ygg_home $plan $resolved $ops --force=$force --quiet=(not $dry_run) --sandbox=$effective_sandbox)
    if ($problems | is-not-empty) {
        error make { msg: (format-preflight-errors $problems) }
    }

    let mod_count = ($plan_mods | length)

    # Check pending journal before starting mutations (RFC-027)
    let pending_journal = (check-pending-journal $ygg_home)
    if ($pending_journal.incomplete? | default false) {
        print -e $"[ygg] Warning: Interrupted transaction detected in .state/journal.json \(started ($pending_journal.timestamp? | default 'unknown')\). Resuming operation."
    }

    if $dry_run {
        # RFC-011: plan only, nothing on the host changes
        report-collisions $resolved
        let pkg_res = (install-packages $ygg_home $plan --dry-run --skip-packages=$skip_packages --pkg=$pkg --pkg-timeout=$pkg_timeout --refresh-packages=$refresh_packages --sandbox=$effective_sandbox)
        for o in $ops {
            if $all or ($o.op != "OK") {
                print-op-line $o
            }
        }
        for cmd in $pkg_res.executed {
            print ("  " + ("PKG" | fill --alignment left --width 15) + " " + $cmd)
        }
        for mgr in $pkg_res.skipped {
            print ("  " + ("PKG" | fill --alignment left --width 15) + " " + $mgr + " SKIP (cached)")
        }
        compile-environment $ygg_home $plan --dry-run --force=$force --sandbox=$effective_sandbox | ignore
        for mod_entry in $plan_mods {
            let mod_dir = ($mod_entry.dir? | default ($ygg_home | path join "modules" ($mod_entry.name? | default "")))
            if ($mod_dir | path join "setup.nu" | path exists) {
                print ("  " + ("SETUP" | fill --alignment left --width 15) + " " + ($mod_entry.name? | default "") + "  (YGG_DRY_RUN=true)")
            }
            run-module-setup $ygg_home $mod_entry --dry-run --force=$force --sandbox=$effective_sandbox
        }
        let hooks = (run-link-hooks $ygg_home $resolved.targets $ops --dry-run --force=$force --sandbox=$effective_sandbox)
        for h in $hooks {
            print ("  " + ("HOOK" | fill --alignment left --width 15) + " " + $h.cmd + "  (" + $h.module + ": " + ($h.keys | str join ", ") + ")")
        }
        run-service-actions $ygg_home $plan $ops --dry-run | ignore
        let changes = (($ops | where op != "OK" | length) + ($pkg_res.executed | length))
        let unchanged = ($ops | where op == "OK" | length)
        print $"Plan: ($changes) change\(s\), ($unchanged) unchanged across ($mod_count) module\(s\). No changes made."
        return
    }

    # Begin WAL transaction (RFC-027)
    begin-journal-transaction $ygg_home $plan

    # 1. Install packages
    record-journal-step $ygg_home "packages" "IN_PROGRESS"
    let pkg_res = (install-packages $ygg_home $plan --skip-packages=$skip_packages --pkg=$pkg --pkg-timeout=$pkg_timeout --refresh-packages=$refresh_packages --sandbox=$effective_sandbox)
    record-journal-step $ygg_home "packages" "COMMITTED"

    # 2. Deploy links and file copies (PRUNE first; per-link failures are collected)
    record-journal-step $ygg_home "links" "IN_PROGRESS"
    let link_res = (apply-links $ygg_home $plan --force=$force --sandbox=$effective_sandbox)
    record-journal-step $ygg_home "links" "COMMITTED"

    # 3. Compile shell environments and aliases
    record-journal-step $ygg_home "env" "IN_PROGRESS"
    compile-environment $ygg_home $plan --force=$force --sandbox=$effective_sandbox | ignore
    record-journal-step $ygg_home "env" "COMMITTED"

    # 4. Run module procedural setup scripts
    record-journal-step $ygg_home "setup" "IN_PROGRESS"
    for mod_entry in $plan_mods {
        run-module-setup $ygg_home $mod_entry --force=$force --sandbox=$effective_sandbox
    }
    record-journal-step $ygg_home "setup" "COMMITTED"

    # 5. on_change hooks of links (RFC-015): last step; a failing hook only warns
    record-journal-step $ygg_home "hooks" "IN_PROGRESS"
    run-link-hooks $ygg_home $resolved.targets $ops --force=$force --sandbox=$effective_sandbox | ignore
    record-journal-step $ygg_home "hooks" "COMMITTED"

    # Declarative services management (RFC-037)
    run-service-actions $ygg_home $plan $ops | ignore

    print $"Applied ($mod_count) module\(s\)."

    for f in $link_res.failed {
        print -e $"[ygg] Error: failed to link '($f.dest)' -> '($f.src)' \(($f.module)\): ($f.stderr)"
    }

    mut errors = []
    if ($pkg_res.failed | is-not-empty) {
        let failed_pkgs = ($pkg_res.failed | each { |f| $f.mgr + ": " + $f.pkg + " (" + $f.reason + ")" } | str join ", ")
        $errors = ($errors | append ("Package installation failed for: " + $failed_pkgs))
    }
    if ($link_res.failed | is-not-empty) {
        $errors = ($errors | append $"($link_res.failed | length) link\(s\) failed: ($link_res.failed | get dest | str join ', ')")
    }
    if ($errors | is-not-empty) {
        error make { msg: ($errors | str join "; ") }
    }

    # Rotate old backups and garbage collect orphaned hashes (RFC-028)
    let host_cfg = (try { load-host-config $ygg_home } catch { {} })
    let max_count = ($host_cfg | get -o ygg.backups.max_count | default 20)
    let max_age_days = ($host_cfg | get -o ygg.backups.max_age_days | default 30)
    rotate-backups $ygg_home --max-count=$max_count --max-age-days=$max_age_days | ignore

    let active_keys = (collect-active-hash-keys $plan)
    gc-state-hashes $ygg_home $active_keys | ignore

    # Generate or update ygg.lock (RFC-032)
    generate-ygg-lock $ygg_home $plan | ignore

    # Commit WAL transaction on clean completion (RFC-027)
    commit-journal-transaction $ygg_home
}

# Show planned changes across all modules without modifying the filesystem
def "main diff" [
    --all (-a),
    --skip-packages (-S),
    --pkg: string = "",
    --refresh-packages,
    --sandbox: string = ""
] {
    main apply --dry-run --all=$all --skip-packages=$skip_packages --pkg=$pkg --refresh-packages=$refresh_packages --sandbox=$sandbox
}

# Update git modules via rebase and apply if clean
def "main update" [--no-lock] {
    let ygg_home = (get-ygg-home)
    ensure-ygg-dirs $ygg_home

    let lock_file = (acquire-host-lock $ygg_home "update" --no-lock=$no_lock)
    try {
        let results = (update-modules $ygg_home)
        let conflicts = ($results | where status == "conflict")
        if ($conflicts | is-not-empty) {
            let names = ($conflicts | get name | str join ", ")
            print -e $"Update encountered conflicts in: ($names). Skipping apply."
            release-host-lock $lock_file
            return $results
        }

        apply-plan
        release-host-lock $lock_file
    } catch { |e|
        release-host-lock $lock_file
        error make $e
    }
}

# Save reverse-copied files back to their source modules
def "main save" [
    --sandbox: string = "",
    --force,
    --no-lock
] {
    let effective_sandbox = if ($sandbox != "") { $sandbox } else { ($env.YGG_SANDBOX? | default "") }
    assert-sandbox-home $effective_sandbox

    let ygg_home = (get-ygg-home)
    ensure-ygg-dirs $ygg_home

    let lock_file = (acquire-host-lock $ygg_home "save" --no-lock=$no_lock)
    try {
        let plan = (resolve-effective-plan $ygg_home)
        let saved = (save-copied-files $ygg_home $plan --sandbox=$effective_sandbox --force=$force)
        print $"Saved ($saved | length) file\(s\)."
        release-host-lock $lock_file
        $saved
    } catch { |e|
        release-host-lock $lock_file
        error make $e
    }
}

# Clean old backups and orphaned state hashes (RFC-028)
def "main clean" [
    --backups,
    --hashes,
    --dry-run,
    --no-lock
] {
    let ygg_home = (get-ygg-home)
    ensure-ygg-dirs $ygg_home

    let do_backups = $backups or (not $hashes)
    let do_hashes = $hashes or (not $backups)

    let lock_file = (acquire-host-lock $ygg_home "clean" --no-lock=($no_lock or $dry_run))
    try {
        let host_cfg = (try { load-host-config $ygg_home } catch { {} })
        let max_count = ($host_cfg | get -o ygg.backups.max_count | default 20)
        let max_age_days = ($host_cfg | get -o ygg.backups.max_age_days | default 30)

        if $do_backups {
            let removed = (rotate-backups $ygg_home --max-count=$max_count --max-age-days=$max_age_days --dry-run=$dry_run)
            if $dry_run {
                print $"Would remove ($removed | length) old backup\(s\)."
            } else {
                print $"Cleaned ($removed | length) old backup\(s\)."
            }
        }

        if $do_hashes {
            let plan = (resolve-effective-plan $ygg_home)
            let active_keys = (collect-active-hash-keys $plan)
            let purged = (gc-state-hashes $ygg_home $active_keys --dry-run=$dry_run)
            if $dry_run {
                print $"Would purge ($purged) orphan hash\(es\)."
            } else {
                print $"Purged ($purged) orphan hash\(es\)."
            }
        }

        release-host-lock $lock_file
    } catch { |e|
        release-host-lock $lock_file
        error make $e
    }
}

# Display module sync and git status table (--json: all columns as JSON, independent of terminal width)
def "main status" [--json] {
    let ygg_home = (get-ygg-home)
    ensure-ygg-dirs $ygg_home
    let rows = (modules-status $ygg_home)
    if $json {
        print ($rows | to json --raw)
    } else {
        $rows
    }
}

# Read-only host audit (RFC-017): prints findings and a summary; exit code 1 when any error is found
def "main doctor" [--json, --sandbox: string = ""] {
    let effective_sandbox = if ($sandbox != "") { $sandbox } else { ($env.YGG_SANDBOX? | default "") }
    assert-sandbox-home $effective_sandbox
    let ygg_home = (get-ygg-home)
    let report = (run-doctor $ygg_home --sandbox=$effective_sandbox)
    let errors = ($report | where { |r| $r.severity == "error" } | length)
    if $json {
        print ($report | to json --raw)
    } else {
        if ($report | is-not-empty) {
            print ($report | table --expand)
        }
        let warns = ($report | where { |r| $r.severity == "warn" } | length)
        print $"Doctor: ($errors) error\(s\), ($warns) warning\(s\)."
    }
    if $errors > 0 {
        exit 1
    }
}

# Conditionally execute command if watched files change (SDK helper)
def "main onchange" [
    key: string,
    watch: string,
    cmd: string,
    --target: string = ""
] {
    let globs = ($watch | split row "," | each { |g| $g | str trim } | where { |g| $g != "" })
    onchange $key $globs { ^nu -c $cmd } --target=$target
}

# Deep-merge JSON fragment into destination JSON file (SDK helper)
def "main merge-json" [
    src_fragment: string,
    dest_json: string,
    --mode: string = "0600"
] {
    merge-json $src_fragment $dest_json --mode=$mode
}

# Export selected secrets to destination dotenv file (SDK helper)
def "main export-secrets" [
    dest_dotenv: string,
    --keys: string = ""
] {
    let key_list = if ($keys != "") {
        ($keys | split row "," | each { |k| $k | str trim } | where { |k| $k != "" })
    } else {
        []
    }
    export-secrets $dest_dotenv --keys=$key_list
}

# Idempotent link with backup of a real file/directory at dest (SDK helper, RFC-023)
def "main safe-link" [src: string, dest: string] {
    safe-link $src $dest
}
