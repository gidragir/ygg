# tests/test_manifest.nu
use std/assert
use ../src/manifest.nu *
use ../src/link.nu [preflight-check]
use helpers.nu [with-temp-ygg]

export def test_scope_isolation_and_last_module_wins [] {
    with-temp-ygg { |home|
        let m1 = ($home | path join "modules" "base")
        let m2 = ($home | path join "modules" "override")
        mkdir $m1 $m2
        'name = "base"
os = ["cachyos"]
[packages]
pacman = ["rofi-wayland"]
[links]
niri = "~/.config/niri"
starship = "~/.config/starship.toml"
[scope.pc.links]
openrgb = "~/.config/OpenRGB"
[scope.asus.links]
rog = "~/.config/rog"
' | save -f ($m1 | path join "ygg.toml")

        'name = "override"
os = ["linux", "windows", "macos"]
[links]
starship = "~/.config/starship.toml"
' | save -f ($m2 | path join "ygg.toml")

        '[[modules]]
name = "base"
scopes = ["asus"]
[[modules]]
name = "override"
' | save -f ($home | path join "host.toml")

        with-env { YGG_HOST_OS_OVERRIDE: "cachyos" } {
            let plan = (resolve-effective-plan $home)
            let dests = ($plan.links | get dest_raw)
            assert ("~/.config/rog" in $dests)
            assert (not ("~/.config/OpenRGB" in $dests))
            # RFC-010: plan keeps ALL candidates; winner is chosen by resolve-link-targets
            let stars = ($plan.links | where dest_raw == "~/.config/starship.toml" | sort-by module_rank)
            assert equal ($stars | length) 2
            assert equal ($stars | get module_rank) [0, 1]
            assert equal ($stars | get module) ["base", "override"]
            assert equal ($stars | get origin_rank) [0, 0]
            # scope link carries the scope origin_rank (> 0)
            let rog = ($plan.links | where key == "rog" | first)
            assert ($rog.origin_rank > 0)
        }
    }
}

export def test_manifest_1_to_n_and_table_link_forms [] {
    with-temp-ygg { |home|
        let m = ($home | path join "modules" "m")
        mkdir $m
        'name = "m"
os = ["linux", "windows", "macos"]
[links]
"glazewm" = ["~/.config/glazewm", "~/.glzr/glazewm"]
[links."niri/cfg/*"]
target = "~/.config/niri/cfg/*"
on_change = "niri msg action reload-config"
[links."openrgb"]
target = "~/.config/OpenRGB"
mode = "dir"
[save]
"settings.json" = ["~/.config/app/s.json", "~/.local/share/app/s.json"]
' | save -f ($m | path join "ygg.toml")
        "[[modules]]\nname = \"m\"\n" | save -f ($home | path join "host.toml")

        let plan = (resolve-effective-plan $home)
        assert equal ($plan.links | where key == "glazewm" | length) 2
        let niri_entry = ($plan.links | where key == "niri/cfg/*" | first)
        assert equal $niri_entry.on_change "niri msg action reload-config"
        let orgb_entry = ($plan.links | where key == "openrgb" | first)
        assert equal $orgb_entry.mode "dir"
        assert equal ($plan.save | where key == "settings.json" | length) 2
    }
}

export def test_manifest_rejects_invalid_link_table_and_mode [] {
    with-temp-ygg { |home|
        let m = ($home | path join "modules" "m")
        mkdir $m
        # 1. Table without target
        "name = \"m\"\nos = [\"linux\", \"windows\", \"macos\"]\n[links.a]\non_change = \"echo 1\"\n" | save -f ($m | path join "ygg.toml")
        "[[modules]]\nname = \"m\"\n" | save -f ($home | path join "host.toml")
        assert (try { resolve-effective-plan $home; false } catch { true })

        # 2. Unknown mode (e.g. merge)
        "name = \"m\"\nos = [\"linux\", \"windows\", \"macos\"]\n[links.a]\ntarget = \"~/a\"\nmode = \"merge\"\n" | save -f ($m | path join "ygg.toml")
        assert (try { resolve-effective-plan $home; false } catch { true })

        # 3. mode with /*
        "name = \"m\"\nos = [\"linux\", \"windows\", \"macos\"]\n[links.\"a/*\"]\ntarget = \"~/a/*\"\nmode = \"dir\"\n" | save -f ($m | path join "ygg.toml")
        assert (try { resolve-effective-plan $home; false } catch { true })
    }
}

