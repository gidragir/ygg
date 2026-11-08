# tests/test_link.nu
# Test suite for link.nu (file linker, unfolding, 3-way sync, pruning)

use std/assert
use ../src/state.nu *
use ../src/manifest.nu *
use ../src/link.nu *
use helpers.nu [with-temp-ygg]

export def test_glob_shared_dir_and_ownership_conflict [] {
    with-temp-ygg { |home|
        let sb = ($home | path join "sb")
        let m1 = ($home | path join "modules" "m1")
        let m2 = ($home | path join "modules" "m2")
        mkdir ($m1 | path join "scripts") ($m2 | path join "scripts")
        "#!/bin/sh\necho 1\n" | save -f ($m1 | path join "scripts" "a.sh")
        "#!/bin/sh\necho 2\n" | save -f ($m2 | path join "scripts" "b.sh")
        "name = \"m1\"\nos = [\"linux\"]\n[links]\n\"scripts/*\" = \"~/.zsh/scripts/\"\n" | save -f ($m1 | path join "ygg.toml")
        "name = \"m2\"\nos = [\"linux\"]\n[links]\n\"scripts/*\" = \"~/.zsh/scripts/\"\n" | save -f ($m2 | path join "ygg.toml")
        "[[modules]]\nname = \"m1\"\n[[modules]]\nname = \"m2\"\n" | save -f ($home | path join "host.toml")

        let plan = (resolve-effective-plan $home)
        apply-links $home $plan --sandbox $sb
        assert (($sb | path join ".zsh/scripts/a.sh" | path exists))
        assert (($sb | path join ".zsh/scripts/b.sh" | path exists))
        assert (not (is-link-or-junction ($sb | path join ".zsh/scripts")))
    }
}

export def test_glob_shared_dir_ownership_conflict_error [] {
    with-temp-ygg { |home|
        let sb = ($home | path join "sb")
        mkdir ($sb | path join "target_dir")
        let link_dest = ($sb | path join ".zsh/scripts")
        mkdir ($link_dest | path dirname)
        ^ln -s ($sb | path join "target_dir") $link_dest

        let m = ($home | path join "modules" "m1")
        mkdir ($m | path join "scripts")
        "#!/bin/sh\necho 1\n" | save -f ($m | path join "scripts" "a.sh")
        "name = \"m1\"\nos = [\"linux\"]\n[links]\n\"scripts/*\" = \"~/.zsh/scripts/\"\n" | save -f ($m | path join "ygg.toml")
        "[[modules]]\nname = \"m1\"\n" | save -f ($home | path join "host.toml")

        let plan = (resolve-effective-plan $home)
        let failed = (try {
            apply-links $home $plan --sandbox $sb
            false
        } catch { |e|
            $e.msg | str contains "ownership conflict"
        })
        assert $failed
    }
}

export def test_replaces_dangling_symlink_without_backup [] {
    with-temp-ygg { |home|
        let sb = ($home | path join "sb")
        mkdir ($sb | path join ".config")
        let dest = ($sb | path join ".config" "starship.toml")
        ^ln -s "/nonexistent/dead/target" $dest

        let m1 = ($home | path join "modules" "core")
        mkdir $m1
        "add_newline = false\n" | save -f ($m1 | path join "starship.toml")
        "name = \"core\"\nos = [\"linux\"]\n[links]\n\"starship.toml\" = \"~/.config/starship.toml\"\n" | save -f ($m1 | path join "ygg.toml")
        "[[modules]]\nname = \"core\"\n" | save -f ($home | path join "host.toml")

        apply-links $home (resolve-effective-plan $home) --sandbox $sb
        assert (($dest | path exists))
        let backups = (glob ($home | path join ".state/backups/**/*"))
        assert ($backups | is-empty)
    }
}

