use std/assert
use ../src/state.nu [ensure-ygg-dirs]
use ../src/link.nu [is-link-or-junction]
use ../scripts/release.nu [read-ygg-version]
use helpers.nu [with-temp-ygg, test-link-dir, test-dangling-link]

export def test_preflight_blocks_missing_link_source_before_packages [] {
    with-temp-ygg { |home|
        let sb = ($home | path join "sb")
        let pkg_log = ($home | path join "pkg.log")
        let mod_src = ($home | path join "bad-mod")
        mkdir $mod_src
        mkdir ($sb | path join ".config" "ollama")
        "host_model_state" | save -f ($sb | path join ".config" "ollama" "models.txt")

        'name = "bad-mod"
os = ["linux", "windows", "macos", "cachyos"]
[packages]
pacman = ["curl"]
[links]
"configs/ollama" = "~/.config/ollama"
"missing/glob/*" = "~/.config/glob/*"
' | save -f ($mod_src | path join "ygg.toml")

        mkdir ($home | path join "modules")
        test-link-dir $mod_src ($home | path join "modules" "bad-mod")
        "[[modules]]\nname = \"bad-mod\"\n" | save -f ($home | path join "host.toml")

        let ygg_bin = ($env.FILE_PWD | path join "../bin/ygg.nu" | path expand)
        let res = (with-env {
            YGG_HOME: $home,
            YGG_SANDBOX: $sb,
            YGG_HOST_OS_OVERRIDE: "cachyos",
            YGG_MOCK_PKG_LOG: $pkg_log
        } { ^nu $ygg_bin apply --force --sandbox $sb | complete })

        assert ($res.exit_code != 0)
        assert ($res.stderr | str contains "configs/ollama")
        assert ($res.stderr | str contains "missing/glob/*")
        assert (not ($pkg_log | path exists))
        assert equal (open --raw ($sb | path join ".config" "ollama" "models.txt")) "host_model_state"
    }
}

export def test_preflight_missing_source_points_to_manifest [] {
    with-temp-ygg { |home|
        let sb = ($home | path join "sb")
        let pkg_log = ($home | path join "pkg.log")
        let mod_src = ($home | path join "bad-mod")
        mkdir $mod_src
        mkdir ($sb | path join ".config" "ollama")
        "host_model_state" | save -f ($sb | path join ".config" "ollama" "models.txt")

        'name = "bad-mod"
os = ["linux", "windows", "macos", "cachyos"]
[packages]
pacman = ["curl"]
[links]
"configs/ollama" = "~/.config/ollama"
' | save -f ($mod_src | path join "ygg.toml")

        mkdir ($home | path join "modules")
        test-link-dir $mod_src ($home | path join "modules" "bad-mod")
        "[[modules]]\nname = \"bad-mod\"\n" | save -f ($home | path join "host.toml")

        let ygg_bin = ($env.FILE_PWD | path join "../bin/ygg.nu" | path expand)
        let res = (with-env {
            YGG_HOME: $home,
            YGG_SANDBOX: $sb,
            YGG_HOST_OS_OVERRIDE: "cachyos",
            YGG_MOCK_PKG_LOG: $pkg_log
        } { ^nu $ygg_bin apply --force --sandbox $sb | complete })

        assert ($res.exit_code != 0)
        let flat_err = ($res.stderr | str replace --all --regex '\r?\n\s*\|\s*' ' ')
        assert ($flat_err | str contains "source 'configs/ollama' not found in module (links: 'configs/ollama' -> '~/.config/ollama')")
        assert not ($flat_err | str contains ($home | path join "modules" "bad-mod"))
        assert not ($flat_err | str contains $mod_src)
        assert not ($flat_err | str contains "committed and pushed")

        mkdir ($mod_src | path join ".git")
        let res2 = (with-env {
            YGG_HOME: $home,
            YGG_SANDBOX: $sb,
            YGG_HOST_OS_OVERRIDE: "cachyos",
            YGG_MOCK_PKG_LOG: $pkg_log
        } { ^nu $ygg_bin apply --force --sandbox $sb | complete })
        assert ($res2.exit_code != 0)
        let flat_err2 = ($res2.stderr | str replace --all --regex '\r?\n\s*\|\s*' ' ')
        assert ($flat_err2 | str contains "committed and pushed")
    }
}

export def test_preflight_shadowed_files_module_relative [] {
    with-temp-ygg { |home|
        let sb = ($home | path join "sb")
        let mod_src = ($home | path join "m")
        mkdir ($mod_src | path join "cfg" "app")
        mkdir ($sb | path join ".config" "app")
        "mod_file\n" | save -f ($mod_src | path join "cfg" "app" "a.conf")
        "extra_host\n" | save -f ($sb | path join ".config" "app" "extra.conf")

        'name = "m"
os = ["linux", "windows", "macos", "cachyos"]
[links]
"cfg/app" = "~/.config/app"
' | save -f ($mod_src | path join "ygg.toml")

        mkdir ($home | path join "modules")
        test-link-dir $mod_src ($home | path join "modules" "m")
        "[[modules]]\nname = \"m\"\n" | save -f ($home | path join "host.toml")

        let ygg_bin = ($env.FILE_PWD | path join "../bin/ygg.nu" | path expand)
        let res = (with-env {
            YGG_HOME: $home,
            YGG_SANDBOX: $sb,
            YGG_HOST_OS_OVERRIDE: "cachyos",
            YGG_MOCK_PKG_LOG: ($home | path join "pkg.log")
        } { ^nu $ygg_bin apply --sandbox $sb | complete })

        assert ($res.exit_code != 0)
        assert ($res.stderr | str contains "(shadowed_files)")
        assert ($res.stderr | str contains "not present in 'm/cfg/app'")
    }
}