export def test_rejects_incompatible_os [] {
    let m = { name: "ai-dotfiles", os: ["cachyos"] }
    let win = { os: "windows", distro: "windows", auto_scopes: ["windows"] }
    assert equal (validate-module-os $m $win) false

    let cachy = { os: "linux", distro: "cachyos", auto_scopes: ["linux", "unix", "cachyos", "arch"] }
    assert equal (validate-module-os $m $cachy) true
}

export def test_load_and_save_host_config [] {
    with-temp-ygg { |home|
        # Missing host.toml returns default empty record
        let empty_cfg = (load-host-config $home)
        assert equal $empty_cfg.modules []

        let new_cfg = {
            modules: [
                { name: "core", scopes: ["work"], exclude: ["secret"] }
            ]
        }
        save-host-config $home $new_cfg
        let loaded = (load-host-config $home)
        assert equal ($loaded.modules | length) 1
        assert equal ($loaded.modules | first | get name) "core"
        assert equal ($loaded.modules | first | get scopes) ["work"]
    }
}

export def test_load_host_config_rejects_broken_toml [] {
    with-temp-ygg { |home|
        "[[modules\nname = bad\n" | save -f ($home | path join "host.toml")
        let failed = (try { load-host-config $home; false } catch { true })
        assert $failed
    }
}

export def test_load_module_manifest_with_merges [] {
    with-temp-ygg { |home|
        let mod_dir = ($home | path join "modules" "custom")
        mkdir $mod_dir

        'name = "custom"
os = ["linux", "macos"]
[config]
theme = "dark"
[links]
base_link = "~/.config/base"
[scope.work.links]
work_link = "~/.config/work"
' | save -f ($mod_dir | path join "ygg.toml")

        'pacman = ["pkg1"]
[scope.work]
pacman = ["pkg2"]
' | save -f ($mod_dir | path join "packages.toml")

        'extra_link = "~/.config/extra"
' | save -f ($mod_dir | path join "links.toml")

        'FOO = "bar"
' | save -f ($mod_dir | path join "env.toml")

        'my_alias = "echo test"
' | save -f ($mod_dir | path join "aliases.toml")

        let manifest = (load-module-manifest $mod_dir)
        assert equal $manifest.name "custom"
        assert equal $manifest.os ["linux", "macos"]
        assert equal $manifest.config.theme "dark"
        assert equal $manifest.links.base_link "~/.config/base"
        assert equal $manifest.links.extra_link "~/.config/extra"
        assert equal $manifest.packages.pacman ["pkg1"]
        assert equal $manifest.env.FOO "bar"
        assert equal $manifest.aliases.my_alias "echo test"
        assert equal $manifest.scope.work.links.work_link "~/.config/work"
        assert equal $manifest.scope.work.packages.pacman ["pkg2"]
    }
}

export def test_resolve_effective_plan_excludes_and_os_error [] {
    with-temp-ygg { |home|
        let m1 = ($home | path join "modules" "linux_only")
        mkdir $m1
        'name = "linux_only"
os = ["linux"]
[links]
l1 = "~/.config/l1"
l2 = "~/.config/l2"
' | save -f ($m1 | path join "ygg.toml")

        '[[modules]]
name = "linux_only"
exclude = ["l1"]
' | save -f ($home | path join "host.toml")

        with-env { YGG_HOST_OS_OVERRIDE: "linux" } {
            let plan = (resolve-effective-plan $home)
            let dests = ($plan.links | get dest_raw)
            assert ("~/.config/l2" in $dests)
            assert (not ("~/.config/l1" in $dests))
        }

        # Incompatible host OS must fail with error
        with-env { YGG_HOST_OS_OVERRIDE: "windows" } {
            let res = (try { resolve-effective-plan $home; false } catch { true })
            assert equal $res true
        }
    }
}