export def test_scope_switch_prunes_old_links_safely [] {
    with-temp-ygg { |home|
        let sb = ($home | path join "sb")
        let m1 = ($home | path join "modules" "dotfiles")
        mkdir ($m1 | path join "openrgb") ($m1 | path join "rog")
        "preset\n" | save -f ($m1 | path join "openrgb" "off.orp")
        "fan\n" | save -f ($m1 | path join "rog" "rog.cfg")
        'name = "dotfiles"
os = ["linux"]
[scope.pc.links]
openrgb = "~/.config/OpenRGB"
[scope.asus.links]
rog = "~/.config/rog"' | save -f ($m1 | path join "ygg.toml")

        '[[modules]]
name = "dotfiles"
scopes = ["pc"]' | save -f ($home | path join "host.toml")
        apply-links $home (resolve-effective-plan $home) --sandbox $sb
        assert (($sb | path join ".config/OpenRGB/off.orp" | path exists))

        '[[modules]]
name = "dotfiles"
scopes = ["asus"]' | save -f ($home | path join "host.toml")
        apply-links $home (resolve-effective-plan $home) --sandbox $sb
        assert (not ($sb | path join ".config/OpenRGB" | path exists))
        assert (($m1 | path join "openrgb/off.orp" | path exists))
        assert (($sb | path join ".config/rog/rog.cfg" | path exists))
    }
}

export def test_three_way_copy_sync_preserves_host_gui_edits [] {
    with-temp-ygg { |home|
        let sb = ($home | path join "sb")
        let m1 = ($home | path join "modules" "win")
        mkdir ($m1 | path join "terminal") ($sb | path join "AppData/Local/Packages/Microsoft.WindowsTerminal_123/LocalState")
        let repo_file = ($m1 | path join "terminal/settings.json")
        let host_file = ($sb | path join "AppData/Local/Packages/Microsoft.WindowsTerminal_123/LocalState/settings.json")
        '{"theme":"dark"}' | save -f $repo_file
        '{"theme":"default"}' | save -f $host_file

        'name = "win"
os = ["windows"]
[save]
"terminal/settings.json" = "~/AppData/Local/Packages/Microsoft.WindowsTerminal_*/LocalState/settings.json"' | save -f ($m1 | path join "ygg.toml")
        "[[modules]]\nname = \"win\"\n" | save -f ($home | path join "host.toml")

        with-env { YGG_HOST_OS_OVERRIDE: "windows" } {
            # 1. Initial apply (--force seeds host from module)
            apply-links $home (resolve-effective-plan $home) --sandbox $sb --force
            assert equal (open --raw $host_file) '{"theme":"dark"}'

            # 2. User edits file on host via GUI; next apply pulls change back into module
            '{"theme":"catppuccin"}' | save -f $host_file
            apply-links $home (resolve-effective-plan $home) --sandbox $sb
            assert equal (open --raw $repo_file) '{"theme":"catppuccin"}'
        }
    }
}

export def test_is_link_or_junction [] {
    with-temp-ygg { |home|
        let real_file = ($home | path join "file.txt")
        let real_dir = ($home | path join "dir")
        "test\n" | save -f $real_file
        mkdir $real_dir

        let valid_link = ($home | path join "valid_link")
        let dead_link = ($home | path join "dead_link")
        ^ln -s $real_file $valid_link
        ^ln -s ($home | path join "nonexistent") $dead_link

        assert (is-link-or-junction $valid_link)
        assert (is-link-or-junction $dead_link)
        assert (not (is-link-or-junction $real_file))
        assert (not (is-link-or-junction $real_dir))
        assert (not (is-link-or-junction ($home | path join "nonexistent_file")))
    }
}

export def test_remove_link_only_safety [] {
    with-temp-ygg { |home|
        let real_dir = ($home | path join "real_dir")
        mkdir $real_dir
        "content\n" | save -f ($real_dir | path join "file.txt")

        let dir_link = ($home | path join "dir_link")
        ^ln -s $real_dir $dir_link

        # Removing link removes ONLY the link
        remove-link-only $dir_link
        assert (not ($dir_link | path exists))
        assert (($real_dir | path join "file.txt" | path exists))

        # Attempting to call remove-link-only on a real directory raises error
        let failed = (try {
            remove-link-only $real_dir
            false
        } catch { true })
        assert $failed
    }
}

