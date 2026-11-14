#!/usr/bin/env nu
# bin/ygg.nu — Yggdrasil CLI Router

use ../src *

const YGG_VERSION = "0.1.1"

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

def main [
    --version (-v) # Print version
] {
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
    print "      [--pkg <m1,m2>] [--pkg-timeout <sec>] [--refresh-packages] [--skip-packages] [--prune-packages] [--force-system-prune] [--no-lock] [--locked]"
    print "  ygg diff [--all] [--pkg <m1,m2>]         Show planned changes without modifying anything"
    print "  ygg update [--no-lock]                   Update git modules via rebase and apply"
    print "  ygg save [--no-lock]                     Save reverse-copied GUI/app edits back to modules"
    print "  ygg clean [--backups] [--hashes] [--dry-run] [--no-lock]  Clean old backups and orphaned state hashes"
    print "  ygg status [--json]                      Display module sync and git status table"
    print "  ygg doctor [--json] [--fix] [-y]         Host audit & self-healing (exit code 1 on errors)"
    print "  ygg completions <shell>                  Generate shell completions (nu, zsh, bash, fish, ps1)"
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
    --os: string = "linux" # Comma-separated target OS list for the new module (default: linux)
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
    source: string, # Local directory or git URL of the module (optionally with @scope1,scope2 suffix)
    --scope (-s): string = "", # Comma-separated scopes to activate for the module
    --dry-run (-n), # Show the plan without modifying anything
    --force (-f), # Overwrite conflicting files and links (with backup)
    --skip-packages (-S), # Skip package installation
    --pkg: string = "", # Comma-separated package managers to run
    --pkg-timeout: int = -1, # Package manager timeout in seconds
    --refresh-packages, # Reinstall packages even if their hash is unchanged
    --sandbox: string = "", # Use this directory as HOME instead of the real one
    --no-lock # Do not take the host lock
] {
    assert-pkg-flags $pkg $skip_packages
    let effective_sandbox = if ($sandbox != "") { $sandbox } else { ($env.YGG_SANDBOX? | default "") }
    assert-sandbox-home $effective_sandbox

    let ygg_home = (get-ygg-home)
    if not $dry_run {
        ensure-ygg-dirs $ygg_home
    }

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
        let prep = (add-module $ygg_home $clean_source --scopes $all_scopes --dry-run --read-only=$dry_run --force=$force)
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
    name: string, # Module name
    --no-lock # Do not take the host lock
] {
    assert-sandbox-home ($env.YGG_SANDBOX? | default "")
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
    --dry-run (-n), # Show the plan without modifying anything
    --force (-f), # Overwrite conflicting files and links (with backup)
    --all (-a), # List unchanged operations too in the dry-run output
    --skip-packages (-S), # Skip package installation
    --pkg: string = "", # Comma-separated package managers to run
    --pkg-timeout: int = -1, # Package manager timeout in seconds
    --refresh-packages, # Reinstall packages even if their hash is unchanged
    --sandbox: string = "", # Use this directory as HOME instead of the real one
    --no-lock, # Do not take the host lock
    --locked, # Fail if modules do not match the lock file
    --prune-packages, # Remove packages no longer declared by any module
    --force-system-prune # Allow pruning of system-level packages
] {
    let effective_sandbox = if ($sandbox != "") { $sandbox } else { ($env.YGG_SANDBOX? | default "") }
    assert-sandbox-home $effective_sandbox

    let ygg_home = (get-ygg-home)
    if not $dry_run {
        ensure-ygg-dirs $ygg_home
    }

    let lock_file = (acquire-host-lock $ygg_home "apply" --no-lock=($no_lock or $dry_run))
    try {
        apply-plan --dry-run=$dry_run --force=$force --all=$all --skip-packages=$skip_packages --pkg=$pkg --pkg-timeout=$pkg_timeout --refresh-packages=$refresh_packages --sandbox=$sandbox --locked=$locked --prune-packages=$prune_packages --force-system-prune=$force_system_prune
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
    --locked,
    --prune-packages,
    --force-system-prune
] {
    assert-pkg-flags $pkg $skip_packages
    let effective_sandbox = if ($sandbox != "") {
        $sandbox
    } else {
        ($env.YGG_SANDBOX? | default "")
    }
    assert-sandbox-home $effective_sandbox

    let ygg_home = (get-ygg-home)
    if not $dry_run {
        ensure-ygg-dirs $ygg_home
    }

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

    mut effective_refresh_packages = $refresh_packages
    # Check pending journal before starting mutations (RFC-043)
    let pending_journal = (check-pending-journal $ygg_home)
    if $pending_journal.state in ["interrupted", "failed"] {
        let rec_step = (if ($pending_journal.failed_step | is-empty) { "unknown" } else { $pending_journal.failed_step })
        if $dry_run {
            print -e $"[ygg] Would recover: previous apply ($pending_journal.state) at step '($rec_step)'; would re-run the full pipeline."
        } else {
            print -e $"[ygg] Recovering: previous apply ($pending_journal.state) at step '($rec_step)'; re-running full pipeline."
        }
        let packages_committed = (($pending_journal.steps?.packages? | default "") == "COMMITTED")
        if not $packages_committed {
            $effective_refresh_packages = true
        }
    }

    if $dry_run {
        # RFC-011: plan only, nothing on the host changes
        report-collisions $resolved
        mut pruned_cmds: list<string> = []
        if $prune_packages {
            let res = (prune-unused-packages $ygg_home $plan --dry-run --force-system-prune=$force_system_prune --pkg=$pkg --sandbox=$effective_sandbox)
            $pruned_cmds = $res.executed
        }
        let pkg_res = (install-packages $ygg_home $plan --dry-run --skip-packages=$skip_packages --pkg=$pkg --pkg-timeout=$pkg_timeout --refresh-packages=$effective_refresh_packages --sandbox=$effective_sandbox)
        for o in $ops {
            if $all or ($o.op != "OK") {
                print-op-line $o
            }
        }
        for cmd in $pruned_cmds {
            print ("  " + ("PRUNE" | fill --alignment left --width 15) + " " + $cmd)
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
            let is_safe = ($mod_entry.manifest?.setup?.dry_run_safe?
                | default ($mod_entry.setup?.dry_run_safe?
                | default ($mod_entry.dry_run_safe? | default false)))
            if ($mod_dir | path join "setup.nu" | path exists) and $is_safe {
                print ("  " + ("SETUP" | fill --alignment left --width 15) + " " + ($mod_entry.name? | default "") + "  (YGG_DRY_RUN=true)")
            }
            run-module-setup $ygg_home $mod_entry --dry-run --force=$force --sandbox=$effective_sandbox
        }
        let hooks = (run-link-hooks $ygg_home $resolved.targets $ops --dry-run --force=$force --sandbox=$effective_sandbox)
        for h in $hooks {
            print ("  " + ("HOOK" | fill --alignment left --width 15) + " " + $h.cmd + "  (" + $h.module + ": " + ($h.keys | str join ", ") + ")")
        }
        run-service-actions $ygg_home $plan $ops --dry-run --force=$force --sandbox=$effective_sandbox | ignore
        let changes = (($ops | where op != "OK" | length) + ($pkg_res.executed | length) + ($pruned_cmds | length))
        let unchanged = ($ops | where op == "OK" | length)
        print $"Plan: ($changes) change\(s\), ($unchanged) unchanged across ($mod_count) module\(s\). No changes made."
        return
    }

    # Begin WAL transaction (RFC-043)
    begin-journal-transaction $ygg_home $plan

    try {
        # 1. Prune unused packages if requested (RFC-030 / RFC-043)
        record-journal-step $ygg_home "prune_packages" "IN_PROGRESS"
        mut prune_res = { executed: [], failed: [], skipped: [] }
        if $prune_packages {
            $prune_res = (prune-unused-packages $ygg_home $plan --force-system-prune=$force_system_prune --pkg=$pkg --sandbox=$effective_sandbox)
        }
        if ($prune_res.failed | is-not-empty) {
            record-journal-step $ygg_home "prune_packages" "FAILED"
        } else {
            record-journal-step $ygg_home "prune_packages" "COMMITTED"
        }

        # 2. Install packages
        record-journal-step $ygg_home "packages" "IN_PROGRESS"
        let pkg_res = (install-packages $ygg_home $plan --skip-packages=$skip_packages --pkg=$pkg --pkg-timeout=$pkg_timeout --refresh-packages=$effective_refresh_packages --sandbox=$effective_sandbox)
        if ($pkg_res.failed | is-not-empty) {
            record-journal-step $ygg_home "packages" "FAILED"
        } else {
            record-journal-step $ygg_home "packages" "COMMITTED"
        }

        # 3. Deploy links and file copies (PRUNE first; per-link failures are collected)
        record-journal-step $ygg_home "links" "IN_PROGRESS"
        let link_res = (apply-links $ygg_home $plan --force=$force --sandbox=$effective_sandbox)
        if ($link_res.failed | is-not-empty) {
            record-journal-step $ygg_home "links" "FAILED"
        } else {
            record-journal-step $ygg_home "links" "COMMITTED"
        }

        # 4. Compile shell environments and aliases
        record-journal-step $ygg_home "env" "IN_PROGRESS"
        compile-environment $ygg_home $plan --force=$force --sandbox=$effective_sandbox | ignore
        record-journal-step $ygg_home "env" "COMMITTED"

        # 5. Run module procedural setup scripts
        record-journal-step $ygg_home "setup" "IN_PROGRESS"
        for mod_entry in $plan_mods {
            run-module-setup $ygg_home $mod_entry --force=$force --sandbox=$effective_sandbox
        }
        record-journal-step $ygg_home "setup" "COMMITTED"

        # on_change hooks of links (RFC-015): last step; a failing hook only warns
        run-link-hooks $ygg_home $resolved.targets $ops --force=$force --sandbox=$effective_sandbox | ignore

        # 6. Declarative services management (RFC-037 / RFC-043)
        record-journal-step $ygg_home "services" "IN_PROGRESS"
        let svc_res = (run-service-actions $ygg_home $plan $ops --force=$force --sandbox=$effective_sandbox)
        let svc_failed = ($svc_res | where status == "failed")
        if ($svc_failed | is-not-empty) {
            record-journal-step $ygg_home "services" "FAILED"
        } else {
            record-journal-step $ygg_home "services" "COMMITTED"
        }

        print $"Applied ($mod_count) module\(s\)."

        for f in $link_res.failed {
            print -e $"[ygg] Error: failed to link '($f.dest)' -> '($f.src)' \(($f.module)\): ($f.stderr)"
        }

        mut errors = []
        if ($prune_res.failed | is-not-empty) {
            let failed_pkgs = ($prune_res.failed | str join ", ")
            $errors = ($errors | append ("Package pruning failed for: " + $failed_pkgs))
        }
        if ($pkg_res.failed | is-not-empty) {
            let failed_pkgs = ($pkg_res.failed | each { |f| $f.mgr + ": " + $f.pkg + " (" + $f.reason + ")" } | str join ", ")
            $errors = ($errors | append ("Package installation failed for: " + $failed_pkgs))
        }
        if ($link_res.failed | is-not-empty) {
            $errors = ($errors | append $"($link_res.failed | length) link\(s\) failed: ($link_res.failed | get dest | str join ', ')")
        }
        if ($svc_failed | is-not-empty) {
            $errors = ($errors | append ("Service actions failed: " + ($svc_failed | each { |f| $f.manager + ": " + $f.action + " " + $f.service + " (" + $f.stderr + ")" } | str join ", ")))
        }
        if ($errors | is-not-empty) {
            error make { msg: ($errors | str join "; ") }
        }

        # 7. Finalize (RFC-043)
        record-journal-step $ygg_home "finalize" "IN_PROGRESS"
        # Rotate old backups and garbage collect orphaned hashes (RFC-028)
        let host_cfg = (try { load-host-config $ygg_home } catch { {} })
        let max_count = ($host_cfg | get -o ygg.backups.max_count | default 20)
        let max_age_days = ($host_cfg | get -o ygg.backups.max_age_days | default 30)
        rotate-backups $ygg_home --max-count=$max_count --max-age-days=$max_age_days | ignore

        let active_keys = (collect-active-hash-keys $plan)
        let active_modules = ($plan.modules? | default [] | each { |m| $m.name })
        gc-state-hashes $ygg_home $active_keys $active_modules | ignore

        # Generate or update ygg.lock (RFC-032)
        generate-ygg-lock $ygg_home $plan | ignore
        record-journal-step $ygg_home "finalize" "COMMITTED"

        # Commit WAL transaction on clean completion (RFC-043)
        commit-journal-transaction $ygg_home
    } catch { |e|
        fail-journal-transaction $ygg_home ($e.msg? | default ($e | to text))
        error make $e
    }
}

# Show planned changes across all modules without modifying the filesystem
def "main diff" [
    --all (-a), # List unchanged operations too in the dry-run output
    --skip-packages (-S), # Skip package installation
    --pkg: string = "", # Comma-separated package managers to inspect
    --refresh-packages, # Ignore cached package hashes
    --sandbox: string = "" # Use this directory as HOME instead of the real one
] {
    main apply --dry-run --all=$all --skip-packages=$skip_packages --pkg=$pkg --refresh-packages=$refresh_packages --sandbox=$sandbox
}

# Update git modules via rebase and apply if clean
def "main update" [
    --no-lock # Do not take the host lock
] {
    let ygg_home = (get-ygg-home)
    ensure-ygg-dirs $ygg_home

    let lock_file = (acquire-host-lock $ygg_home "update" --no-lock=$no_lock)
    try {
        let results = (update-modules $ygg_home)
        let failed = ($results | where { |r| $r.status in ["conflict", "error"] })
        if ($failed | is-not-empty) {
            let names = ($failed | get name | str join ", ")
            print -e $"Update failed in: ($names). Skipping apply."
            print ($results | select name status message? | table)
            release-host-lock $lock_file
            exit 1
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
    --sandbox: string = "", # Use this directory as HOME instead of the real one
    --force, # Overwrite the module copy with the host version on conflict
    --no-lock # Do not take the host lock
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
    --backups, # Clean only old backups
    --hashes, # Clean only orphaned state hashes
    --dry-run, # Show what would be removed without deleting
    --no-lock # Do not take the host lock
] {
    let ygg_home = (get-ygg-home)
    if not $dry_run {
        ensure-ygg-dirs $ygg_home
    }

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
            let active_modules = ($plan.modules? | default [] | each { |m| $m.name })
            let purged = (gc-state-hashes $ygg_home $active_keys $active_modules --dry-run=$dry_run)
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
def "main status" [
    --json # Print the table as JSON
] {
    let ygg_home = (get-ygg-home)
    let rows = (modules-status $ygg_home)
    if $json {
        print ($rows | to json --raw)
    } else {
        $rows
    }
}

# Host audit (RFC-017) & self-healing (RFC-038): prints findings and a summary; exit code 1 when any error remains
def "main doctor" [
    --json, # Print findings as JSON
    --fix, # Repair fixable findings
    --yes (-y), # Confirm fixes without prompting
    --sandbox: string = "" # Use this directory as HOME instead of the real one
] {
    let effective_sandbox = if ($sandbox != "") { $sandbox } else { ($env.YGG_SANDBOX? | default "") }
    assert-sandbox-home $effective_sandbox
    let ygg_home = (get-ygg-home)
    mut report = (run-doctor $ygg_home --sandbox=$effective_sandbox)

    mut fixed_findings = []
    if $fix {
        let fixable = ($report | where { |r| ($r.check in ["perm", "state_orphan"]) or (($r.check == "orphan_link") and ($r.owned? | default false)) })
        if ($fixable | is-not-empty) {
            let confirmed = if $yes {
                true
            } else {
                if not $json {
                    print $"Doctor --fix: found (($fixable | length)) fixable finding\(s\)."
                }
                let answer = (try { input "Apply automatic fixes? [y/N]: " } catch { "n" })
                ($answer | str trim | str lowercase) in ["y", "yes"]
            }
            if $confirmed {
                let lock_file = (acquire-host-lock $ygg_home "doctor-fix")
                try {
                    # Re-audit under the lock so that the fix sees the current state
                    let fresh = (run-doctor $ygg_home --sandbox=$effective_sandbox)
                    $fixed_findings = (doctor-fix $ygg_home ($fresh | where { |r| ($r.check in ["perm", "state_orphan"]) or (($r.check == "orphan_link") and ($r.owned? | default false)) }) --sandbox=$effective_sandbox)
                    $report = (run-doctor $ygg_home --sandbox=$effective_sandbox)
                } catch { |e|
                    release-host-lock $lock_file
                    error make { msg: $e.msg }
                }
                release-host-lock $lock_file
            } else if not $json {
                print "Doctor --fix aborted by user."
            }
        }
    }

    let errors = ($report | where { |r| $r.severity == "error" } | length)
    if $json {
        let out = if $fix {
            { findings: $report, fixed: $fixed_findings }
        } else {
            $report
        }
        print ($out | to json --raw)
    } else {
        if ($fixed_findings | is-not-empty) {
            print "Fixed findings:"
            print ($fixed_findings | select check target action status | table --expand)
            print ""
        }
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

# SDK helper subcommands for setup.nu scripts: not part of the public CLI (absent from `ygg --help`)
const SDK_SUBCOMMANDS = ["onchange", "merge-json", "export-secrets", "safe-link"]
const DQ = '"'
const COMPLETION_SHELLS = ["nu", "zsh", "bash", "fish", "ps1", "powershell"]

# Flags of one `scope commands` signature: table<long, short, takes_value, description>
def signature-flags [signatures: record]: nothing -> table {
    $signatures
    | values
    | first
    | where { |p| $p.parameter_type in ["switch", "named"] }
    | each { |p|
        {
            long: $p.parameter_name
            short: ($p.short_flag? | default "")
            takes_value: ($p.parameter_type == "named")
            description: ($p.description? | default "" | lines | first | default "" | str trim)
        }
    }
}

# Positional names of one signature; optional ones carry a trailing "?"
def signature-positionals [signatures: record]: nothing -> list<string> {
    $signatures
    | values
    | first
    | where { |p| $p.parameter_type == "positional" }
    | each { |p| if $p.is_optional { $p.parameter_name + "?" } else { $p.parameter_name } }
}

# One-line command description without internal RFC references
def clean-description [text: string]: nothing -> string {
    $text | lines | first | default "" | str replace --all --regex ' ?\(RFC-[0-9]+\)' '' | str trim
}

# RFC-052: the single source for all shell completions, built from the real `main *` signatures
def cli-signature-table []: nothing -> table {
    scope commands
    | where { |c| $c.name | str starts-with "main " }
    | each { |c|
        {
            command: ($c.name | str substring 5..)
            description: (clean-description $c.description)
            flags: (signature-flags $c.signatures)
            positionals: (signature-positionals $c.signatures)
        }
    }
    | where { |r| $r.command not-in $SDK_SUBCOMMANDS }
}

# Flags of the bare `ygg` command (--version)
def cli-root-flags []: nothing -> table {
    let root = (scope commands | where name == "main" | first)
    signature-flags $root.signatures
}

# Completion source for a positional: modules (host.toml), shells (completions), path (add)
def completion-kind [command: string, positional: string]: nothing -> string {
    match ($command + " " + ($positional | str replace '?' '')) {
        "remove name" => "modules"
        "completions shell" => "shells"
        "add source" => "path"
        _ => ""
    }
}

# Every spelling of a flag: [-s, --long] (short first when present)
def flag-spellings [f: record]: nothing -> list<string> {
    let long = ("--" + $f.long)
    if ($f.short != "") { [("-" + $f.short), $long] } else { [$long] }
}

def generate-completions-nu []: nothing -> string {
    let header = r#'
# Nushell completions for ygg (generated from the CLI signatures)
def "nu-complete ygg-modules" [] {
    let ygg_home = ($env.YGG_HOME? | default ($env.HOME? | default "~" | path join ".ygg"))
    let host_file = ($ygg_home | path join "host.toml")
    if ($host_file | path exists) {
        try {
            open $host_file | get -o modules | default [] | get -o name | default []
        } catch { [] }
    } else { [] }
}

def "nu-complete ygg-shells" [] {
    ["nu", "zsh", "bash", "fish", "ps1", "powershell"]
}
'# | str trim --left
    let flag_line = { |f|
        let short = if ($f.short != "") { "(-" + $f.short + ")" } else { "" }
        let typ = if $f.takes_value { ": string" } else { "" }
        "    --" + $f.long + $short + $typ + " # " + $f.description
    }
    let root = ("export extern ygg [\n" + (cli-root-flags | each $flag_line | str join "\n") + "\n]")
    let blocks = (cli-signature-table | each { |c|
        let pos = ($c.positionals | each { |p|
            let name = ($p | str replace '?' '')
            let comp = match (completion-kind $c.command $p) {
                "modules" => ("@" + $DQ + "nu-complete ygg-modules" + $DQ)
                "shells" => ("@" + $DQ + "nu-complete ygg-shells" + $DQ)
                _ => ""
            }
            "    " + $p + ": string" + $comp
        })
        let lines = ($pos | append ($c.flags | each $flag_line))
        "# " + $c.description + "\nexport extern " + $DQ + "ygg " + $c.command  + $DQ + " [\n" + ($lines | str join "\n") + (if ($lines | is-empty) { "" } else { "\n" }) + "]"
    })
    $header + "\n" + $root + "\n\n" + ($blocks | str join "\n\n")
}

# Zsh: escape text for use inside "..." and [...] of an _arguments spec
def zsh-escape [text: string]: nothing -> string {
    $text
    | str replace --all '\' '\\'
    | str replace --all $DQ ("\\" + $DQ)
    | str replace --all '$' '\$'
    | str replace --all (char -u '60') ('\' + (char -u '60'))
    | str replace --all '[' '\['
    | str replace --all ']' '\]'
}

def generate-completions-zsh []: nothing -> string {
    let table = (cli-signature-table)
    let commands = ($table | each { |c| "        " + $DQ  + $c.command + ":" + (zsh-escape $c.description)  + $DQ } | str join "\n")
    let root_spec = (cli-root-flags | each { |f|
        let d = (zsh-escape $f.description)
        if ($f.short != "") {
            "        " + $DQ + "(-" + $f.short + " --" + $f.long + ")" + $DQ + "{-" + $f.short + ",--" + $f.long + "}" + $DQ + "[" + $d + "]" + $DQ + " \\"
        } else {
            "        " + $DQ + "--" + $f.long + "[" + $d + "]" + $DQ + " \\"
        }
    } | str join "\n")
    let branches = ($table | each { |c|
        let flag_specs = ($c.flags | each { |f|
            let d = (zsh-escape $f.description)
            let val = if $f.takes_value { ":" + $f.long + ":" } else { "" }
            if ($f.short != "") {
                $DQ + "(-" + $f.short + " --" + $f.long + ")" + $DQ + "{-" + $f.short + ",--" + $f.long + "}" + $DQ + "[" + $d + "]" + $val  + $DQ
            } else {
                $DQ + "--" + $f.long + "[" + $d + "]" + $val  + $DQ
            }
        })
        let pos_specs = ($c.positionals | each { |p|
            let name = ($p | str replace '?' '')
            let prefix = if ($p | str ends-with "?") { "::" } else { "1:" }
            let action = match (completion-kind $c.command $p) {
                "shells" => ("(" + ($COMPLETION_SHELLS | str join " ") + ")")
                "path" => "_files"
                _ => ""
            }
            $DQ  + $prefix + $name + ":" + $action  + $DQ
        })
        let specs = ($flag_specs | append $pos_specs)
        let body = if ($specs | is-empty) {
            "                    true"
        } else {
            "                    _arguments \\\n" + ($specs | each { |s| "                        " + $s } | str join " \\\n")
        }
        "                " + $c.command + ")\n" + $body + "\n                    ;;"
    } | str join "\n")
    let head = "#compdef ygg\n\n# Zsh completion for ygg (generated from the CLI signatures)\n_ygg() {\n    local -a commands\n    commands=(\n"
    let mid = "\n    )\n\n    _arguments -C \\\n"
    let after_root = "\n        " + $DQ + "1: :->command" + $DQ + " \\\n        " + $DQ + "*:: :->args" + $DQ + "\n\n    case $state in\n        command)\n            _describe -t commands " + $DQ + "ygg command" + $DQ + " commands\n            ;;\n        args)\n            case $words[1] in\n"
    let tail = "\n            esac\n            ;;\n    esac\n}\n\n_ygg " + $DQ + "$@" + $DQ
    $head + $commands + $mid + $root_spec + $after_root + $branches + $tail
}

def generate-completions-bash []: nothing -> string {
    let table = (cli-signature-table)
    let names = ($table | get command | str join " ")
    let root_opts = (cli-root-flags | each { |f| flag-spellings $f } | flatten | str join " ")
    let branches = ($table | each { |c|
        let opts = ($c.flags | each { |f| flag-spellings $f } | flatten | str join " ")
        let kinds = ($c.positionals | each { |p| completion-kind $c.command $p })
        let shells = ($COMPLETION_SHELLS | str join " ")
        let body = if ("shells" in $kinds) {
            "            COMPREPLY=($(compgen -W " + $DQ  + $shells  + $DQ + " -- " + $DQ + "$cur" + $DQ + "))"
        } else if ("path" in $kinds) {
            "            if [[ " + $DQ + "$cur" + $DQ + " == -* ]]; then\n                COMPREPLY=($(compgen -W " + $DQ  + $opts  + $DQ + " -- " + $DQ + "$cur" + $DQ + "))\n            else\n                _filedir\n            fi"
        } else {
            "            local opts=" + $DQ  + $opts  + $DQ + "\n            COMPREPLY=($(compgen -W " + $DQ + "$opts" + $DQ + " -- " + $DQ + "$cur" + $DQ + "))"
        }
        "        " + $c.command + ")\n" + $body + "\n            ;;"
    } | str join "\n")
    let head = "# Bash completion for ygg (generated from the CLI signatures)\n\n_ygg() {\n    local cur prev words cword\n    _init_completion -s || return\n\n    local commands=" + $DQ  + $names  + $DQ + "\n\n    if [[ $cword -eq 1 ]]; then\n        COMPREPLY=($(compgen -W " + $DQ + "$commands " + $root_opts  + $DQ + " -- " + $DQ + "$cur" + $DQ + "))\n        return 0\n    fi\n\n    case " + $DQ + "${words[1]}" + $DQ + " in\n"
    let tail = "\n        *)\n            ;;\n    esac\n}\n\ncomplete -F _ygg ygg"
    $head + $branches + $tail
}

# Fish: escape text for use inside '...'
def fish-escape [text: string]: nothing -> string {
    $text | str replace --all '\' '\\' | str replace --all "'" "\\'"
}

def generate-completions-fish []: nothing -> string {
    let table = (cli-signature-table)
    let header = r#'
# Fish completion for ygg (generated from the CLI signatures)

function __fish_ygg_needs_command
    set -l cmd (commandline -opc)
    if test (count $cmd) -eq 1
        return 0
    end
    return 1
end

function __fish_ygg_using_subcommand -a sub
    set -l cmd (commandline -opc)
    if test (count $cmd) -gt 1
        if test $cmd[2] = $sub
            return 0
        end
    end
    return 1
end

complete -c ygg -f
'# | str trim --left
    let flag_args = { |f|
        let s = if ($f.short != "") { " -s " + $f.short } else { "" }
        let r = if $f.takes_value { " -r" } else { "" }
        " -l " + $f.long + $s + $r + " -d '" + (fish-escape $f.description) + "'"
    }
    let root = (cli-root-flags | each { |f| "complete -c ygg" + (do $flag_args $f) } | str join "\n")
    let subs = ($table | each { |c| "complete -c ygg -n " + $DQ + "__fish_ygg_needs_command" + $DQ + " -a " + $c.command + " -d '" + (fish-escape $c.description) + "'" } | str join "\n")
    let per_cmd = ($table | each { |c|
        let cond = " -n " + $DQ + "__fish_ygg_using_subcommand " + $c.command  + $DQ
        let flags = ($c.flags | each { |f| "complete -c ygg" + $cond + (do $flag_args $f) })
        let pos = ($c.positionals | each { |p|
            if (completion-kind $c.command $p) == "shells" {
                [("complete -c ygg" + $cond + " -a " + $DQ  + ($COMPLETION_SHELLS | str join " ")  + $DQ + " -d " + $DQ + "Shell" + $DQ)]
            } else { [] }
        } | flatten)
        $flags | append $pos | str join "\n"
    } | where { |b| $b != "" } | str join "\n\n")
    $header + "\n# General options\n" + $root + "\n\n# Subcommands\n" + $subs + "\n\n# Subcommand flags and arguments\n" + $per_cmd
}

# PowerShell: escape text for use inside '...'
def ps1-escape [text: string]: nothing -> string {
    $text | str replace --all "'" "''"
}

def generate-completions-ps1 []: nothing -> string {
    let table = (cli-signature-table)
    let subs = ($table | each { |c| "        '" + $c.command + "' = '" + (ps1-escape $c.description) + "'" } | str join "\n")
    # Flags are pair arrays, not hashtable keys: PowerShell hashtable keys are case-insensitive and
    # `-s` / `-S` (add: --scope / --skip-packages) would collide.
    let flags = ($table | each { |c|
        let entries = ($c.flags | each { |f|
            let d = (ps1-escape $f.description)
            flag-spellings $f | each { |sp| "            [pscustomobject]@{ N = '" + $sp + "'; D = '" + $d + "' }" }
        } | flatten)
        if ($entries | is-empty) {
            "        '" + $c.command + "' = @()"
        } else {
            "        '" + $c.command + "' = @(\n" + ($entries | str join ",\n") + "\n        )"
        }
    } | str join "\n")
    let values = ($table | each { |c|
        if ($c.positionals | any { |p| (completion-kind $c.command $p) == "shells" }) {
            [("        '" + $c.command + "' = @(" + ($COMPLETION_SHELLS | each { |s| "'" + $s + "'" } | str join ", ") + ")")]
        } else { [] }
    } | flatten | str join "\n")
    let head = "# PowerShell completion for ygg (generated from the CLI signatures)\n\nRegister-ArgumentCompleter -Native -CommandName 'ygg' -ScriptBlock {\n    param($wordToComplete, $commandAst, $cursorPosition)\n\n    $subcommands = [ordered]@{\n"
    let mid1 = "\n    }\n\n    $flags = @{\n"
    let mid2 = "\n    }\n\n    $values = @{\n"
    let tail = r#'
    }

    $elements = $commandAst.CommandElements
    if ($elements.Count -le 2) {
        $subcommands.GetEnumerator() | Where-Object { $_.Key -like "$wordToComplete*" } | ForEach-Object {
            [System.Management.Automation.CompletionResult]::new($_.Key, $_.Key, 'Command', $_.Value)
        }
        return
    }

    $subcmd = $elements[1].Value
    $candidates = @()
    if ($flags.ContainsKey($subcmd)) {
        $candidates += $flags[$subcmd]
    }
    if ($values.ContainsKey($subcmd)) {
        foreach ($v in $values[$subcmd]) { $candidates += [pscustomobject]@{ N = $v; D = $v } }
    }

    $candidates | Where-Object { $_.N -like "$wordToComplete*" } | ForEach-Object {
        [System.Management.Automation.CompletionResult]::new($_.N, $_.N, 'ParameterName', $_.D)
    }
}'#
    $head + $subs + $mid1 + $flags + $mid2 + $values + $tail
}

# Generate shell completions (RFC-039)
def "main completions" [
    shell: string
] {
    let s = ($shell | str lowercase)
    match $s {
        "nu" | "nushell" => {
            print (generate-completions-nu)
        }
        "zsh" => {
            print (generate-completions-zsh)
        }
        "bash" => {
            print (generate-completions-bash)
        }
        "fish" => {
            print (generate-completions-fish)
        }
        "ps1" | "powershell" => {
            print (generate-completions-ps1)
        }
        _ => {
            error make { msg: $"Unsupported shell: '($shell)'. Supported shells: nu, zsh, bash, fish, ps1, powershell" }
        }
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
