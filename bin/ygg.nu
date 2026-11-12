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
    --locked,
    --prune-packages,
    --force-system-prune
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
        print -e $"[ygg] Recovering: previous apply ($pending_journal.state) at step '($pending_journal.failed_step)'; re-running full pipeline."
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
def "main status" [--json] {
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
    --json,
    --fix,
    --yes (-y),
    --sandbox: string = ""
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

def generate-completions-nu [] {
    '# Nushell completions for ygg (RFC-039)
def "nu-complete ygg-modules" [] {
    let ygg_home = ($env.YGG_HOME? | default ($env.HOME? | default "~" | path join ".ygg"))
    let host_file = ($ygg_home | path join "host.toml")
    if ($host_file | path exists) {
        try {
            open $host_file | get -o modules | default {} | columns
        } catch { [] }
    } else { [] }
}

def "nu-complete ygg-shells" [] {
    ["nu", "zsh", "bash", "fish", "ps1", "powershell"]
}

export extern ygg [
    --version(-v) # Print version
]

export extern "ygg init" [
    name?: string # Module name
    --os: string  # Target OS (default: linux)
]

export extern "ygg add" [
    source: string                           # Path or Git URL of module
    --scope: string                          # Comma-separated scopes
    --dry-run                                # Simulate actions without applying
    --force                                  # Overwrite existing files/links
    --no-lock                                # Bypass concurrency lock
    --pkg: string                            # Filter packages to install
    --pkg-timeout: int                       # Package manager timeout in seconds
    --refresh-packages                       # Force package install even if hash matches
    --skip-packages                          # Skip all package installations
    --prune-packages                         # Remove unmanaged packages
    --force-system-prune                     # Force prune system packages
]

export extern "ygg remove" [
    name: string@"nu-complete ygg-modules"   # Module name to remove
    --no-lock                                # Bypass concurrency lock
]

export extern "ygg apply" [
    module?: string@"nu-complete ygg-modules" # Module name to apply
    --dry-run                                 # Simulate actions without applying
    --force                                   # Overwrite existing files/links
    --all                                     # Apply all modules in host.toml
    --pkg: string                             # Filter packages to install
    --pkg-timeout: int                        # Package manager timeout in seconds
    --refresh-packages                        # Force package install even if hash matches
    --skip-packages                           # Skip all package installations
    --prune-packages                          # Remove unmanaged packages
    --force-system-prune                      # Force prune system packages
    --no-lock                                 # Bypass concurrency lock
    --locked                                  # Fail if lock exists rather than waiting
]

export extern "ygg diff" [
    module?: string@"nu-complete ygg-modules" # Module name to diff
    --all                                     # Compare all modules
    --pkg: string                             # Filter packages to inspect
]

export extern "ygg update" [
    --no-lock # Bypass concurrency lock
]

export extern "ygg save" [
    module?: string@"nu-complete ygg-modules" # Module name to save back
    --no-lock                                 # Bypass concurrency lock
]

export extern "ygg clean" [
    --backups # Prune backups older than 7 days
    --hashes  # Clean orphaned package and state hashes
    --dry-run # Simulate cleanup without deleting
    --no-lock # Bypass concurrency lock
]

export extern "ygg status" [
    --json # Output status as JSON
]

export extern "ygg doctor" [
    --json     # Output audit results as JSON
    --fix      # Auto-heal detected issues
    --yes(-y)  # Confirm fixes non-interactively
]

export extern "ygg version" []

export extern "ygg completions" [
    shell: string@"nu-complete ygg-shells" # Target shell
]'
}

def generate-completions-zsh [] {
    '#compdef ygg

# Zsh completion for ygg (RFC-039)
_ygg() {
    local -a commands
    commands=(
        "init:Initialize a new module with ygg.toml and .gitignore"
        "add:Add local directory or git repo and apply"
        "remove:Remove a module and unlink its files"
        "apply:Apply configurations, links, packages and setup"
        "diff:Show planned changes without modifying anything"
        "update:Update git modules via rebase and apply"
        "save:Save reverse-copied GUI/app edits back to modules"
        "clean:Clean old backups and orphaned state hashes"
        "status:Display module sync and git status table"
        "doctor:Host audit & self-healing"
        "version:Print ygg version"
        "completions:Generate shell completions"
    )

    _arguments -C \
        "(-v --version)"{-v,--version}"[Print version]" \
        "1: :->command" \
        "*:: :->args"

    case $state in
        command)
            _describe -t commands "ygg command" commands
            ;;
        args)
            case $words[1] in
                init)
                    _arguments \
                        "--os[Target OS]:os:" \
                        "1:name:"
                    ;;
                add)
                    _arguments \
                        "--scope[Comma-separated scopes]:scopes:" \
                        "--dry-run[Simulate actions without applying]" \
                        "--force[Overwrite existing files/links]" \
                        "--no-lock[Bypass concurrency lock]" \
                        "--pkg[Filter packages]:packages:" \
                        "--pkg-timeout[Package manager timeout]:seconds:" \
                        "--refresh-packages[Force package install]" \
                        "--skip-packages[Skip all package installations]" \
                        "--prune-packages[Remove unmanaged packages]" \
                        "--force-system-prune[Force prune system packages]" \
                        "*:source:_files"
                    ;;
                apply)
                    _arguments \
                        "--dry-run[Simulate actions without applying]" \
                        "--force[Overwrite existing files/links]" \
                        "--all[Apply all modules]" \
                        "--pkg[Filter packages]:packages:" \
                        "--pkg-timeout[Package manager timeout]:seconds:" \
                        "--refresh-packages[Force package install]" \
                        "--skip-packages[Skip all package installations]" \
                        "--prune-packages[Remove unmanaged packages]" \
                        "--force-system-prune[Force prune system packages]" \
                        "--no-lock[Bypass concurrency lock]" \
                        "--locked[Fail if locked]" \
                        "*:module:"
                    ;;
                diff)
                    _arguments \
                        "--all[Compare all modules]" \
                        "--pkg[Filter packages]:packages:" \
                        "*:module:"
                    ;;
                clean)
                    _arguments \
                        "--backups[Prune backups older than 7 days]" \
                        "--hashes[Clean orphaned package hashes]" \
                        "--dry-run[Simulate cleanup]" \
                        "--no-lock[Bypass concurrency lock]"
                    ;;
                doctor)
                    _arguments \
                        "--json[Output audit results as JSON]" \
                        "--fix[Auto-heal detected issues]" \
                        "(-y --yes)"{-y,--yes}"[Confirm fixes non-interactively]"
                    ;;
                status)
                    _arguments \
                        "--json[Output status as JSON]"
                    ;;
                completions)
                    _arguments \
                        "1:shell:(nu zsh bash fish ps1 powershell)"
                    ;;
            esac
            ;;
    esac
}

