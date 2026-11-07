#!/usr/bin/env nu
# bin/ygg.nu — Yggdrasil CLI Router

use ../src *

def main [] {
    print "Yggdrasil (ygg) — Minimalist cross-platform modular configuration manager"
    print ""
    print "Usage:"
    print "  ygg init [name] [--os <os_list>]        Initialize a new module with ygg.toml and .gitignore"
    print "  ygg add <source> [--scope <scopes>]      Add local directory or git repo and apply"
    print "  ygg remove <name>                        Remove a module and unlink its files"
    print "  ygg apply [--dry-run] [--force]          Apply configurations, links, packages and setup"
    print "  ygg update                               Update git modules via rebase and apply"
    print "  ygg save                                 Save reverse-copied GUI/app edits back to modules"
    print "  ygg status                               Display module sync and git status table"
    print ""
    print "SDK Subcommands (for setup.nu scripts):"
    print "  ygg onchange <key> <watch> <cmd>         Conditionally run command if watched files change"
    print "  ygg merge-json <fragment> <target>       Deep-merge JSON fragment into target file"
    print "  ygg export-secrets <dotenv>              Export selected secrets to environment dotenv"
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
    --scope (-s): string = ""
] {
    let ygg_home = (get-ygg-home)
    ensure-ygg-dirs $ygg_home

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

    let add_res = (add-module $ygg_home $clean_source --scopes $all_scopes)
    print $"Added module ($add_res.name)"

    main apply
}

# Remove a module and unlink its managed files
def "main remove" [name: string] {
    let ygg_home = (get-ygg-home)
    ensure-ygg-dirs $ygg_home
    remove-module $ygg_home $name
    print $"Removed module ($name)"
}

# Apply configurations, links, packages and setup across all modules
def "main apply" [
    --dry-run (-n),
    --force (-f),
    --sandbox: string = ""
] {
    let ygg_home = (get-ygg-home)
    ensure-ygg-dirs $ygg_home

    let effective_sandbox = if ($sandbox != "") {
        $sandbox
    } else {
        ($env.YGG_SANDBOX? | default "")
    }

    let plan = (resolve-effective-plan $ygg_home)

    # 1. Install packages
    install-packages $plan --dry-run=$dry_run --sandbox=$effective_sandbox | ignore

    # 2. Deploy links and file copies
    apply-links $ygg_home $plan --dry-run=$dry_run --force=$force --sandbox=$effective_sandbox | ignore

    # 3. Compile shell environments and aliases
    compile-environment $ygg_home $plan --dry-run=$dry_run --force=$force --sandbox=$effective_sandbox | ignore

    # 4. Run module procedural setup scripts
    for mod_entry in ($plan.modules? | default []) {
        run-module-setup $ygg_home $mod_entry --dry-run=$dry_run --force=$force --sandbox=$effective_sandbox
    }

    print $"Applied ($plan.modules? | default [] | length) module\(s\)."
}

# Update git modules via rebase and apply if clean
def "main update" [] {
    let ygg_home = (get-ygg-home)
    ensure-ygg-dirs $ygg_home

    let results = (update-modules $ygg_home)
    let conflicts = ($results | where status == "conflict")
    if ($conflicts | is-not-empty) {
        let names = ($conflicts | get name | str join ", ")
        print -e $"Update encountered conflicts in: ($names). Skipping apply."
        return $results
    }

    main apply
}

# Save reverse-copied files back to their source modules
def "main save" [--sandbox: string = ""] {
    let ygg_home = (get-ygg-home)
    ensure-ygg-dirs $ygg_home
    let effective_sandbox = if ($sandbox != "") { $sandbox } else { ($env.YGG_SANDBOX? | default "") }
    let plan = (resolve-effective-plan $ygg_home)
    let saved = (save-copied-files $ygg_home $plan --sandbox=$effective_sandbox)
    print $"Saved ($saved | length) file\(s\)."
    $saved
}

# Display module sync and git status table
def "main status" [] {
    let ygg_home = (get-ygg-home)
    ensure-ygg-dirs $ygg_home
    modules-status $ygg_home
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