export def test_unlink_module [] {
    with-temp-ygg { |home|
        let sb = ($home | path join "sb")
        let m1 = ($home | path join "modules" "m1")
        mkdir $m1
        "test content\n" | save -f ($m1 | path join "file.txt")
        "name = \"m1\"\nos = [\"linux\"]\n[links]\n\"file.txt\" = \"~/.config/file.txt\"\n" | save -f ($m1 | path join "ygg.toml")
        "[[modules]]\nname = \"m1\"\n" | save -f ($home | path join "host.toml")

        let plan = (resolve-effective-plan $home)
        apply-links $home $plan --sandbox $sb
        assert (($sb | path join ".config/file.txt" | path exists))

        let count = (unlink-module $home "m1")
        assert equal $count 1
        assert (not ($sb | path join ".config/file.txt" | path exists))
        assert (($m1 | path join "file.txt" | path exists))
    }
}

export def test_save_copied_files [] {
    with-temp-ygg { |home|
        let sb = ($home | path join "sb")
        let m1 = ($home | path join "modules" "win")
        mkdir ($m1 | path join "terminal") ($sb | path join "terminal")
        let repo_file = ($m1 | path join "terminal/settings.json")
        let host_file = ($sb | path join "terminal/settings.json")
        '{"theme":"dark"}' | save -f $repo_file
        '{"theme":"light"}' | save -f $host_file

        'name = "win"
os = ["windows"]
[save]
"terminal/settings.json" = "~/terminal/settings.json"' | save -f ($m1 | path join "ygg.toml")
        "[[modules]]\nname = \"win\"\n" | save -f ($home | path join "host.toml")

        with-env { YGG_HOST_OS_OVERRIDE: "windows" } {
            apply-links $home (resolve-effective-plan $home) --sandbox $sb --force
            assert equal (open --raw $host_file) '{"theme":"dark"}'

            '{"theme":"dracula"}' | save -f $host_file
            let saved = (save-copied-files $home (resolve-effective-plan $home))
            assert (($saved | length) > 0)
            assert equal (open --raw $repo_file) '{"theme":"dracula"}'
        }
    }
}

export def test_apply_links_dry_run [] {
    with-temp-ygg { |home|
        let sb = ($home | path join "sb")
        let m1 = ($home | path join "modules" "m1")
        mkdir $m1
        "test content\n" | save -f ($m1 | path join "file.txt")
        "name = \"m1\"\nos = [\"linux\"]\n[links]\n\"file.txt\" = \"~/.config/file.txt\"\n" | save -f ($m1 | path join "ygg.toml")
        "[[modules]]\nname = \"m1\"\n" | save -f ($home | path join "host.toml")

        let plan = (resolve-effective-plan $home)
        apply-links $home $plan --sandbox $sb --dry-run
        assert (not ($sb | path join ".config/file.txt" | path exists))
        let st = (load-state $home)
        assert ($st.links | columns | is-empty)
    }
}

export def test_windows_cmd_shim_generation_and_cleanup [] {
    with-temp-ygg { |home|
        let sb = ($home | path join "sb")
        let m1 = ($home | path join "modules" "scripts")
        mkdir ($m1 | path join "bin") ($sb | path join ".local" "bin")
        "print 'hello from nu'" | save -f ($m1 | path join "bin" "hello.nu")

        'name = "scripts"
os = ["windows"]
[links]
"bin/hello.nu" = "~/.local/bin/hello.nu"' | save -f ($m1 | path join "ygg.toml")
        "[[modules]]\nname = \"scripts\"\n" | save -f ($home | path join "host.toml")

        with-env { YGG_HOST_OS_OVERRIDE: "windows" } {
            let plan = (resolve-effective-plan $home)
            apply-links $home $plan --sandbox $sb
            let target_nu = ($sb | path join ".local" "bin" "hello.nu")
            let target_cmd = ($sb | path join ".local" "bin" "hello.cmd")
            assert ($target_nu | path exists)
            assert ($target_cmd | path exists)
            let cmd_content = (open --raw $target_cmd)
            assert ($cmd_content | str contains "nu \"%~dp0hello.nu\" %*")

            # Unlink removes both target script and .cmd shim
            unlink-module $home "scripts"
            assert (not ($target_nu | path exists))
            assert (not ($target_cmd | path exists))
        }
    }
}