_ygg "$@"'
}

def generate-completions-bash [] {
    '# Bash completion for ygg (RFC-039)

_ygg() {
    local cur prev words cword
    _init_completion -s || return

    local commands="init add remove apply diff update save clean status doctor version completions"

    if [[ $cword -eq 1 ]]; then
        COMPREPLY=($(compgen -W "$commands --version -v" -- "$cur"))
        return 0
    fi

    case "${words[1]}" in
        init)
            local opts="--os"
            COMPREPLY=($(compgen -W "$opts" -- "$cur"))
            ;;
        add)
            local opts="--scope --dry-run --force --no-lock --pkg --pkg-timeout --refresh-packages --skip-packages --prune-packages --force-system-prune"
            COMPREPLY=($(compgen -W "$opts" -- "$cur"))
            ;;
        apply)
            local opts="--dry-run --force --all --pkg --pkg-timeout --refresh-packages --skip-packages --prune-packages --force-system-prune --no-lock --locked"
            COMPREPLY=($(compgen -W "$opts" -- "$cur"))
            ;;
        diff)
            local opts="--all --pkg"
            COMPREPLY=($(compgen -W "$opts" -- "$cur"))
            ;;
        clean)
            local opts="--backups --hashes --dry-run --no-lock"
            COMPREPLY=($(compgen -W "$opts" -- "$cur"))
            ;;
        status)
            local opts="--json"
            COMPREPLY=($(compgen -W "$opts" -- "$cur"))
            ;;
        doctor)
            local opts="--json --fix -y --yes"
            COMPREPLY=($(compgen -W "$opts" -- "$cur"))
            ;;
        completions)
            local shells="nu zsh bash fish ps1 powershell"
            COMPREPLY=($(compgen -W "$shells" -- "$cur"))
            ;;
        *)
            ;;
    esac
}

