# tests/test_manifest.nu
use std/assert
use ../src/manifest.nu *
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
os = ["linux"]
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
os = ["linux"]
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
        "name = \"m\"\nos = [\"linux\"]\n[links.a]\non_change = \"echo 1\"\n" | save -f ($m | path join "ygg.toml")
        "[[modules]]\nname = \"m\"\n" | save -f ($home | path join "host.toml")
        assert (try { resolve-effective-plan $home; false } catch { true })

        # 2. Unknown mode (e.g. merge)
        "name = \"m\"\nos = [\"linux\"]\n[links.a]\ntarget = \"~/a\"\nmode = \"merge\"\n" | save -f ($m | path join "ygg.toml")
        assert (try { resolve-effective-plan $home; false } catch { true })

        # 3. mode with /*
        "name = \"m\"\nos = [\"linux\"]\n[links.\"a/*\"]\ntarget = \"~/a/*\"\nmode = \"dir\"\n" | save -f ($m | path join "ygg.toml")
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
os = ["linux"]
[config]
editor = "nano"
theme = "solarized"
[links]
m1_link = "~/.config/m1"
' | save -f ($m1 | path join "ygg.toml")

        'name = "m2"
os = ["linux"]
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
os = ["linux"]
[links]
"scripts/*" = "~/.zsh/scripts/"
' | save -f ($m1 | path join "ygg.toml")

        'name = "m2"
os = ["linux"]
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

        'os = ["linux"]' | save -f ($bad1 | path join "ygg.toml")
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

