# src/manifest.nu
# Yggdrasil configuration manager — Manifest parser, OS guard & scope resolution

use state.nu [detect-host-os]

# Load host configuration from $YGG_HOME/host.toml (defaults to { modules: [] })
export def load-host-config [ygg_home: string]: nothing -> record {
    let host_file = ($ygg_home | path join "host.toml")
    let default_cfg = { modules: [] }

    if not ($host_file | path exists) {
        return $default_cfg
    }

    try {
        let loaded = (open $host_file)
        let mods = ($loaded.modules? | default [])
        $loaded | merge { modules: $mods }
    } catch {
        $default_cfg
    }
}

# Save host configuration atomically to $YGG_HOME/host.toml
export def save-host-config [ygg_home: string, cfg: record]: nothing -> nothing {
    if not ($ygg_home | path exists) {
        mkdir $ygg_home
    }
    let host_file = ($ygg_home | path join "host.toml")
    let rand_id = (random chars --length 8)
    let tmp_file = ($ygg_home | path join $"host.toml.tmp.($rand_id)")

    $cfg | to toml | save -f $tmp_file
    mv -f $tmp_file $host_file
}

# Check if module supports the current host OS
export def validate-module-os [manifest: record, host_os: record]: nothing -> bool {
    let host_tokens = ([$host_os.os, $host_os.distro]
        | append ($host_os.auto_scopes? | default [])
        | uniq
        | each { |s| $s | str lowercase })

    let mod_os_raw = ($manifest.os? | default [])
    let mod_os = if (($mod_os_raw | describe) starts-with "list") {
        $mod_os_raw
    } else if ($mod_os_raw != "") and ($mod_os_raw != null) {
        [$mod_os_raw]
    } else {
        []
    }

    $mod_os | any { |req| ($req | str lowercase) in $host_tokens }
}