complete -F _ygg ygg'
}

def generate-completions-fish [] {
    '# Fish completion for ygg (RFC-039)

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

# General options
complete -c ygg -s v -l version -d "Print version"

# Subcommands
complete -c ygg -n "__fish_ygg_needs_command" -a init -d "Initialize a new module with ygg.toml and .gitignore"
complete -c ygg -n "__fish_ygg_needs_command" -a add -d "Add local directory or git repo and apply"
complete -c ygg -n "__fish_ygg_needs_command" -a remove -d "Remove a module and unlink its files"
complete -c ygg -n "__fish_ygg_needs_command" -a apply -d "Apply configurations, links, packages and setup"
complete -c ygg -n "__fish_ygg_needs_command" -a diff -d "Show planned changes without modifying anything"
complete -c ygg -n "__fish_ygg_needs_command" -a update -d "Update git modules via rebase and apply"
complete -c ygg -n "__fish_ygg_needs_command" -a save -d "Save reverse-copied GUI/app edits back to modules"
complete -c ygg -n "__fish_ygg_needs_command" -a clean -d "Clean old backups and orphaned state hashes"
complete -c ygg -n "__fish_ygg_needs_command" -a status -d "Display module sync and git status table"
complete -c ygg -n "__fish_ygg_needs_command" -a doctor -d "Host audit & self-healing"
complete -c ygg -n "__fish_ygg_needs_command" -a version -d "Print version"
complete -c ygg -n "__fish_ygg_needs_command" -a completions -d "Generate shell completions"

# Completions command flags and args
complete -c ygg -n "__fish_ygg_using_subcommand completions" -a "nu zsh bash fish ps1 powershell" -d "Shell"

# Subcommand flags
complete -c ygg -n "__fish_ygg_using_subcommand init" -l os -d "Target OS"

complete -c ygg -n "__fish_ygg_using_subcommand add" -l scope -d "Comma-separated scopes"
complete -c ygg -n "__fish_ygg_using_subcommand add" -l dry-run -d "Simulate actions without applying"
complete -c ygg -n "__fish_ygg_using_subcommand add" -l force -d "Overwrite existing files/links"
complete -c ygg -n "__fish_ygg_using_subcommand add" -l no-lock -d "Bypass concurrency lock"
complete -c ygg -n "__fish_ygg_using_subcommand add" -l pkg -d "Filter packages to install"
complete -c ygg -n "__fish_ygg_using_subcommand add" -l pkg-timeout -d "Package manager timeout in seconds"
complete -c ygg -n "__fish_ygg_using_subcommand add" -l refresh-packages -d "Force package install"
complete -c ygg -n "__fish_ygg_using_subcommand add" -l skip-packages -d "Skip all package installations"
complete -c ygg -n "__fish_ygg_using_subcommand add" -l prune-packages -d "Remove unmanaged packages"
complete -c ygg -n "__fish_ygg_using_subcommand add" -l force-system-prune -d "Force prune system packages"

complete -c ygg -n "__fish_ygg_using_subcommand apply" -l dry-run -d "Simulate actions without applying"
complete -c ygg -n "__fish_ygg_using_subcommand apply" -l force -d "Overwrite existing files/links"
complete -c ygg -n "__fish_ygg_using_subcommand apply" -l all -d "Apply all modules"
complete -c ygg -n "__fish_ygg_using_subcommand apply" -l pkg -d "Filter packages to install"
complete -c ygg -n "__fish_ygg_using_subcommand apply" -l pkg-timeout -d "Package manager timeout"
complete -c ygg -n "__fish_ygg_using_subcommand apply" -l refresh-packages -d "Force package install"
complete -c ygg -n "__fish_ygg_using_subcommand apply" -l skip-packages -d "Skip all package installations"
complete -c ygg -n "__fish_ygg_using_subcommand apply" -l prune-packages -d "Remove unmanaged packages"
complete -c ygg -n "__fish_ygg_using_subcommand apply" -l force-system-prune -d "Force prune system packages"
complete -c ygg -n "__fish_ygg_using_subcommand apply" -l no-lock -d "Bypass concurrency lock"
complete -c ygg -n "__fish_ygg_using_subcommand apply" -l locked -d "Fail if locked"

complete -c ygg -n "__fish_ygg_using_subcommand diff" -l all -d "Compare all modules"
complete -c ygg -n "__fish_ygg_using_subcommand diff" -l pkg -d "Filter packages"

complete -c ygg -n "__fish_ygg_using_subcommand clean" -l backups -d "Prune backups older than 7 days"
complete -c ygg -n "__fish_ygg_using_subcommand clean" -l hashes -d "Clean orphaned hashes"
complete -c ygg -n "__fish_ygg_using_subcommand clean" -l dry-run -d "Simulate cleanup"
complete -c ygg -n "__fish_ygg_using_subcommand clean" -l no-lock -d "Bypass concurrency lock"

complete -c ygg -n "__fish_ygg_using_subcommand status" -l json -d "Output status as JSON"

complete -c ygg -n "__fish_ygg_using_subcommand doctor" -l json -d "Output audit results as JSON"
complete -c ygg -n "__fish_ygg_using_subcommand doctor" -l fix -d "Auto-heal detected issues"
complete -c ygg -n "__fish_ygg_using_subcommand doctor" -s y -l yes -d "Confirm fixes non-interactively"'
}