export def test_resolve_effective_plan_filter_and_config_merge [] {
    with-temp-ygg { |home|
        let m1 = ($home | path join "modules" "m1")
        let m2 = ($home | path join "modules" "m2")
        mkdir $m1 $m2

        'name = "m1"
os = ["linux", "windows", "macos"]
[config]
editor = "nano"
theme = "solarized"
[links]
m1_link = "~/.config/m1"
' | save -f ($m1 | path join "ygg.toml")

        'name = "m2"
os = ["linux", "windows", "macos"]
[config]
editor = "helix"
[links]
m2_link = "~/.config/m2"
' | save -f ($m2 | path join "ygg.toml")

        '[[modules]]
name = "m1"
config = { editor = "nvim" }
[[modules]]
name = "m2"
' | save -f ($home | path join "host.toml")

        with-env { YGG_HOST_OS_OVERRIDE: "linux" } {
            # Filter only m1
            let plan_filtered = (resolve-effective-plan $home --modules-filter ["m1"])
            assert equal ($plan_filtered.modules | length) 1
            let m1_resolved = ($plan_filtered.modules | first)
            assert equal $m1_resolved.config.editor "nvim"
            assert equal $m1_resolved.config.theme "solarized"
            assert equal ($plan_filtered.links | length) 1
            assert equal ($plan_filtered.links | first | get dest_raw) "~/.config/m1"
        }
    }
}

export def test_resolve_effective_plan_glob_links_multi_modules [] {
    with-temp-ygg { |home|
        let m1 = ($home | path join "modules" "m1")
        let m2 = ($home | path join "modules" "m2")
        mkdir $m1 $m2

        'name = "m1"
os = ["linux", "windows", "macos"]
[links]
"scripts/*" = "~/.zsh/scripts/"
' | save -f ($m1 | path join "ygg.toml")

        'name = "m2"
os = ["linux", "windows", "macos"]
[links]
"scripts/*" = "~/.zsh/scripts/"
' | save -f ($m2 | path join "ygg.toml")

        '[[modules]]
name = "m1"
[[modules]]
name = "m2"
' | save -f ($home | path join "host.toml")

        with-env { YGG_HOST_OS_OVERRIDE: "linux" } {
            let plan = (resolve-effective-plan $home)
            # Both glob links must be preserved
            let glob_links = ($plan.links | where is_glob)
            assert equal ($glob_links | length) 2
            assert equal ($glob_links | get module) ["m1", "m2"]
        }
    }
}

export def test_load_module_manifest_validation_failures [] {
    with-temp-ygg { |home|
        let bad1 = ($home | path join "modules" "no_name")
        let bad2 = ($home | path join "modules" "no_os")
        mkdir $bad1 $bad2

        'os = ["linux", "windows", "macos"]' | save -f ($bad1 | path join "ygg.toml")
        'name = "no_os"' | save -f ($bad2 | path join "ygg.toml")

        let res1 = (try { load-module-manifest $bad1; false } catch { true })
        assert equal $res1 true

        let res2 = (try { load-module-manifest $bad2; false } catch { true })
        assert equal $res2 true

        let res3 = (try { load-module-manifest ($home | path join "nonexistent"); false } catch { true })
        assert equal $res3 true
    }
}

export def test_plan_collects_path_from_modules_and_scopes [] {
    with-temp-ygg { |home|
        let m1 = ($home | path join "modules" "m1")
        let m2 = ($home | path join "modules" "m2")
        mkdir $m1 $m2

        'name = "m1"
os = ["linux", "windows"]
' | save -f ($m1 | path join "ygg.toml")

        'path = ["~/a"]
[scope.work]
path = ["~/b"]
' | save -f ($m1 | path join "env.toml")

        'name = "m2"
os = ["linux", "windows"]
' | save -f ($m2 | path join "ygg.toml")

        'path = ["~/a", "~/c"]
' | save -f ($m2 | path join "env.toml")

        '[[modules]]
name = "m1"
scopes = ["work"]
[[modules]]
name = "m2"
' | save -f ($home | path join "host.toml")

        let plan = (resolve-effective-plan $home)
        assert equal $plan.path ["~/a", "~/b", "~/c"]
    }
}

export def test_plan_rejects_percent_in_path [] {
    with-temp-ygg { |home|
        let m1 = ($home | path join "modules" "m1")
        mkdir $m1

        'name = "m1"
os = ["linux", "windows"]
' | save -f ($m1 | path join "ygg.toml")

        'path = ["%JAVA_HOME%/bin"]
' | save -f ($m1 | path join "env.toml")

        '[[modules]]
name = "m1"
' | save -f ($home | path join "host.toml")

        let failed = (try { resolve-effective-plan $home; false } catch { true })
        assert $failed
    }
}