export def test_unix_chmod_execution_in_bin [] {
    with-temp-ygg { |home|
        let sb = ($home | path join "sb")
        let m1 = ($home | path join "modules" "sh_mod")
        mkdir ($m1 | path join "bin")
        let script_file = ($m1 | path join "bin" "my_script.sh")
        "#!/bin/sh\necho test\n" | save -f $script_file
        # Remove execute permission initially
        ^chmod 644 $script_file

        'name = "sh_mod"
os = ["linux"]
[links]
"bin/my_script.sh" = "~/.local/bin/my_script.sh"' | save -f ($m1 | path join "ygg.toml")
        "[[modules]]\nname = \"sh_mod\"\n" | save -f ($home | path join "host.toml")

        let plan = (resolve-effective-plan $home)
        apply-links $home $plan --sandbox $sb
        # Verify script file is now executable on Unix
        let ls_res = (^ls -l $script_file | str trim)
        assert ($ls_res | str starts-with "-rwx")
    }
}

export def test_glob_dest_with_trailing_star [] {
    with-temp-ygg { |home|
        let sb = ($home | path join "sb")
        let m = ($home | path join "modules" "m")
        mkdir ($m | path join "bin")
        "#!/bin/sh\necho hi\n" | save -f ($m | path join "bin" "mytool")
        "name = \"m\"\nos = [\"linux\"]\n[links]\n\"bin/*\" = \"~/.local/bin/*\"\n" | save -f ($m | path join "ygg.toml")
        "[[modules]]\nname = \"m\"\n" | save -f ($home | path join "host.toml")

        apply-links $home (resolve-effective-plan $home) --sandbox $sb
        assert (($sb | path join ".local/bin/mytool" | path exists))
        assert (not ($sb | path join ".local/bin/*" | path exists))
    }
}

export def test_windows_glob_file_copies_survive_repeated_apply [] {
    with-temp-ygg { |home|
        let sb = ($home | path join "sb")
        let m = ($home | path join "modules" "app_cfg")
        mkdir ($m | path join "cfg")
        "v1\n" | save -f ($m | path join "cfg" "a.yaml")

        'name = "app_cfg"
os = ["windows"]
[links]
"cfg/*" = "~/.config/app/*"' | save -f ($m | path join "ygg.toml")
        "[[modules]]\nname = \"app_cfg\"\n" | save -f ($home | path join "host.toml")

        with-env { YGG_HOST_OS_OVERRIDE: "windows" } {
            let plan = (resolve-effective-plan $home)
            apply-links $home $plan --sandbox $sb
            apply-links $home $plan --sandbox $sb

            let target = ($sb | path join ".config" "app" "a.yaml")
            let state_json = ($home | path join ".state" "state.json")
            assert equal ($target | path type) "file"
            assert equal (open --raw $target) "v1\n"
            assert ($target in ((open $state_json).copies | columns))
            let backups = (glob ($home | path join ".state" "backups" "**" "a.yaml"))
            assert ($backups | is-empty)
        }
    }
}

export def test_windows_single_file_link_survives_repeated_apply [] {
    with-temp-ygg { |home|
        let sb = ($home | path join "sb")
        let m = ($home | path join "modules" "app_cfg")
        mkdir $m
        "v1\n" | save -f ($m | path join "app.toml")

        'name = "app_cfg"
os = ["windows"]
[links]
"app.toml" = "~/.config/app.toml"' | save -f ($m | path join "ygg.toml")
        "[[modules]]\nname = \"app_cfg\"\n" | save -f ($home | path join "host.toml")

        with-env { YGG_HOST_OS_OVERRIDE: "windows" } {
            let plan = (resolve-effective-plan $home)
            apply-links $home $plan --sandbox $sb
            apply-links $home $plan --sandbox $sb
            apply-links $home $plan --sandbox $sb

            let target = ($sb | path join ".config" "app.toml")
            assert equal (open --raw $target) "v1\n"
            let backups = (glob ($home | path join ".state" "backups" "**" "app.toml"))
            assert ($backups | is-empty)
        }
    }
}