# Load module manifest ygg.toml and merge optional packages.toml, links.toml, env.toml, aliases.toml
export def load-module-manifest [mod_dir: string]: nothing -> record {
    let ygg_path = ($mod_dir | path join "ygg.toml")
    if not ($ygg_path | path exists) {
        error make { msg: $"Module manifest 'ygg.toml' not found in '($mod_dir)'" }
    }

    let raw = (open $ygg_path)

    # Validate name
    let mod_name = ($raw.name? | default "")
    if ($mod_name == "") {
        error make { msg: $"Module manifest in '($mod_dir)' missing required field 'name'" }
    }

    # Validate os
    let mod_os_raw = ($raw.os? | default null)
    if ($mod_os_raw == null) or ($mod_os_raw == []) or ($mod_os_raw == "") {
        error make { msg: $"Module manifest in '($mod_dir)' missing required field 'os'" }
    }
    let norm_os = if (($mod_os_raw | describe) starts-with "list") {
        $mod_os_raw
    } else {
        [$mod_os_raw]
    }

    mut manifest = {
        name: $mod_name,
        os: $norm_os,
        description: ($raw.description? | default ""),
        config: ($raw.config? | default {}),
        packages: ($raw.packages? | default {}),
        links: ($raw.links? | default {}),
        save: ($raw.save? | default {}),
        env: ($raw.env? | default {}),
        aliases: ($raw.aliases? | default {}),
        scope: ($raw.scope? | default {})
    }

    # 1. packages.toml
    let pkg_file = ($mod_dir | path join "packages.toml")
    if ($pkg_file | path exists) {
        let ext = (open $pkg_file)
        if ($ext.packages? != null) {
            for mgr in ($ext.packages | columns) {
                let cur = ($manifest.packages | get -i $mgr | default [])
                let added = ($ext.packages | get $mgr)
                $manifest.packages = ($manifest.packages | upsert $mgr ($cur | append $added | uniq))
            }
        }
        for col in ($ext | columns | where { |c| $c != "packages" and $c != "scope" }) {
            let val = ($ext | get $col)
            if (($val | describe) starts-with "list") {
                let cur = ($manifest.packages | get -i $col | default [])
                $manifest.packages = ($manifest.packages | upsert $col ($cur | append $val | uniq))
            }
        }
        if ($ext.scope? != null) {
            for s_name in ($ext.scope | columns) {
                let s_val = ($ext.scope | get $s_name)
                let s_pkgs = if ($s_val.packages? != null) { $s_val.packages } else { $s_val }
                let cur_scope = ($manifest.scope | get -i $s_name | default {})
                let cur_scope_pkgs = ($cur_scope.packages? | default {})
                mut updated_pkgs = $cur_scope_pkgs
                for mgr in ($s_pkgs | columns) {
                    let cur_mgr = ($updated_pkgs | get -i $mgr | default [])
                    let added = ($s_pkgs | get $mgr)
                    $updated_pkgs = ($updated_pkgs | upsert $mgr ($cur_mgr | append $added | uniq))
                }
                let updated_scope = ($cur_scope | upsert packages $updated_pkgs)
                $manifest.scope = ($manifest.scope | upsert $s_name $updated_scope)
            }
        }
    }

    # 2. links.toml
    let links_file = ($mod_dir | path join "links.toml")
    if ($links_file | path exists) {
        let ext = (open $links_file)
        if ($ext.links? != null) {
            $manifest.links = ($manifest.links | merge $ext.links)
        }
        for col in ($ext | columns | where { |c| $c != "links" and $c != "scope" }) {
            $manifest.links = ($manifest.links | upsert $col ($ext | get $col))
        }
        if ($ext.scope? != null) {
            for s_name in ($ext.scope | columns) {
                let s_val = ($ext.scope | get $s_name)
                let s_links = if ($s_val.links? != null) { $s_val.links } else { $s_val }
                let cur_scope = ($manifest.scope | get -i $s_name | default {})
                let cur_scope_links = ($cur_scope.links? | default {})
                let updated_scope = ($cur_scope | upsert links ($cur_scope_links | merge $s_links))
                $manifest.scope = ($manifest.scope | upsert $s_name $updated_scope)
            }
        }
    }

    # 3. env.toml
    let env_file = ($mod_dir | path join "env.toml")
    if ($env_file | path exists) {
        let ext = (open $env_file)
        if ($ext.env? != null) {
            $manifest.env = ($manifest.env | merge $ext.env)
        }
        for col in ($ext | columns | where { |c| $c != "env" and $c != "scope" }) {
            $manifest.env = ($manifest.env | upsert $col ($ext | get $col))
        }
        if ($ext.scope? != null) {
            for s_name in ($ext.scope | columns) {
                let s_val = ($ext.scope | get $s_name)
                let s_env = if ($s_val.env? != null) { $s_val.env } else { $s_val }
                let cur_scope = ($manifest.scope | get -i $s_name | default {})
                let cur_scope_env = ($cur_scope.env? | default {})
                let updated_scope = ($cur_scope | upsert env ($cur_scope_env | merge $s_env))
                $manifest.scope = ($manifest.scope | upsert $s_name $updated_scope)
            }
        }
    }

    # 4. aliases.toml
    let aliases_file = ($mod_dir | path join "aliases.toml")
    if ($aliases_file | path exists) {
        let ext = (open $aliases_file)
        if ($ext.aliases? != null) {
            $manifest.aliases = ($manifest.aliases | merge $ext.aliases)
        }
        for col in ($ext | columns | where { |c| $c != "aliases" and $c != "scope" }) {
            $manifest.aliases = ($manifest.aliases | upsert $col ($ext | get $col))
        }
        if ($ext.scope? != null) {
            for s_name in ($ext.scope | columns) {
                let s_val = ($ext.scope | get $s_name)
                let s_aliases = if ($s_val.aliases? != null) { $s_val.aliases } else { $s_val }
                let cur_scope = ($manifest.scope | get -i $s_name | default {})
                let cur_scope_aliases = ($cur_scope.aliases? | default {})
                let updated_scope = ($cur_scope | upsert aliases ($cur_scope_aliases | merge $s_aliases))
                $manifest.scope = ($manifest.scope | upsert $s_name $updated_scope)
            }
        }
    }

    $manifest
}