export def test_manifest_module_dependencies_dag_and_cycle_detection [] {
    let mods = [
        { name: "hyprland", depends_on: ["waybar", "core"] },
        { name: "waybar", depends_on: ["core"] },
        { name: "core", depends_on: [] }
    ]
    let sorted = (sort-modules-dag $mods)
    let names = ($sorted | get name)
    assert ($names == ["core", "waybar", "hyprland"]) "Expected topological order [core, waybar, hyprland]"
    
    # Циклическая зависимость должна выбрасывать структурированную ошибку
    let cyclic = [
        { name: "A", depends_on: ["B"] },
        { name: "B", depends_on: ["A"] }
    ]
    let err = (try { sort-modules-dag $cyclic; "" } catch { |e| $e.msg })
    assert ($err =~ "Cyclic module dependency") "Expected cyclic dependency error"
}

export def test_manifest_resolve_plan_sorts_modules_topologically [] {
    with-temp-ygg { |home|
        let m_core = ($home | path join "modules" "core")
        let m_waybar = ($home | path join "modules" "waybar")
        let m_hypr = ($home | path join "modules" "hyprland")
        mkdir $m_core $m_waybar $m_hypr

        'name = "core"
os = ["linux", "windows", "macos"]
' | save -f ($m_core | path join "ygg.toml")

        'name = "waybar"
os = ["linux", "windows", "macos"]
depends_on = ["core"]
' | save -f ($m_waybar | path join "ygg.toml")

        'name = "hyprland"
os = ["linux", "windows", "macos"]
depends_on = ["waybar", "core"]
' | save -f ($m_hypr | path join "ygg.toml")

        # In host.toml, declare them in REVERSE order
        '[[modules]]
name = "hyprland"
[[modules]]
name = "waybar"
[[modules]]
name = "core"
' | save -f ($home | path join "host.toml")

        let plan = (resolve-effective-plan $home)
        let order = ($plan.modules | get name)
        assert equal $order ["core", "waybar", "hyprland"]
    }
}

export def test_preflight_detects_missing_module_dependency [] {
    with-temp-ygg { |home|
        let m_app = ($home | path join "modules" "app")
        mkdir $m_app

        'name = "app"
os = ["linux", "windows", "macos"]
depends_on = ["missing-mod"]
' | save -f ($m_app | path join "ygg.toml")

        '[[modules]]
name = "app"
' | save -f ($home | path join "host.toml")

        let plan = (resolve-effective-plan $home)
        let problems = (preflight-check $home $plan)
        assert equal ($problems | get reason) ["missing_dependency"]
        assert equal ($problems | get module) ["app"]
        assert ($problems | first | get detail | str contains "missing-mod")
    }
}

export def test_eval_scope_expressions [] {
    let scopes = ["linux", "pc", "cachyos"]
    assert (eval-scope-expression "linux and pc" $scopes) "Expected true for 'linux and pc'"
    assert (eval-scope-expression "linux and !work" $scopes) "Expected true for 'linux and !work'"
    assert (not (eval-scope-expression "windows or work" $scopes)) "Expected false for 'windows or work'"
    assert (eval-scope-expression "(cachyos or arch) and !windows" $scopes) "Expected true for complex condition"
    assert (eval-scope-expression "linux" $scopes) "Expected true for simple scope"
    assert (not (eval-scope-expression "work" $scopes)) "Expected false for missing simple scope"
    assert (eval-scope-expression "not work" $scopes) "Expected true for 'not work'"
    assert (eval-scope-expression "!work and (pc or laptop)" $scopes) "Expected true for '!work and (pc or laptop)'"
    assert (not (eval-scope-expression "!(pc or cachyos)" $scopes)) "Expected false for '!(pc or cachyos)'"
}

export def test_scope_expressions_in_resolve_effective_plan [] {
    with-temp-ygg { |home|
        let m = ($home | path join "modules" "scoped")
        mkdir $m
        'name = "scoped"
os = ["cachyos"]
[packages]
pacman = ["base-pkg"]
[scope."linux and !work".links]
monitor = "~/.config/monitor.kdl"
[scope."windows or laptop".links]
laptop = "~/.config/laptop.kdl"
[scope."linux and (arch or cachyos)".packages]
pacman = ["libva-nvidia-driver"]
' | save -f ($m | path join "ygg.toml")

        '[[modules]]
name = "scoped"
scopes = ["pc"]
' | save -f ($home | path join "host.toml")

        with-env { YGG_HOST_OS_OVERRIDE: "cachyos" } {
            let plan = (resolve-effective-plan $home)
            let dests = ($plan.links | get dest_raw)
            assert ("~/.config/monitor.kdl" in $dests)
            assert (not ("~/.config/laptop.kdl" in $dests))
            assert ("libva-nvidia-driver" in ($plan.packages | get pacman))
            assert ("base-pkg" in ($plan.packages | get pacman))
        }
    }
}