def generate-completions-ps1 [] {
    '# PowerShell completion for ygg (RFC-039)

Register-ArgumentCompleter -Native -CommandName "ygg" -ScriptBlock {
    param($wordToComplete, $commandAst, $cursorPosition)

    $subcommands = @{
        "init" = "Initialize a new module with ygg.toml and .gitignore"
        "add" = "Add local directory or git repo and apply"
        "remove" = "Remove a module and unlink its files"
        "apply" = "Apply configurations, links, packages and setup"
        "diff" = "Show planned changes without modifying anything"
        "update" = "Update git modules via rebase and apply"
        "save" = "Save reverse-copied GUI/app edits back to modules"
        "clean" = "Clean old backups and orphaned state hashes"
        "status" = "Display module sync and git status table"
        "doctor" = "Host audit & self-healing"
        "version" = "Print ygg version"
        "completions" = "Generate shell completions"
    }

    $elements = $commandAst.CommandElements
    if ($elements.Count -le 2) {
        $subcommands.GetEnumerator() | Where-Object { $_.Key -like "$wordToComplete*" } | ForEach-Object {
            [System.Management.Automation.CompletionResult]::new($_.Key, $_.Key, "Command", $_.Value)
        }
        return
    }

    $subcmd = $elements[1].Value
    $flags = switch ($subcmd) {
        "init" { @("--os") }
        "add" { @("--scope", "--dry-run", "--force", "--no-lock", "--pkg", "--pkg-timeout", "--refresh-packages", "--skip-packages", "--prune-packages", "--force-system-prune") }
        "apply" { @("--dry-run", "--force", "--all", "--pkg", "--pkg-timeout", "--refresh-packages", "--skip-packages", "--prune-packages", "--force-system-prune", "--no-lock", "--locked") }
        "diff" { @("--all", "--pkg") }
        "clean" { @("--backups", "--hashes", "--dry-run", "--no-lock") }
        "status" { @("--json") }
        "doctor" { @("--json", "--fix", "-y", "--yes") }
        "completions" { @("nu", "zsh", "bash", "fish", "ps1", "powershell") }
        default { @() }
    }

    $flags | Where-Object { $_ -like "$wordToComplete*" } | ForEach-Object {
        [System.Management.Automation.CompletionResult]::new($_, $_, "ParameterName", $_)
    }
}'
}

# Generate shell completions (RFC-039)
def "main completions" [
    shell: string
] {
    let s = ($shell | str downcase)
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