export def test_windows_copy_three_way_for_link_and_glob [] {
    with-temp-ygg { |home|
        let sb = ($home | path join "sb")
        let m = ($home | path join "modules" "mod1")
        mkdir ($m | path join "cfg")
        "init-single\n" | save -f ($m | path join "single.toml")
        "init-glob\n" | save -f ($m | path join "cfg" "file.txt")

        'name = "mod1"
os = ["windows"]
[links]
"single.toml" = "~/.config/single.toml"
"cfg/*" = "~/.config/cfg/*"' | save -f ($m | path join "ygg.toml")
        "[[modules]]\nname = \"mod1\"\n" | save -f ($home | path join "host.toml")

        with-env { YGG_HOST_OS_OVERRIDE: "windows" } {
            let plan = (resolve-effective-plan $home)
            apply-links $home $plan --sandbox $sb

            let target_single = ($sb | path join ".config" "single.toml")
            let target_glob = ($sb | path join ".config" "cfg" "file.txt")
            let repo_single = ($m | path join "single.toml")
            let repo_glob = ($m | path join "cfg" "file.txt")

            assert equal (open --raw $target_single) "init-single\n"
            assert equal (open --raw $target_glob) "init-glob\n"

            # 1. Host edit -> apply -> module updated
            "host-edit-single\n" | save -f $target_single
            "host-edit-glob\n" | save -f $target_glob
            apply-links $home $plan --sandbox $sb
            assert equal (open --raw $repo_single) "host-edit-single\n"
            assert equal (open --raw $repo_glob) "host-edit-glob\n"

            # 2. Module edit -> apply -> host updated
            "mod-edit-single\n" | save -f $repo_single
            "mod-edit-glob\n" | save -f $repo_glob
            apply-links $home $plan --sandbox $sb
            assert equal (open --raw $target_single) "mod-edit-single\n"
            assert equal (open --raw $target_glob) "mod-edit-glob\n"

            # 3. Both sides different -> apply -> neither modified (conflict)
            "both-host-single\n" | save -f $target_single
            "both-mod-single\n" | save -f $repo_single
            "both-host-glob\n" | save -f $target_glob
            "both-mod-glob\n" | save -f $repo_glob
            apply-links $home $plan --sandbox $sb
            assert equal (open --raw $target_single) "both-host-single\n"
            assert equal (open --raw $repo_single) "both-mod-single\n"
            assert equal (open --raw $target_glob) "both-host-glob\n"
            assert equal (open --raw $repo_glob) "both-mod-glob\n"

            # 4. Apply with --force -> host = module, previous host version in backups
            apply-links $home $plan --sandbox $sb --force
            assert equal (open --raw $target_single) "both-mod-single\n"
            assert equal (open --raw $target_glob) "both-mod-glob\n"

            let b_single = (glob ($home | path join ".state" "backups" "**" "single.toml"))
            assert equal ($b_single | length) 1
            assert equal (open --raw ($b_single | first)) "both-host-single\n"

            let b_glob = (glob ($home | path join ".state" "backups" "**" "file.txt"))
            assert equal ($b_glob | length) 1
            assert equal (open --raw ($b_glob | first)) "both-host-glob\n"
        }
    }
}