export def test_manifest_declarative_services_merge [] {
    with-temp-ygg { |home|
        let m = ($home | path join "modules" "svcmod")
        mkdir $m
        'name = "svcmod"
os = ["linux", "windows", "macos"]

[services.systemd.user]
enable = ["syncthing.service"]
reload_on_change = { "waybar.service" = ["config.jsonc"] }

[scope.linux.services.systemd.user]
reload_on_change = { "waybar.service" = ["style.css"] }
restart_on_change = { "ollama.service" = ["config.json"] }
' | save -f ($m | path join "ygg.toml")

        '[[modules]]
name = "svcmod"
' | save -f ($home | path join "host.toml")

        with-env { YGG_HOST_OS_OVERRIDE: "linux" } {
            let plan = (resolve-effective-plan $home)
            assert ($plan.services? != null)
            let sys_user = $plan.services.systemd.user
            assert equal $sys_user.enable ["syncthing.service"]
            let waybar_triggers = ($sys_user.reload_on_change | get "waybar.service")
            assert ("config.jsonc" in $waybar_triggers)
            assert ("style.css" in $waybar_triggers)
            let ollama_triggers = ($sys_user.restart_on_change | get "ollama.service")
            assert equal $ollama_triggers ["config.json"]
        }
    }
}





export def test_dag_sort_is_stable_to_host_order [] {
    let mods = [{ name: "a" }, { name: "b", depends_on: ["c"] }, { name: "c" }, { name: "d" }]
    assert equal (sort-modules-dag $mods | get name) ["a", "c", "b", "d"]
    let plain = [{ name: "z" }, { name: "y" }, { name: "x" }]
    assert equal (sort-modules-dag $plain | get name) ["z", "y", "x"]
    let cyc = [{ name: "a" }, { name: "p", depends_on: ["q"] }, { name: "q", depends_on: ["p"] }]
    let msg = (try { sort-modules-dag $cyc; "" } catch { |e| $e.msg })
    assert ($msg | str contains "p"); assert ($msg | str contains "q")
    assert (not ($msg =~ '\ba\b'))
}

# ygg.toml keys are portable: a foreign separator ("/" on Windows, "\" on Unix) becomes the native one
# in src_path, like expand-target-path does for destinations
export def test_manifest_src_path_uses_native_separator [] {
    with-temp-ygg { |home|
        let m = ($home | path join "modules" "m")
        let foreign = if $nu.os-info.family == "windows" { "/" } else { "\\" }
        let sep = (char path_sep)
        let link_key = $"pc($foreign)a.kdl"
        let save_key = $"app($foreign)s.json"
        mkdir ($m | path join "pc") ($m | path join "app") ($m | path join "cfg" "sub")
        "k\n" | save -f ($m | path join "pc" "a.kdl")
        "{}" | save -f ($m | path join "app" "s.json")
        ([
            'name = "m"'
            'os = ["linux", "windows", "macos"]'
            '[links]'
            $"'($link_key)' = \"~/.config/early/a.kdl\""
            '"cfg/sub/*" = "~/.config/sub/*"'
            '[save]'
            $"'($save_key)' = \"~/.config/app/s.json\""
        ] | str join "\n") | save -f ($m | path join "ygg.toml")
        "[[modules]]\nname = \"m\"\n" | save -f ($home | path join "host.toml")

        let plan = (resolve-effective-plan $home)
        let link_src = ($plan.links | where key == $link_key | get 0.src_path)
        let glob_src = ($plan.links | where key == "cfg/sub/*" | get 0.src_path)
        let save_src = ($plan.save | where key == $save_key | get 0.src_path)
        assert ($link_src | str ends-with $"($sep)pc($sep)a.kdl") $"link src_path not native: ($link_src)"
        assert ($glob_src | str ends-with $"($sep)cfg($sep)sub") $"glob src_path not native: ($glob_src)"
        assert ($save_src | str ends-with $"($sep)app($sep)s.json") $"save src_path not native: ($save_src)"
        assert ($link_src | path exists)
        assert ($save_src | path exists)
    }
}
