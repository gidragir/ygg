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
    } catch { |e|
        error make { msg: $"Cannot parse ($host_file): ($e.msg). Refusing to continue." }
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

    mut raw_path = ($raw.path? | default [])
    if not (($raw_path | describe) starts-with "list") {
        $raw_path = [$raw_path]
    }

    mut raw_depends = ($raw.depends_on? | default [])
    if not (($raw_depends | describe) starts-with "list") {
        $raw_depends = (if ($raw_depends == "") { [] } else { [$raw_depends] })
    }

    mut manifest = {
        name: $mod_name,
        os: $norm_os,
        depends_on: $raw_depends,
        description: ($raw.description? | default ""),
        config: ($raw.config? | default {}),
        packages: ($raw.packages? | default {}),
        links: ($raw.links? | default {}),
        save: ($raw.save? | default {}),
        env: ($raw.env? | default {}),
        aliases: ($raw.aliases? | default {}),
        path: $raw_path,
        scope: ($raw.scope? | default {}),
        doctor: ($raw.doctor? | default {})
    }

    if ($manifest.env.path? != null) {
        let ep = if (($manifest.env.path | describe) starts-with "list") { $manifest.env.path } else { [$manifest.env.path] }
        $manifest.path = ($manifest.path | append $ep | uniq)
        $manifest.env = ($manifest.env | reject path)
    }

    for s_name in ($manifest.scope | columns) {
        let s_val = ($manifest.scope | get $s_name)
        mut s_scope = $s_val
        mut s_path = ($s_val.path? | default [])
        if not (($s_path | describe) starts-with "list") {
            $s_path = [$s_path]
        }
        if ($s_val.env?.path? != null) {
            let p = if (($s_val.env.path | describe) starts-with "list") { $s_val.env.path } else { [$s_val.env.path] }
            $s_path = ($s_path | append $p | uniq)
            let clean_env = ($s_val.env | reject path)
            $s_scope = ($s_scope | upsert env $clean_env)
        }
        if not ($s_path | is-empty) {
            $s_scope = ($s_scope | upsert path $s_path)
        }
        $manifest.scope = ($manifest.scope | upsert $s_name $s_scope)
    }

    # 1. packages.toml
    let pkg_file = ($mod_dir | path join "packages.toml")
    if ($pkg_file | path exists) {
        let ext = (open $pkg_file)
        if ($ext.packages? != null) {
            for mgr in ($ext.packages | columns) {
                let cur = ($manifest.packages | get -o $mgr | default [])
                let added = ($ext.packages | get $mgr)
                $manifest.packages = ($manifest.packages | upsert $mgr ($cur | append $added | uniq))
            }
        }
        for col in ($ext | columns | where { |c| $c != "packages" and $c != "scope" }) {
            let val = ($ext | get $col)
            if (($val | describe) starts-with "list") {
                let cur = ($manifest.packages | get -o $col | default [])
                $manifest.packages = ($manifest.packages | upsert $col ($cur | append $val | uniq))
            }
        }
        if ($ext.scope? != null) {
            for s_name in ($ext.scope | columns) {
                let s_val = ($ext.scope | get $s_name)
                let s_pkgs = if ($s_val.packages? != null) { $s_val.packages } else { $s_val }
                let cur_scope = ($manifest.scope | get -o $s_name | default {})
                let cur_scope_pkgs = ($cur_scope.packages? | default {})
                mut updated_pkgs = $cur_scope_pkgs
                for mgr in ($s_pkgs | columns) {
                    let cur_mgr = ($updated_pkgs | get -o $mgr | default [])
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
                let cur_scope = ($manifest.scope | get -o $s_name | default {})
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
        if ($ext.path? != null) {
            let p = if (($ext.path | describe) starts-with "list") { $ext.path } else { [$ext.path] }
            let cur_path = ($manifest.path? | default [])
            $manifest.path = ($cur_path | append $p | uniq)
        }
        if ($ext.env? != null) {
            mut env_map = $ext.env
            if ($env_map.path? != null) {
                let p = if (($env_map.path | describe) starts-with "list") { $env_map.path } else { [$env_map.path] }
                let cur_path = ($manifest.path? | default [])
                $manifest.path = ($cur_path | append $p | uniq)
                $env_map = ($env_map | reject path)
            }
            $manifest.env = ($manifest.env | merge $env_map)
        }
        for col in ($ext | columns | where { |c| $c != "env" and $c != "scope" and $c != "path" }) {
            $manifest.env = ($manifest.env | upsert $col ($ext | get $col))
        }
        if ($ext.scope? != null) {
            for s_name in ($ext.scope | columns) {
                let s_val = ($ext.scope | get $s_name)
                mut s_env = if ($s_val.env? != null) { $s_val.env } else { $s_val }
                let cur_scope = ($manifest.scope | get -o $s_name | default {})
                let cur_scope_env = ($cur_scope.env? | default {})
                let cur_scope_path = ($cur_scope.path? | default [])

                mut new_scope_path = $cur_scope_path
                if ($s_val.path? != null) {
                    let p = if (($s_val.path | describe) starts-with "list") { $s_val.path } else { [$s_val.path] }
                    $new_scope_path = ($new_scope_path | append $p | uniq)
                }
                if ($s_env.path? != null) {
                    let p = if (($s_env.path | describe) starts-with "list") { $s_env.path } else { [$s_env.path] }
                    $new_scope_path = ($new_scope_path | append $p | uniq)
                    $s_env = ($s_env | reject path)
                }

                mut updated_scope = ($cur_scope | upsert env ($cur_scope_env | merge $s_env))
                if not ($new_scope_path | is-empty) {
                    $updated_scope = ($updated_scope | upsert path $new_scope_path)
                }
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
                let cur_scope = ($manifest.scope | get -o $s_name | default {})
                let cur_scope_aliases = ($cur_scope.aliases? | default {})
                let updated_scope = ($cur_scope | upsert aliases ($cur_scope_aliases | merge $s_aliases))
                $manifest.scope = ($manifest.scope | upsert $s_name $updated_scope)
            }
        }
    }

    $manifest
}

# Normalize a scalar-or-list value to list<string> (RFC-003)
def to-string-list [value: any]: nothing -> list<string> {
    if (($value | describe) starts-with "list") { $value } else { [$value] }
}

# Normalize a link value (string | list | table { target, on_change, mode }) (RFC-003, RFC-015, RFC-021)
def normalize-link-value [key: string, value: any]: nothing -> record<targets: list<string>, on_change: string, mode: string> {
    if not (($value | describe) starts-with "record") {
        return { targets: (to-string-list $value), on_change: "", mode: "" }
    }
    if ($value.target? == null) {
        error make { msg: $"Link '($key)': table form requires 'target'" }
    }
    let mode = ($value.mode? | default "")
    if $mode not-in ["", "dir"] {
        error make { msg: $"Link '($key)': unknown mode '($mode)' \(expected 'dir'\)" }
    }
    if ($mode != "") and ($key | str ends-with "/*") {
        error make { msg: $"Link '($key)': mode cannot be combined with /*" }
    }
    { targets: (to-string-list $value.target), on_change: ($value.on_change? | default ""), mode: $mode }
}

# Replace base entries whose key is redefined in a scope; scoped entries take the scope origin_rank (RFC-010)
def merge-link-entries [base: table, scoped: table]: nothing -> table {
    if ($scoped | is-empty) {
        return $base
    }
    let scoped_keys = ($scoped | get key)
    $base | where { |b| $b.key not-in $scoped_keys } | append $scoped
}

# Convert a links/save record of a manifest into a candidate table with origin_rank
def entries-with-rank [section: any, origin_rank: int]: nothing -> table {
    if ($section == null) or (($section | describe) !~ '^record') {
        return []
    }
    $section | transpose key value | each { |e| { key: $e.key, value: $e.value, origin_rank: $origin_rank } }
}

# Topologically sort modules by their declared dependencies using Kahn's algorithm (RFC-031)
export def sort-modules-dag [modules: list<record>]: nothing -> list<record> {
    if ($modules | length) <= 1 {
        return $modules
    }

    let all_names = ($modules | each { |m| $m.name })

    mut pending = ($modules | each { |m|
        let raw_deps = ($m | get -o depends_on | default [])
        let norm_deps = if (($raw_deps | describe) starts-with "list") {
            $raw_deps
        } else if ($raw_deps == "") {
            []
        } else {
            [$raw_deps]
        }
        let internal_deps = ($norm_deps | where { |d| $d in $all_names } | uniq)
        {
            name: $m.name,
            item: $m,
            deps: $internal_deps
        }
    })

    mut sorted = []

    while ($pending | is-not-empty) {
        let ready = ($pending | where { |node| ($node.deps | is-empty) })
        if ($ready | is-empty) {
            let cycle_mods = ($pending | get name | str join ", ")
            error make { msg: $"Cyclic module dependency detected among: ($cycle_mods)" }
        }

        for r in $ready {
            $sorted = ($sorted | append $r.item)
        }

        let resolved_names = ($ready | get name)
        $pending = ($pending | where { |node| $node.name not-in $resolved_names })
        $pending = ($pending | each { |node|
            $node | upsert deps ($node.deps | where { |d| $d not-in $resolved_names })
        })
    }

    $sorted
}

# Resolve effective plan across active modules and scopes
# --extra-modules: virtual { name, path, scopes } entries (RFC-012, `ygg add` preview / pre-flight);
# an entry replaces the host.toml module of the same name and goes last, as a real `add` would.
export def resolve-effective-plan [
    ygg_home: string,
    --modules-filter: list<string> = [],
    --extra-modules: list<record> = []
]: nothing -> record {
    let host_cfg = (load-host-config $ygg_home)
    let host_os = (detect-host-os)

    let extra_names = ($extra_modules | each { |m| $m.name })
    let all_modules = ($host_cfg.modules? | default [] | where { |m| $m.name not-in $extra_names } | append $extra_modules)
    let active_modules = if ($modules_filter | is-empty) {
        $all_modules
    } else {
        $all_modules | where { |m| $m.name in $modules_filter }
    }

    let prepared_modules = ($active_modules | each { |mod_entry|
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
        let entry_deps = if ($mod_entry.depends_on? | default null) == null {
            []
        } else if (($mod_entry.depends_on | describe) starts-with "list") {
            $mod_entry.depends_on
        } else {
            [$mod_entry.depends_on]
        }
        let manifest_deps = ($manifest.depends_on? | default [])
        let all_deps = ($manifest_deps | append $entry_deps | uniq)
        {
            name: $mod_name,
            depends_on: $all_deps,
            mod_entry: $mod_entry,
            mod_dir: $mod_dir,
            manifest: $manifest
        }
    })

    let sorted_modules = (sort-modules-dag $prepared_modules)

    mut plan_modules = []
    mut plan_links = []
    mut plan_save = []
    mut plan_packages = {}
    mut plan_env = {}
    mut plan_aliases = {}
    mut plan_path = []
    mut key_order = 0
    mut mod_rank = -1

    for item in $sorted_modules {
        $mod_rank = $mod_rank + 1
        let mod_entry = $item.mod_entry
        let mod_name = $item.name
        let mod_dir = $item.mod_dir
        let manifest = $item.manifest

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
        # Collect module's links / save as candidate tables (origin_rank 0 = base, RFC-010)
        mut mod_links = (entries-with-rank $manifest.links 0)
        mut mod_save = (entries-with-rank $manifest.save 0)
        # Collect module's env
        mut mod_env = $manifest.env
        # Collect module's aliases
        mut mod_aliases = $manifest.aliases
        # Collect module's path
        mut mod_path = ($manifest.path? | default [])
        if not (($mod_path | describe) starts-with "list") {
            $mod_path = [$mod_path]
        }

        # Merge in active scopes for this module (origin_rank 1..N in active scope order)
        mut scope_rank = 0
        for s_name in $active_scopes {
            $scope_rank = $scope_rank + 1
            let scope_data = ($manifest.scope | get -o $s_name)
            if ($scope_data != null) {
                # packages in scope
                if ($scope_data.packages? != null) {
                    for mgr in ($scope_data.packages | columns) {
                        let cur = ($mod_packages | get -o $mgr | default [])
                        let added = ($scope_data.packages | get $mgr)
                        $mod_packages = ($mod_packages | upsert $mgr ($cur | append $added | uniq))
                    }
                }
                # links in scope
                if ($scope_data.links? != null) {
                    $mod_links = (merge-link-entries $mod_links (entries-with-rank $scope_data.links $scope_rank))
                }
                # save in scope
                if ($scope_data.save? != null) {
                    $mod_save = (merge-link-entries $mod_save (entries-with-rank $scope_data.save $scope_rank))
                }
                # env in scope
                if ($scope_data.env? != null) {
                    $mod_env = ($mod_env | merge $scope_data.env)
                }
                # aliases in scope
                if ($scope_data.aliases? != null) {
                    $mod_aliases = ($mod_aliases | merge $scope_data.aliases)
                }
                # path in scope
                if ($scope_data.path? != null) {
                    let p = if (($scope_data.path | describe) starts-with "list") { $scope_data.path } else { [$scope_data.path] }
                    $mod_path = ($mod_path | append $p | uniq)
                }
            }
        }

        for p in $mod_path {
            if ($p | str contains "%") {
                error make { msg: $"Path entry '($p)' contains '%' which is not supported on Windows user Path (.NET writes REG_SZ where % variables are not expanded)" }
            }
        }
        $plan_path = ($plan_path | append $mod_path | uniq)

        # Handle excludes for links and save
        let excludes = ($mod_entry.exclude? | default [])

        # Collect ALL link candidates; priority is resolved by resolve-link-targets (RFC-003, RFC-010)
        for entry in $mod_links {
            let link_key = $entry.key
            let spec = (normalize-link-value $link_key $entry.value)
            for dest_raw in $spec.targets {
                if ($link_key in $excludes) or ($dest_raw in $excludes) {
                    continue
                }
                let clean_key = ($link_key | str replace --regex '^\./' '')
                let base_rel = ($clean_key | str replace --regex '/\*$' '')
                let src_path = ($mod_dir | path join $base_rel)
                let is_glob = (($link_key | str ends-with "/*") or ($dest_raw | str ends-with "/*"))

                $plan_links = ($plan_links | append {
                    module: $mod_name,
                    module_rank: $mod_rank,
                    origin_rank: $entry.origin_rank,
                    key_order: $key_order,
                    key: $link_key,
                    src_rel: $clean_key,
                    src_path: $src_path,
                    dest_raw: $dest_raw,
                    is_glob: $is_glob,
                    on_change: $spec.on_change,
                    mode: $spec.mode
                })
                $key_order = $key_order + 1
            }
        }

        # Collect ALL save candidates (1-to-N targets)
        for entry in $mod_save {
            let save_key = $entry.key
            let spec = (normalize-link-value $save_key $entry.value)
            for dest_raw in $spec.targets {
                if ($save_key in $excludes) or ($dest_raw in $excludes) {
                    continue
                }
                let clean_key = ($save_key | str replace --regex '^\./' '')
                $plan_save = ($plan_save | append {
                    module: $mod_name,
                    module_rank: $mod_rank,
                    origin_rank: $entry.origin_rank,
                    key_order: $key_order,
                    key: $save_key,
                    src_rel: $clean_key,
                    src_path: ($mod_dir | path join $clean_key),
                    dest_raw: $dest_raw
                })
                $key_order = $key_order + 1
            }
        }

        # Merge packages across modules
        for mgr in ($mod_packages | columns) {
            let cur = ($plan_packages | get -o $mgr | default [])
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
            depends_on: $item.depends_on,
            has_setup: ($mod_dir | path join "setup.nu" | path exists),
            pin: ($mod_entry.pin? | default false),
            ref: ($mod_entry.ref? | default ""),
            rev: ($mod_entry.rev? | default "")
        })
    }

    {
        modules: $plan_modules,
        links: $plan_links,
        save: $plan_save,
        packages: $plan_packages,
        env: $plan_env,
        aliases: $plan_aliases,
        path: $plan_path
    }
}