# Resolve effective plan across active modules and scopes
export def resolve-effective-plan [ygg_home: string, --modules-filter: list<string> = []]: nothing -> record {
    let host_cfg = (load-host-config $ygg_home)
    let host_os = (detect-host-os)

    let all_modules = ($host_cfg.modules? | default [])
    let active_modules = if ($modules_filter | is-empty) {
        $all_modules
    } else {
        $all_modules | where { |m| $m.name in $modules_filter }
    }

    mut plan_modules = []
    mut plan_links = []
    mut plan_save = []
    mut plan_packages = {}
    mut plan_env = {}
    mut plan_aliases = {}

    for mod_entry in $active_modules {
        let mod_name = $mod_entry.name
        let mod_dir = if ($mod_entry.path? != null) and ($mod_entry.path != "") {
            if not ($mod_entry.path | path exists) {
                error make { msg: $"Custom path for module '($mod_name)' not found at '($mod_entry.path)'" }
            }
            $mod_entry.path
        } else {
            let default_dir = ($ygg_home | path join "modules" $mod_name)
            if not ($default_dir | path exists) {
                error make { msg: $"Module directory for '($mod_name)' not found at '($default_dir)'" }
            }
            $default_dir
        }

        let manifest = (load-module-manifest $mod_dir)

        # OS Guard check
        if not (validate-module-os $manifest $host_os) {
            error make { msg: $"Module '($mod_name)' does not support host OS '($host_os.os)' \(required: ($manifest.os | to json -r)\)" }
        }

        # Active scopes for this module: host auto_scopes + host.toml scopes
        let mod_entry_scopes = ($mod_entry.scopes? | default [])
        let active_scopes = ($host_os.auto_scopes | append $mod_entry_scopes | uniq)

        # Merge config: module manifest config overridden by host.toml config
        let effective_config = ($manifest.config | merge ($mod_entry.config? | default {}))

        # Collect module's packages
        mut mod_packages = $manifest.packages
        # Collect module's links
        mut mod_links = $manifest.links
        # Collect module's save
        mut mod_save = $manifest.save
        # Collect module's env
        mut mod_env = $manifest.env
        # Collect module's aliases
        mut mod_aliases = $manifest.aliases

        # Merge in active scopes for this module
        for s_name in $active_scopes {
            let scope_data = ($manifest.scope | get -i $s_name)
            if ($scope_data != null) {
                # packages in scope
                if ($scope_data.packages? != null) {
                    for mgr in ($scope_data.packages | columns) {
                        let cur = ($mod_packages | get -i $mgr | default [])
                        let added = ($scope_data.packages | get $mgr)
                        $mod_packages = ($mod_packages | upsert $mgr ($cur | append $added | uniq))
                    }
                }
                # links in scope
                if ($scope_data.links? != null) {
                    $mod_links = ($mod_links | merge $scope_data.links)
                }
                # save in scope
                if ($scope_data.save? != null) {
                    $mod_save = ($mod_save | merge $scope_data.save)
                }
                # env in scope
                if ($scope_data.env? != null) {
                    $mod_env = ($mod_env | merge $scope_data.env)
                }
                # aliases in scope
                if ($scope_data.aliases? != null) {
                    $mod_aliases = ($mod_aliases | merge $scope_data.aliases)
                }
            }
        }

        # Handle excludes for links and save
        let excludes = ($mod_entry.exclude? | default [])

        # Process links with collision resolution (Last-Module-Wins)
        for link_key in ($mod_links | columns) {
            let dest_raw = ($mod_links | get $link_key)
            if ($link_key in $excludes) or ($dest_raw in $excludes) {
                continue
            }

            let clean_key = ($link_key | str replace --regex '^\./' '')
            let base_rel = ($clean_key | str replace --regex '/\*$' '')
            let src_path = ($mod_dir | path join $base_rel)
            let is_glob = (($link_key | str ends-with "/*") or ($dest_raw | str ends-with "/*"))

            let link_record = {
                module: $mod_name,
                key: $link_key,
                src_rel: $clean_key,
                src_path: $src_path,
                dest_raw: $dest_raw,
                is_glob: $is_glob
            }

            if not $is_glob {
                # Non-glob: replace existing link targeting the exact same dest_raw
                $plan_links = ($plan_links | where { |it| $it.is_glob or ($it.dest_raw != $dest_raw) } | append $link_record)
            } else {
                # Glob link: append
                $plan_links = ($plan_links | append $link_record)
            }
        }

        # Process save
        for save_key in ($mod_save | columns) {
            let dest_raw = ($mod_save | get $save_key)
            if ($save_key in $excludes) or ($dest_raw in $excludes) {
                continue
            }

            let clean_key = ($save_key | str replace --regex '^\./' '')
            let save_record = {
                module: $mod_name,
                key: $save_key,
                src_rel: $clean_key,
                src_path: ($mod_dir | path join $clean_key),
                dest_raw: $dest_raw
            }

            $plan_save = ($plan_save | where { |it| $it.dest_raw != $dest_raw } | append $save_record)
        }

        # Merge packages across modules
        for mgr in ($mod_packages | columns) {
            let cur = ($plan_packages | get -i $mgr | default [])
            let added = ($mod_packages | get $mgr)
            $plan_packages = ($plan_packages | upsert $mgr ($cur | append $added | uniq))
        }

        # Merge env across modules (later module overrides earlier)
        $plan_env = ($plan_env | merge $mod_env)

        # Merge aliases across modules (later module overrides earlier)
        $plan_aliases = ($plan_aliases | merge $mod_aliases)

        # Record active module entry
        $plan_modules = ($plan_modules | append {
            name: $mod_name,
            dir: $mod_dir,
            config: $effective_config,
            scopes: $active_scopes,
            manifest: $manifest,
            has_setup: ($mod_dir | path join "setup.nu" | path exists)
        })
    }

    {
        modules: $plan_modules,
        links: $plan_links,
        save: $plan_save,
        packages: $plan_packages,
        env: $plan_env,
        aliases: $plan_aliases
    }
}