export def test_windows_stale_copy_with_host_edit_goes_to_backups [] {
    with-temp-ygg { |home|
        let sb = ($home | path join "sb")
        let m = ($home | path join "modules" "app_cfg")
        mkdir ($m | path join "cfg")
        "v1\n" | save -f ($m | path join "cfg" "a.yaml")

        'name = "app_cfg"
os = ["windows"]
[links]
"cfg/*" = "~/.config/app/*"' | save -f ($m | path join "ygg.toml")
        "[[modules]]\nname = \"app_cfg\"\n" | save -f ($home | path join "host.toml")

        with-env { YGG_HOST_OS_OVERRIDE: "windows" } {
            let plan = (resolve-effective-plan $home)
            apply-links $home $plan --sandbox $sb

            let target = ($sb | path join ".config" "app" "a.yaml")
            assert ($target | path exists)

            # Host edit
            "edited-on-host\n" | save -f $target

            # Remove file from module
            rm ($m | path join "cfg" "a.yaml")

            # Apply again to prune stale links/copies
            let new_plan = (resolve-effective-plan $home)
            apply-links $home $new_plan --sandbox $sb

            assert (not ($target | path exists))
            let backups = (glob ($home | path join ".state" "backups" "**" "a.yaml"))
            assert equal ($backups | length) 1
            assert equal (open --raw ($backups | first)) "edited-on-host\n"
        }
    }
}

export def test_windows_stale_unedited_copy_is_removed_without_backup [] {
    with-temp-ygg { |home|
        let sb = ($home | path join "sb")
        let m = ($home | path join "modules" "app_cfg")
        mkdir ($m | path join "cfg")
        "v1\n" | save -f ($m | path join "cfg" "a.yaml")

        'name = "app_cfg"
os = ["windows"]
[links]
"cfg/*" = "~/.config/app/*"' | save -f ($m | path join "ygg.toml")
        "[[modules]]\nname = \"app_cfg\"\n" | save -f ($home | path join "host.toml")

        with-env { YGG_HOST_OS_OVERRIDE: "windows" } {
            let plan = (resolve-effective-plan $home)
            apply-links $home $plan --sandbox $sb

            let target = ($sb | path join ".config" "app" "a.yaml")
            assert ($target | path exists)

            # Remove file from module
            rm ($m | path join "cfg" "a.yaml")

            # Apply again to prune stale links/copies
            let new_plan = (resolve-effective-plan $home)
            apply-links $home $new_plan --sandbox $sb

            assert (not ($target | path exists))
            let backups = (glob ($home | path join ".state" "backups" "**" "a.yaml"))
            assert ($backups | is-empty)
        }
    }
}

export def test_windows_copy_turned_directory_is_backed_up [] {
    with-temp-ygg { |home|
        let sb = ($home | path join "sb")
        let m = ($home | path join "modules" "mod1")
        mkdir $m
        "file-content\n" | save -f ($m | path join "item")

        'name = "mod1"
os = ["windows"]
[links]
"item" = "~/.config/item"' | save -f ($m | path join "ygg.toml")
        "[[modules]]\nname = \"mod1\"\n" | save -f ($home | path join "host.toml")

        with-env { YGG_HOST_OS_OVERRIDE: "windows" } {
            # 1. First apply: "item" is a single file copy
            let plan1 = (resolve-effective-plan $home)
            apply-links $home $plan1 --sandbox $sb
            let target = ($sb | path join ".config" "item")
            assert equal ($target | path type) "file"
            assert equal (open --raw $target) "file-content\n"

            # 2. In module, replace file "item" with a directory "item" containing "sub.txt"
            rm ($m | path join "item")
            mkdir ($m | path join "item")
            "sub-content\n" | save -f ($m | path join "item" "sub.txt")

            # 3. Second apply: file should be backed up and junction (symlink) created without error
            let plan2 = (resolve-effective-plan $home)
            apply-links $home $plan2 --sandbox $sb
            assert equal ($target | path type) "symlink"
            assert equal (open --raw ($target | path join "sub.txt")) "sub-content\n"

            let backups = (glob ($home | path join ".state" "backups" "**" "item"))
            assert equal ($backups | length) 1
            assert equal (open --raw ($backups | first)) "file-content\n"
        }
    }
}
