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

export def test_save_skips_conflict_without_baseline [] {
    with-temp-ygg { |home|
        let sb = ($home | path join "sb")
        let m1 = ($home | path join "modules" "win")
        mkdir ($m1 | path join "terminal") ($sb | path join "terminal")
        let repo_file = ($m1 | path join "terminal/settings.json")
        let host_file = ($sb | path join "terminal/settings.json")
        let module_content = '{"theme":"dark"}'
        let host_content = '{"theme":"light"}'
        $module_content | save -f $repo_file
        $host_content | save -f $host_file

        'name = "win"
os = ["windows"]
[save]
"terminal/settings.json" = "~/terminal/settings.json"' | save -f ($m1 | path join "ygg.toml")
        "[[modules]]\nname = \"win\"\n" | save -f ($home | path join "host.toml")

        with-env { YGG_HOST_OS_OVERRIDE: "windows" } {
            let plan = (resolve-effective-plan $home)
            apply-links $home $plan --sandbox $sb
            let st = (load-state $home)
            let copy_record = ($st.copies | get $host_file)
            assert equal $copy_record.last_synced_hash ""

            let saved = (save-copied-files $home $plan --sandbox $sb)
            assert equal $saved []
            assert equal (open --raw $repo_file) $module_content

            let forced = (save-copied-files $home $plan --sandbox $sb --force)
            assert equal ($forced | length) 1
            assert equal (open --raw $repo_file) $host_content
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

export def test_ensure_executable_sets_mode_and_suppresses_stderr [] {
    with-temp-ygg { |home|
        let sb = ($home | path join "sb")
        let m = ($home | path join "modules" "m")
        mkdir ($m | path join "bin")
        let s = ($m | path join "bin" "tool.sh")
        "#!/bin/sh\necho ok\n" | save -f $s
        ^chmod 0644 $s
        'name = "m"
os = ["linux"]
[links]
"bin/tool.sh" = "~/.local/bin/tool.sh"
' | save -f ($m | path join "ygg.toml")
        "[[modules]]\nname = \"m\"\n" | save -f ($home | path join "host.toml")

        apply-links $home (resolve-effective-plan $home) --sandbox $sb
        let mode = (ls -lD $s | get 0.mode)
        let m9 = ($mode | str substring (($mode | str length) - 9)..)
        assert ($m9 =~ '^..x')
    }
}

export def test_resolve_link_targets_priority_rules_and_collisions [] {
    with-temp-ygg { |home|
        let sb = ($home | path join "sb")
        let early = ($home | path join "modules" "early")
        let late = ($home | path join "modules" "late")
        mkdir ($early | path join "pc") ($early | path join "zz") ($late | path join "cfg")
        "early-pc-a\n" | save -f ($early | path join "pc" "a.kdl")
        "early-scoped\n" | save -f ($early | path join "a.kdl")
        "early-base-other\n" | save -f ($early | path join "other.kdl")
        "early-zz-a\n" | save -f ($early | path join "zz" "a.kdl")
        "early-zz-b\n" | save -f ($early | path join "zz" "b.kdl")
        "early-same\n" | save -f ($early | path join "same.txt")
        "late-cfg-a\n" | save -f ($late | path join "cfg" "a.kdl")
        "late-cfg-b\n" | save -f ($late | path join "cfg" "b.kdl")
        "late-same\n" | save -f ($late | path join "same.txt")

        # Early module: explicit scope link into a dir that a LATER module globs into;
        # base key "a.kdl" retargeted by the scope must beat base glob "zz/*".
        'name = "early"
os = ["linux"]
[links]
"a.kdl" = "~/.config/y/other.kdl"
"zz/*" = "~/.config/y/*"
"same.txt" = "~/.config/same.txt"
[scope.pc.links]
"pc/a.kdl" = "~/.config/app/a.kdl"
"a.kdl" = "~/.config/y/a.kdl"
' | save -f ($early | path join "ygg.toml")

        # Late module: glob over ~/.config/app and an ABSOLUTE path equal to early's "~/.config/same.txt"
        let abs_same = ($sb | path join ".config" "same.txt")
        ('name = "late"
os = ["linux"]
[links]
"cfg/*" = "~/.config/app/*"
"same.txt" = "' + $abs_same + '"
') | save -f ($late | path join "ygg.toml")

        '[[modules]]
name = "early"
scopes = ["pc"]
[[modules]]
name = "late"
' | save -f ($home | path join "host.toml")

        let plan = (resolve-effective-plan $home)
        let resolved = (resolve-link-targets $plan --sandbox $sb)
        let t = $resolved.targets
        let app_a = ($sb | path join ".config" "app" "a.kdl")
        let app_b = ($sb | path join ".config" "app" "b.kdl")
        let y_a = ($sb | path join ".config" "y" "a.kdl")
        let y_b = ($sb | path join ".config" "y" "b.kdl")
        let y_other = ($sb | path join ".config" "y" "other.kdl")

        # Rule 1: explicit scope link of EARLY module beats glob of LATE module
        let w_app_a = ($t | where dest == $app_a)
        assert equal ($w_app_a | length) 1
        assert equal ($w_app_a | first | get module) "early"
        assert equal ($w_app_a | first | get src) ($early | path join "pc" "a.kdl")
        assert equal ($w_app_a | first | get is_glob_child) false
        # Glob file not claimed by anyone else is still produced
        let w_app_b = ($t | where dest == $app_b | first)
        assert equal $w_app_b.module "late"
        assert equal $w_app_b.is_glob_child true
        assert equal $w_app_b.glob_dest_dir ($sb | path join ".config" "app")

        # Rule 3 inside one module: scope-retargeted key beats base glob zz/*
        let w_y_a = ($t | where dest == $y_a | first)
        assert equal $w_y_a.src ($early | path join "a.kdl")
        assert equal ($t | where dest == $y_other | length) 0
        assert equal ($t | where dest == $y_b | first | get src) ($early | path join "zz" "b.kdl")

        # "~/x" and absolute path are one target; later module wins (rule 2)
        let w_same = ($t | where { |r| (normalize-case $r.dest) == (normalize-case $abs_same) })
        assert equal ($w_same | length) 1
        assert equal ($w_same | first | get module) "late"

        # Collisions: cross-module recorded, intra-module NOT recorded
        let c = $resolved.collisions
        let c_app_a = ($c | where dest == $app_a)
        assert equal ($c_app_a | length) 1
        assert equal ($c_app_a | first | get winner_module) "early"
        assert equal ($c_app_a | first | get loser_module) "late"
        assert equal ($c | where dest == $y_a | length) 0
        assert equal ($c | where { |r| ($r.dest | path basename) == "same.txt" } | length) 1
        assert ($resolved.nesting_conflicts | is-empty)

        # Unique destinations only
        assert equal ($t | get dest | uniq | length) ($t | length)

        # apply-links honours the resolution, and a second apply keeps glob/explicit overlap stable
        apply-links $home $plan --sandbox $sb | ignore
        assert equal (open --raw $app_a) "early-pc-a\n"
        assert equal (open --raw $app_b) "late-cfg-b\n"
        assert equal (open --raw $y_a) "early-scoped\n"
        assert equal (open --raw $abs_same) "late-same\n"
        let ino1 = (^stat -c "%i" $app_a | str trim)
        let res2 = (apply-links $home $plan --sandbox $sb)
        assert equal (^stat -c "%i" $app_a | str trim) $ino1
        assert ($res2.applied | is-empty)
    }

    # Nesting: an explicit directory link that is a parent of another target
    with-temp-ygg { |home|
        let sb = ($home | path join "sb")
        let m1 = ($home | path join "modules" "m1")
        let m2 = ($home | path join "modules" "m2")
        mkdir ($m1 | path join "dirsrc") $m2
        "x\n" | save -f ($m1 | path join "dirsrc" "inner.txt")
        "f\n" | save -f ($m2 | path join "f.txt")
        "name = \"m1\"\nos = [\"linux\"]\n[links]\n\"dirsrc\" = \"~/.config/nest\"\n" | save -f ($m1 | path join "ygg.toml")
        "name = \"m2\"\nos = [\"linux\"]\n[links]\n\"f.txt\" = \"~/.config/nest/f.txt\"\n" | save -f ($m2 | path join "ygg.toml")
        "[[modules]]\nname = \"m1\"\n[[modules]]\nname = \"m2\"\n" | save -f ($home | path join "host.toml")

        let plan = (resolve-effective-plan $home)
        let resolved = (resolve-link-targets $plan --sandbox $sb)
        let parent = ($resolved.targets | where key == "dirsrc" | first)
        assert equal $parent.is_dir true
        let n = $resolved.nesting_conflicts
        assert equal ($n | length) 1
        assert equal ($n | first | get parent_dest) ($sb | path join ".config" "nest")
        assert equal ($n | first | get child_dest) ($sb | path join ".config" "nest" "f.txt")
        assert equal ($n | first | get module) "m2"
        assert equal ($n | first | get key) "f.txt"

        # Nesting is reported by preflight-check (before package managers)
        let ops = (compute-link-ops $home $resolved --sandbox $sb)
        let problems = (preflight-check $home $plan $resolved $ops --sandbox $sb)
        assert equal ($problems | get reason) ["nesting_conflict"]
        assert ($problems | first | get detail | str contains "ownership conflict")

        # Nesting is an error even in dry-run, and nothing is created
        let err = (try { apply-links $home $plan --sandbox $sb --dry-run; "" } catch { |e| $e.msg })
        assert ($err | str contains "ownership conflict")
        assert (not ($sb | path join ".config" "nest" | path exists))
    }
}

export def test_link_target_matches_and_idempotent_inode [] {
    with-temp-ygg { |home|
        let sb = ($home | path join "sb")
        let wt1 = ($home | path join "wt1")
        let wt2 = ($home | path join "wt2")
        let manifest = "name = \"m\"\nos = [\"linux\"]\n[links]\n\"conf.toml\" = \"~/.config/conf.toml\"\n\"dirA\" = \"~/.config/thedir\"\n"
        for wt in [$wt1, $wt2] {
            mkdir ($wt | path join "dirA") ($wt | path join "dirB")
            "a\n" | save -f ($wt | path join "dirA" "x.txt")
            "b\n" | save -f ($wt | path join "dirB" "x.txt")
            $manifest | save -f ($wt | path join "ygg.toml")
        }
        "v1\n" | save -f ($wt1 | path join "conf.toml")
        "v2\n" | save -f ($wt2 | path join "conf.toml")
        mkdir ($home | path join "modules")
        let mod_link = ($home | path join "modules" "m")
        ^ln -s $wt1 $mod_link
        "[[modules]]\nname = \"m\"\n" | save -f ($home | path join "host.toml")

        let conf = ($sb | path join ".config" "conf.toml")
        let thedir = ($sb | path join ".config" "thedir")

        # 1. Repeated apply is a no-op: same inode, empty applied
        let r1 = (apply-links $home (resolve-effective-plan $home) --sandbox $sb)
        assert equal ($r1.applied | length) 2
        let ino_conf = (^stat -c "%i" $conf | str trim)
        let ino_dir = (^stat -c "%i" $thedir | str trim)
        let r2 = (apply-links $home (resolve-effective-plan $home) --sandbox $sb)
        assert ($r2.applied | is-empty)
        assert equal (^stat -c "%i" $conf | str trim) $ino_conf
        assert equal (^stat -c "%i" $thedir | str trim) $ino_dir

        # 2. Retarget module symlink to another worktree with the same files: still a match, inode kept
        ^ln -sfn $wt2 $mod_link
        assert (link-target-matches $conf ($mod_link | path join "conf.toml"))
        let r3 = (apply-links $home (resolve-effective-plan $home) --sandbox $sb)
        assert ($r3.applied | is-empty)
        assert equal (^stat -c "%i" $conf | str trim) $ino_conf
        assert equal (open --raw $conf) "v2\n"

        # 3. Source change -> atomic swap; no .ygg-tmp-* next to dest nor inside old dir
        "name = \"m\"\nos = [\"linux\"]\n[links]\n\"conf.toml\" = \"~/.config/conf.toml\"\n\"dirB\" = \"~/.config/thedir\"\n" | save -f ($wt2 | path join "ygg.toml")
        let r4 = (apply-links $home (resolve-effective-plan $home) --sandbox $sb)
        assert equal $r4.applied [$thedir]
        assert equal ($thedir | path type) "symlink"
        assert equal (link-literal-target $thedir) ($mod_link | path join "dirB")
        assert equal (open --raw ($thedir | path join "x.txt")) "b\n"
        let tmp_near = (ls -a ($sb | path join ".config") | where { |it| ($it.name | path basename) =~ 'ygg-tmp' })
        let tmp_inside = (ls -a ($wt2 | path join "dirA") | where { |it| ($it.name | path basename) =~ 'ygg-tmp' })
        assert ($tmp_near | is-empty)
        assert ($tmp_inside | is-empty)
        assert (($wt2 | path join "dirA" "x.txt") | path exists)

        # 4. link-target-matches unit cases
        let lt = ($home | path join "lt")
        mkdir ($lt | path join "real")
        let src = ($lt | path join "real" "file")
        "s\n" | save -f $src
        let other = ($lt | path join "real" "other")
        "o\n" | save -f $other
        let abs_link = ($lt | path join "abs_link")
        ^ln -s $src $abs_link
        let rel_link = ($lt | path join "rel_link")
        ^ln -s "real/file" $rel_link
        let chain = ($lt | path join "chain")
        ^ln -s $abs_link $chain
        let plain = ($lt | path join "plain")
        "p\n" | save -f $plain
        assert (link-target-matches $abs_link $src)
        assert (link-target-matches $rel_link $src)
        assert (link-target-matches $chain $src)
        assert (not (link-target-matches $abs_link $other))
        assert (not (link-target-matches $plain $src))
        assert (not (link-target-matches ($lt | path join "missing") $src))

        # 5. Two dangling links to one missing path with different literal spelling (via dir symlink) do not match
        let alias = ($lt | path join "alias")
        ^ln -s ($lt | path join "real") $alias
        let dead1 = ($lt | path join "dead1")
        ^ln -s ($lt | path join "real" "missing") $dead1
        assert (not (link-target-matches $dead1 ($alias | path join "missing")))
        assert equal (normalize-case "/a/b/") "/a/b"
    }
}

export def test_dir_copy_kept_on_apply_and_backed_up_on_prune_and_unlink [] {
    with-temp-ygg { |home|
        let sb = ($home | path join "sb")
        let m = ($home | path join "modules" "m")
        mkdir ($m | path join "cfgdir")
        "mod\n" | save -f ($m | path join "cfgdir" "a.txt")
        "name = \"m\"\nos = [\"windows\"]\n[links]\n\"cfgdir\" = \"~/.config/cfgdir\"\n" | save -f ($m | path join "ygg.toml")
        "[[modules]]\nname = \"m\"\n" | save -f ($home | path join "host.toml")
        let dest = ($sb | path join ".config" "cfgdir")

        # Simulate an RFC-006 fallback result: a real directory copy recorded as dir_copy
        mkdir $dest
        "host-edit\n" | save -f ($dest | path join "a.txt")
        mut st = (load-state $home)
        $st.links = ($st.links | upsert $dest { module: "m", src: ($m | path join "cfgdir"), type: "dir_copy", cmd_shim: "" })
        save-state $home $st

        with-env { YGG_HOST_OS_OVERRIDE: "windows" } {
            # Re-apply keeps the copy (OK with warning), no re-creation, no backup
            let r = (apply-links $home (resolve-effective-plan $home) --sandbox $sb)
            assert ($r.applied | is-empty)
            assert equal ($dest | path type) "dir"
            assert equal (open --raw ($dest | path join "a.txt")) "host-edit\n"
            assert equal ((load-state $home).links | get $dest | get type) "dir_copy"
            assert (glob ($home | path join ".state" "backups" "**" "a.txt") | is-empty)

            # unlink-module moves the copy to backups instead of leaving it untracked
            assert equal (unlink-module $home "m") 1
            assert (not ($dest | path exists))
            let b = (glob ($home | path join ".state" "backups" "**" "cfgdir" "a.txt"))
            assert equal ($b | length) 1
            assert equal (open --raw ($b | first)) "host-edit\n"
            assert (($m | path join "cfgdir" "a.txt") | path exists)

            # prune (link removed from manifest) also goes through backup-existing
            mkdir $dest
            "host-edit-2\n" | save -f ($dest | path join "a.txt")
            mut st2 = (load-state $home)
            $st2.links = ($st2.links | upsert $dest { module: "m", src: ($m | path join "cfgdir"), type: "dir_copy", cmd_shim: "" })
            save-state $home $st2
            "name = \"m\"\nos = [\"windows\"]\n" | save -f ($m | path join "ygg.toml")
            let r2 = (apply-links $home (resolve-effective-plan $home) --sandbox $sb)
            assert equal $r2.pruned [$dest]
            assert (not ($dest | path exists))
            let b2 = (glob ($home | path join ".state" "backups" "**" "cfgdir" "a.txt") | each { |f| open --raw $f })
            assert ("host-edit-2\n" in $b2)
        }
    }
}

# Run nushell code in a child process with src modules loaded; returns `complete` record (stdout/stderr capture)
def run-link-nu [code: string]: nothing -> record {
    let src = ($env.FILE_PWD | path join ".." "src" | path expand)
    let prelude = ("use " + ($src | path join "state.nu") + " *; use " + ($src | path join "manifest.nu") + " *; use " + ($src | path join "link.nu") + " *; ")
    ^nu -c ($prelude + $code) | complete
}

export def test_compute_link_ops_and_prune_first_on_dir_to_glob_transition [] {
    with-temp-ygg { |home|
        let sb = ($home | path join "sb")
        let m = ($home | path join "modules" "dotfiles")
        mkdir ($m | path join "OpenRGB")
        "preset\n" | save -f ($m | path join "OpenRGB" "off.orp")
        "name = \"dotfiles\"\nos = [\"linux\"]\n[links]\n\"OpenRGB\" = { target = \"~/.config/OpenRGB\", mode = \"dir\" }\n" | save -f ($m | path join "ygg.toml")
        "[[modules]]\nname = \"dotfiles\"\n" | save -f ($home | path join "host.toml")
        let dest = ($sb | path join ".config" "OpenRGB")

        # Fresh plan: LINK
        let p0 = (resolve-effective-plan $home)
        let ops0 = (compute-link-ops $home (resolve-link-targets $p0 --sandbox $sb) --sandbox $sb)
        assert equal ($ops0 | get op) ["LINK"]
        assert equal ($ops0 | first | get dest) $dest
        assert equal ($ops0 | columns | sort) ([op dest src module key detail] | sort)

        apply-links $home $p0 --sandbox $sb | ignore
        assert equal ($dest | path type) "symlink"
        # Repeated plan: OK only
        let ops1 = (compute-link-ops $home (resolve-link-targets $p0 --sandbox $sb) --sandbox $sb)
        assert equal ($ops1 | get op) ["OK"]

        # Switch to glob: PRUNE of the own old link comes first, then LINK of the child
        "name = \"dotfiles\"\nos = [\"linux\"]\n[links]\n\"OpenRGB/*\" = \"~/.config/OpenRGB/*\"\n" | save -f ($m | path join "ygg.toml")
        let p1 = (resolve-effective-plan $home)
        let r1 = (resolve-link-targets $p1 --sandbox $sb)
        let ops2 = (compute-link-ops $home $r1 --sandbox $sb)
        assert equal ($ops2 | first | get op) "PRUNE"
        assert equal ($ops2 | first | get dest) $dest
        assert equal ($ops2 | first | get detail) "unlink"
        assert equal ($ops2 | where op == "LINK" | get dest) [($dest | path join "off.orp")]
        assert ((preflight-check $home $p1 $r1 $ops2 --sandbox $sb) | is-empty)

        let res = (apply-links $home $p1 --sandbox $sb)
        assert equal $res.pruned [$dest]
        assert ($res.failed | is-empty)
        assert equal ($dest | path type) "dir"
        assert equal (($dest | path join "off.orp") | path type) "symlink"
        assert equal (open --raw ($m | path join "OpenRGB" "off.orp")) "preset\n"
    }

    # Unmanaged symlink at the glob root stays an ownership conflict (preflight and apply-links)
    with-temp-ygg { |home|
        let sb = ($home | path join "sb")
        let m = ($home | path join "modules" "dotfiles")
        mkdir ($m | path join "OpenRGB") ($sb | path join "elsewhere") ($sb | path join ".config")
        "preset\n" | save -f ($m | path join "OpenRGB" "off.orp")
        "foreign\n" | save -f ($sb | path join "elsewhere" "keep.txt")
        let dest = ($sb | path join ".config" "OpenRGB")
        ^ln -s ($sb | path join "elsewhere") $dest
        "name = \"dotfiles\"\nos = [\"linux\"]\n[links]\n\"OpenRGB/*\" = \"~/.config/OpenRGB/*\"\n" | save -f ($m | path join "ygg.toml")
        "[[modules]]\nname = \"dotfiles\"\n" | save -f ($home | path join "host.toml")

        let plan = (resolve-effective-plan $home)
        let r = (resolve-link-targets $plan --sandbox $sb)
        let ops = (compute-link-ops $home $r --sandbox $sb)
        assert (($ops | where op == "PRUNE") | is-empty)
        let problems = (preflight-check $home $plan $r $ops --sandbox $sb)
        assert equal ($problems | get reason) ["ownership_conflict"]
        let err = (try { apply-links $home $plan --sandbox $sb; "" } catch { |e| $e.msg })
        assert ($err | str contains "ownership_conflict")
        assert equal ($dest | path type) "symlink"
        assert (not (($sb | path join "elsewhere" "off.orp") | path exists))
        assert equal (ls ($sb | path join "elsewhere") | length) 1
    }
}

export def test_shadowed_files_blocks_unconfirmed_dir_replacement [] {
    let setup = { |home: string, link_value: string|
        let sb = ($home | path join "sb")
        let m = ($home | path join "modules" "dotfiles")
        mkdir ($m | path join "OpenRGB") ($sb | path join ".config" "OpenRGB")
        "preset\n" | save -f ($m | path join "OpenRGB" "off.orp")
        "host-preset\n" | save -f ($sb | path join ".config" "OpenRGB" "off.orp")
        "runtime\n" | save -f ($sb | path join ".config" "OpenRGB" "profile.orp")
        "calib\n" | save -f ($sb | path join ".config" "OpenRGB" ".calib")
        ("name = \"dotfiles\"\nos = [\"linux\"]\n[links]\n\"OpenRGB\" = " + $link_value + "\n") | save -f ($m | path join "ygg.toml")
        "[[modules]]\nname = \"dotfiles\"\n" | save -f ($home | path join "host.toml")
    }

    # 1. Plain directory link over a real host dir with extra files -> shadowed_files, host untouched
    with-temp-ygg { |home|
        do $setup $home '"~/.config/OpenRGB"'
        let sb = ($home | path join "sb")
        let dest = ($sb | path join ".config" "OpenRGB")
        let src = ($home | path join "modules" "dotfiles" "OpenRGB")
        assert equal (shadowed-files $dest $src) [".calib", "profile.orp"]

        let plan = (resolve-effective-plan $home)
        let r = (resolve-link-targets $plan --sandbox $sb)
        let ops = (compute-link-ops $home $r --sandbox $sb)
        assert equal ($ops | get op) ["BACKUP_REPLACE"]
        let problems = (preflight-check $home $plan $r $ops --sandbox $sb)
        assert equal ($problems | get reason) ["shadowed_files"]
        let detail = ($problems | first | get detail)
        assert ($detail | str contains "profile.orp")
        assert ($detail | str contains ".calib")
        assert ($detail | str contains "mode = \"dir\"")
        assert ($detail | str contains "--force")
        assert ($detail | str contains "OpenRGB/*")

        let err = (try { apply-links $home $plan --sandbox $sb; "" } catch { |e| $e.msg })
        assert ($err | str contains "shadowed_files")
        assert equal ($dest | path type) "dir"
        assert equal (ls -a $dest | length) 3
        assert (glob ($home | path join ".state" "backups" "**" "*") | is-empty)

        # --force: passes with a warning; old dir is moved into .state/backups with a notice
        let pf = (run-link-nu ("let p = (resolve-effective-plan '" + $home + "'); let r = (resolve-link-targets $p --sandbox '" + $sb + "'); let o = (compute-link-ops '" + $home + "' $r --force --sandbox '" + $sb + "'); preflight-check '" + $home + "' $p $r $o --force --sandbox '" + $sb + "' | length"))
        assert equal $pf.exit_code 0
        assert equal ($pf.stdout | str trim) "0"
        assert ($pf.stderr | str contains "profile.orp")
        let ap = (run-link-nu ("apply-links '" + $home + "' (resolve-effective-plan '" + $home + "') --force --sandbox '" + $sb + "' | to nuon"))
        assert equal $ap.exit_code 0
        assert ($ap.stdout | str contains ("[ygg] Backed up existing '" + $dest + "'"))
        assert equal ($dest | path type) "symlink"
        let bk = (glob ($home | path join ".state" "backups" "**" "OpenRGB" "profile.orp"))
        assert equal ($bk | length) 1
        assert ((($bk | first | path dirname) | path join ".calib") | path exists)
    }

    # 2. mode = "dir" confirms the replacement: warning + backup
    with-temp-ygg { |home|
        do $setup $home '{ target = "~/.config/OpenRGB", mode = "dir" }'
        let sb = ($home | path join "sb")
        let dest = ($sb | path join ".config" "OpenRGB")
        let plan = (resolve-effective-plan $home)
        let r = (resolve-link-targets $plan --sandbox $sb)
        assert ((preflight-check $home $plan $r (compute-link-ops $home $r --sandbox $sb) --sandbox $sb) | is-empty)
        let ap = (run-link-nu ("apply-links '" + $home + "' (resolve-effective-plan '" + $home + "') --sandbox '" + $sb + "' | to nuon"))
        assert equal $ap.exit_code 0
        assert ($ap.stderr | str contains "profile.orp")
        assert ($ap.stdout | str contains "[ygg] Backed up existing")
        assert equal ($dest | path type) "symlink"
        assert equal (glob ($home | path join ".state" "backups" "**" "OpenRGB" "profile.orp") | length) 1
    }

    # 3. Host dir whose files all exist in the source: no shadowing, preflight passes
    with-temp-ygg { |home|
        do $setup $home '"~/.config/OpenRGB"'
        let sb = ($home | path join "sb")
        rm ($sb | path join ".config" "OpenRGB" "profile.orp") ($sb | path join ".config" "OpenRGB" ".calib")
        let plan = (resolve-effective-plan $home)
        let r = (resolve-link-targets $plan --sandbox $sb)
        assert ((preflight-check $home $plan $r (compute-link-ops $home $r --sandbox $sb) --sandbox $sb) | is-empty)
    }

    # 4. mode = "dir" with a file source -> invalid_mode_source
    with-temp-ygg { |home|
        let sb = ($home | path join "sb")
        let m = ($home | path join "modules" "dotfiles")
        mkdir $m
        "x\n" | save -f ($m | path join "OpenRGB")
        "name = \"dotfiles\"\nos = [\"linux\"]\n[links]\n\"OpenRGB\" = { target = \"~/.config/OpenRGB\", mode = \"dir\" }\n" | save -f ($m | path join "ygg.toml")
        "[[modules]]\nname = \"dotfiles\"\n" | save -f ($home | path join "host.toml")
        let plan = (resolve-effective-plan $home)
        let r = (resolve-link-targets $plan --sandbox $sb)
        let problems = (preflight-check $home $plan $r (compute-link-ops $home $r --sandbox $sb) --sandbox $sb)
        assert equal ($problems | get reason) ["invalid_mode_source"]
    }
}

export def test_ensure_executable_follows_symlinked_source [] {
    with-temp-ygg { |home|
        let sb = ($home | path join "sb")
        let m = ($home | path join "modules" "m")
        mkdir ($m | path join "bin") ($m | path join "real")
        let real = ($m | path join "real" "tool.sh")
        "#!/bin/sh\necho ok\n" | save -f $real
        ^chmod 0644 $real
        ^ln -s $real ($m | path join "bin" "tool.sh")
        "name = \"m\"\nos = [\"linux\"]\n[links]\n\"bin/tool.sh\" = \"~/.local/bin/tool.sh\"\n" | save -f ($m | path join "ygg.toml")
        "[[modules]]\nname = \"m\"\n" | save -f ($home | path join "host.toml")

        apply-links $home (resolve-effective-plan $home) --sandbox $sb | ignore
        let mode = (ls -lD $real | get 0.mode)
        let m9 = ($mode | str substring (($mode | str length) - 9)..)
        assert ($m9 =~ '^..x')
    }
}

export def test_is_dir_consistent_for_symlinked_dir_sources [] {
    with-temp-ygg { |home|
        let sb = ($home | path join "sb")
        let m = ($home | path join "modules" "m")
        mkdir ($m | path join "realdir") ($m | path join "g")
        "x\n" | save -f ($m | path join "realdir" "x.txt")
        ^ln -s ($m | path join "realdir") ($m | path join "g" "linked")
        ^ln -s ($m | path join "realdir") ($m | path join "explicit")
        "name = \"m\"\nos = [\"linux\"]\n[links]\n\"g/*\" = \"~/.config/g/*\"\n\"explicit\" = \"~/.config/explicit\"\n" | save -f ($m | path join "ygg.toml")
        "[[modules]]\nname = \"m\"\n" | save -f ($home | path join "host.toml")
        let t = (resolve-link-targets (resolve-effective-plan $home) --sandbox $sb).targets
        let glob_child = ($t | where key == "g/*" | first)
        let explicit = ($t | where key == "explicit" | first)
        assert equal $glob_child.is_dir $explicit.is_dir
    }
}

export def test_forget_prune_children_use_normal_link_table [] {
    # Managed dir link "X" was replaced by the app with a real directory; manifest switches to "X/*"
    let setup = { |home: string|
        let sb = ($home | path join "sb")
        let m = ($home | path join "modules" "d")
        mkdir ($m | path join "X" "sub")
        "mod-f\n" | save -f ($m | path join "X" "f.txt")
        "mod-a\n" | save -f ($m | path join "X" "sub" "a.txt")
        "name = \"d\"\nos = [\"linux\"]\n[links]\n\"X\" = { target = \"~/.config/X\", mode = \"dir\" }\n" | save -f ($m | path join "ygg.toml")
        "[[modules]]\nname = \"d\"\n" | save -f ($home | path join "host.toml")
        apply-links $home (resolve-effective-plan $home) --sandbox $sb | ignore
        let x = ($sb | path join ".config" "X")
        ^rm $x
        mkdir ($x | path join "sub")
        "host-f\n" | save -f ($x | path join "f.txt")
        "host-a\n" | save -f ($x | path join "sub" "a.txt")
        "name = \"d\"\nos = [\"linux\"]\n[links]\n\"X/*\" = \"~/.config/X/*\"\n" | save -f ($m | path join "ygg.toml")
        $x
    }

    # 1. Children over real host entries -> BACKUP_REPLACE (not LINK); shadowed dir blocks without --force
    with-temp-ygg { |home|
        let x = (do $setup $home)
        let sb = ($home | path join "sb")
        "host-only\n" | save -f ($x | path join "sub" "extra.txt")
        let plan = (resolve-effective-plan $home)
        let r = (resolve-link-targets $plan --sandbox $sb)
        let ops = (compute-link-ops $home $r --sandbox $sb)
        assert equal ($ops | where op == "PRUNE" | get detail) ["forget"]
        assert equal ($ops | where op == "BACKUP_REPLACE" | get dest | sort) ([($x | path join "f.txt"), ($x | path join "sub")] | sort)
        assert (($ops | where op == "LINK") | is-empty)
        assert equal ((preflight-check $home $plan $r $ops --sandbox $sb) | get reason) ["shadowed_files"]
        let err = (try { apply-links $home $plan --sandbox $sb; "" } catch { |e| $e.msg })
        assert ($err | str contains "shadowed_files")
        assert equal (($x | path join "sub") | path type) "dir"

        # --force: both replaced via backups, no stray link inside the host directory
        let res = (apply-links $home $plan --force --sandbox $sb)
        assert ($res.failed | is-empty)
        assert equal ($x | path type) "dir"
        assert equal (($x | path join "sub") | path type) "symlink"
        assert equal (($x | path join "f.txt") | path type) "symlink"
        assert (not ((($home | path join "modules" "d" "X" "sub" "sub")) | path exists))
        assert equal (glob ($home | path join ".state" "backups" "**" "sub" "extra.txt") | length) 1
        assert equal (glob ($home | path join ".state" "backups" "**" "X" "f.txt") | each { |f| open --raw $f }) ["host-f\n"]
    }

    # 2. Without host-only files: BACKUP_REPLACE passes preflight and apply succeeds (no "File exists")
    with-temp-ygg { |home|
        let x = (do $setup $home)
        let sb = ($home | path join "sb")
        let res = (apply-links $home (resolve-effective-plan $home) --sandbox $sb)
        assert ($res.failed | is-empty)
        assert equal (($x | path join "f.txt") | path type) "symlink"
        assert equal (($x | path join "sub") | path type) "symlink"
        assert equal (open --raw ($x | path join "sub" "a.txt")) "mod-a\n"
        assert equal ((load-state $home).links | get ($x | path join "sub") | get type) "symlink"
    }
}

export def test_preflight_rejects_bad_service_manager_and_name [] {
    with-temp-ygg { |home|
        ensure-ygg-dirs $home
        let bad_mgr = (preflight-check $home { services: { rm: { enable: ["x"] } } } --quiet)
        assert equal ($bad_mgr | where key == "services" | length) 1
        let bad_name = (preflight-check $home { services: { systemd: { user: { enable: ["a; b"] } } } } --quiet)
        assert equal ($bad_name | where key == "services" | length) 1
        let ok = (preflight-check $home { services: { systemd: { user: { enable: ["a@b.service"], restart_on_change: { "c-d_e:f.service": ["k"] } } } } } --quiet)
        assert equal ($ok | where key == "services") []
    }
}

export def test_preflight_rejects_service_name_starting_with_dash [] {
    with-temp-ygg { |home|
        ensure-ygg-dirs $home
        let p = (preflight-check $home { services: { systemd: { user: { enable: ["--now"] } } } } --quiet)
        assert equal ($p | where key == "services" | length) 1
    }
}

export def test_preflight_launchd_accepts_label_rejects_path [] {
    with-temp-ygg { |home|
        ensure-ygg-dirs $home
        let ok = (preflight-check $home { services: { launchd: { enable: ["com.example.agent"] } } } --quiet)
        assert equal ($ok | where key == "services") []
        let bad = (preflight-check $home { services: { launchd: { enable: ["~/Library/LaunchAgents/x.plist"] } } } --quiet)
        assert equal ($bad | where key == "services" | length) 1
    }
}

export def test_preflight_rejects_invalid_env_and_alias_names [] {
    with-temp-ygg { |home|
        ensure-ygg-dirs $home
        let bad_env = (preflight-check $home { env: { "A; rm -rf ~": "x" } } --quiet)
        assert equal ($bad_env | where key == "env" | length) 1
        let bad_alias = (preflight-check $home { aliases: { "k x": "y" } } --quiet)
        assert equal ($bad_alias | where key == "aliases" | length) 1
        let ok = (preflight-check $home { env: { GOOD_1: "x" }, aliases: { "g.st-1": "y" } } --quiet)
        assert equal ($ok | where { |p| $p.key in ["env", "aliases"] }) []
    }
}

export def test_preflight_rejects_invalid_secrets_key [] {
    with-temp-ygg { |home|
        ensure-ygg-dirs $home
        "[env]\n\"A; rm\" = \"x\"\nGOOD = \"y\"" | save -f ($home | path join "secrets.toml")
        let p = (preflight-check $home {} --quiet)
        assert equal ($p | where key == "env" | length) 1
        assert ((($p | where key == "env").0.detail) | str contains "secrets.toml")
    }
}
