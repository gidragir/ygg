# tests/test_doctor.nu
# Tests for `ygg doctor` (src/doctor.nu, RFC-017): one scenario per check, read-only guarantee,
# CLI exit codes and JSON output, core purity.

use std/assert
use ../src/state.nu *
use ../src/manifest.nu *
use ../src/link.nu *
use ../src/doctor.nu *
use helpers.nu [with-temp-ygg, test-link-dir, test-dangling-link]

# Module source directory outside YGG_HOME, linked into modules/<name>
def make-module [home: string, name: string, toml: string]: nothing -> string {
    let src = ($home | path dirname | path join ("src-" + $name))
    mkdir $src
    $toml | save -f ($src | path join "ygg.toml")
    mkdir ($home | path join "modules")
    test-link-dir $src ($home | path join "modules" $name)
    $src
}

def write-host [home: string, mods: list<string>] {
    $mods | each { |m| "[[modules]]\nname = \"" + $m + "\"\n" } | str join "\n" | save -f ($home | path join "host.toml")
}

def apply-all [home: string] {
    ensure-ygg-dirs $home
    let plan = (resolve-effective-plan $home)
    apply-links $home $plan --sandbox $env.YGG_SANDBOX | ignore
}

def rows-of [report: table, check: string]: nothing -> table {
    $report | where { |r| $r.check == $check }
}

# Recursive snapshot (type, mode, content hash, link target) of a whole directory tree
def snapshot-tree [root: string]: nothing -> list<string> {
    if not ($root | path exists) {
        return []
    }
    mut out = []
    for it in (ls -la $root | sort-by name) {
        let rel = ($it.name | path relative-to $root)
        if ($it.type == "symlink") {
            $out = ($out | append $"L ($rel) -> ($it.target)")
        } else if ($it.type == "dir") {
            $out = ($out | append $"D ($rel) ($it.mode? | default '')")
            $out = ($out | append (snapshot-tree $it.name | each { |l| $l | str replace --regex '^(\w) ' ('$1 ' + $rel + '/') }))
        } else {
            $out = ($out | append $"F ($rel) ($it.mode? | default '') (open --raw $it.name | hash sha256)")
        }
    }
    $out
}

const LINKS_TOML = 'name = "m"
os = ["linux", "windows", "macos"]
[links]
"a.conf" = "~/.config/a.conf"
"b.conf" = "~/.config/b.conf"
"c.conf" = "~/.config/c.conf"
'

def setup-links-module [home: string]: nothing -> string {
    let src = (make-module $home "m" $LINKS_TOML)
    for f in ["a.conf", "b.conf", "c.conf", "d.conf"] {
        $"($f)\n" | save -f ($src | path join $f)
    }
    write-host $home ["m"]
    apply-all $home
    $src
}

export def test_doctor_link_and_link_pending [] {
    with-temp-ygg { |home|
        let sb = $env.YGG_SANDBOX
        let host_os_ovr = if $nu.os-info.family == "windows" { "windows" } else { "cachyos" }
        with-env { YGG_HOST_OS_OVERRIDE: $host_os_ovr } {
            let src = (setup-links-module $home)
            let cfg = ($sb | path join ".config")
            assert equal (rows-of (run-doctor $home --sandbox $sb) "link" | length) 0

            if $nu.os-info.family != "windows" {
                # Broken managed link (points to a missing path) and a real file in place of a link
                rm ($cfg | path join "a.conf")
                test-dangling-link ($home | path join "nowhere") ($cfg | path join "a.conf")
                rm ($cfg | path join "b.conf")
                "host\n" | save -f ($cfg | path join "b.conf")
                # A link added to the manifest but not applied yet
                ($LINKS_TOML + "\"d.conf\" = \"~/.config/d.conf\"\n") | save -f ($src | path join "ygg.toml")

                let rep = (run-doctor $home --sandbox $sb)
                let link_rows = (rows-of $rep "link")
                assert equal ($link_rows | length) 2
                assert ($link_rows | all { |r| $r.severity == "error" })
                assert equal ($link_rows | get target | sort) [($cfg | path join "a.conf"), ($cfg | path join "b.conf")]
                assert ($link_rows | all { |r| ($r.fix | str contains "ygg apply") })

                let pending = (rows-of $rep "link_pending")
                assert equal ($pending | length) 1
                assert equal ($pending | first | get severity) "warn"
                assert equal ($pending | first | get target) ($cfg | path join "d.conf")
                # The healthy link is not reported anywhere
                assert (not ($rep | any { |r| $r.target == ($cfg | path join "c.conf") }))
                # The dangling managed link is a `link` error, not an orphan
                assert equal (rows-of $rep "orphan_link" | length) 0
            }
        }
    }
}

export def test_doctor_orphan_link_and_state_orphan [] {
    with-temp-ygg { |home|
        let sb = $env.YGG_SANDBOX
        with-env { YGG_HOST_OS_OVERRIDE: "cachyos" } {
            setup-links-module $home | ignore
            let cfg = ($sb | path join ".config")
            mkdir ($sb | path join ".local" "bin")
            test-dangling-link ($home | path join "gone-1") ($cfg | path join "stale.conf")
            test-dangling-link ($home | path join "gone-2") ($sb | path join ".local" "bin" "old-tool")
            test-dangling-link ($home | path join "gone-3") ($sb | path join ".stale-rc")
            # A valid unmanaged symlink is not an orphan
            ^ln -s ($cfg | path join "a.conf") ($cfg | path join "alias.conf")
            # Depth 1 only: a dangling link two levels below ~/.config is not scanned
            mkdir ($cfg | path join "deep" "er")
            test-dangling-link ($home | path join "gone-4") ($cfg | path join "deep" "er" "x")

            # State records of a module that is not in host.toml
            mut st = (load-state $home)
            let ghost_dest = ($cfg | path join "ghost.conf")
            $st.links = ($st.links | upsert $ghost_dest { module: "ghost", src: "/x", type: "symlink", cmd_shim: "" })
            let ghost_copy = ($cfg | path join "ghost.json")
            $st.copies = ($st.copies | upsert $ghost_copy { module: "ghost", src: "/y", dest: $ghost_copy, last_synced_hash: "" })
            save-state $home $st

            let rep = (run-doctor $home --sandbox $sb)
            let orphans = (rows-of $rep "orphan_link")
            assert equal ($orphans | get target | each { |p| normalize-case $p } | sort) ([
                ($cfg | path join "stale.conf"),
                ($sb | path join ".local" "bin" "old-tool"),
                ($sb | path join ".stale-rc")
            ] | each { |p| normalize-case $p } | sort)
            assert ($orphans | all { |r| $r.severity == "warn" })

            let st_orphans = (rows-of $rep "state_orphan")
            assert equal ($st_orphans | get target | sort) ([$ghost_dest, $ghost_copy] | sort)
            assert ($st_orphans | all { |r| ($r.severity == "warn") and ($r.detail | str contains "ghost") })
        }
    }
}

export def test_doctor_sync_conflict_and_pending_save [] {
    with-temp-ygg { |home|
        let sb = $env.YGG_SANDBOX
        with-env { YGG_HOST_OS_OVERRIDE: "cachyos" } {
            let src = (make-module $home "m" 'name = "m"
os = ["linux", "windows", "macos"]
[save]
"s1.json" = "~/.config/s1.json"
"s2.json" = "~/.config/s2.json"
"s3.json" = "~/.config/s3.json"
')
            for f in ["s1.json", "s2.json", "s3.json"] {
                "{}\n" | save -f ($src | path join $f)
            }
            write-host $home ["m"]
            apply-all $home
            let cfg = ($sb | path join ".config")
            assert equal (rows-of (run-doctor $home --sandbox $sb) "sync" | length) 0

            '{"host": 1}' | save -f ($cfg | path join "s1.json")
            '{"host": 2}' | save -f ($cfg | path join "s2.json")
            '{"mod": 2}' | save -f ($src | path join "s2.json")

            let sync = (rows-of (run-doctor $home --sandbox $sb) "sync")
            assert equal ($sync | length) 2
            assert ($sync | all { |r| $r.severity == "warn" })
            let s1 = ($sync | where target == ($cfg | path join "s1.json") | first)
            assert ($s1.detail | str contains "pending_save")
            assert ($s1.fix | str contains "ygg save")
            let s2 = ($sync | where target == ($cfg | path join "s2.json") | first)
            assert ($s2.detail | str contains "conflict")
        }
    }
}

export def test_doctor_perm_on_private_files [] {
    if $nu.os-info.family == "windows" { return }
    with-temp-ygg { |home|
        let sb = $env.YGG_SANDBOX
        with-env { YGG_HOST_OS_OVERRIDE: "cachyos" } {
            make-module $home "m" 'name = "m"
os = ["linux", "windows", "macos"]
[doctor]
private_files = ["~/.config/keys/key.txt"]
' | ignore
            write-host $home ["m"]
            ensure-ygg-dirs $home
            let secrets = ($home | path join "secrets.toml")
            let env_file = ($home | path join ".state" "env" "env.nu")
            let conf = ($sb | path join ".config" "environment.d" "99-ygg.conf")
            let key = ($sb | path join ".config" "keys" "key.txt")
            mkdir ($conf | path dirname) ($key | path dirname)
            for f in [$secrets, $env_file, $conf, $key] {
                "x = 1\n" | save -f $f
                ^chmod 0644 $f
            }

            let perm = (rows-of (run-doctor $home --sandbox $sb) "perm")
            assert equal ($perm | get target | sort) ([$secrets, $env_file, $conf, $key] | sort)
            assert ($perm | all { |r| ($r.severity == "error") and ($r.fix | str contains "chmod 600") })

            for f in [$secrets, $env_file, $conf, $key] {
                ^chmod 0600 $f
            }
            assert equal (rows-of (run-doctor $home --sandbox $sb) "perm" | length) 0
            # Group-readable private file is an error as well
            ^chmod 0640 $key
            assert equal (rows-of (run-doctor $home --sandbox $sb) "perm" | get target) [$key]
        }
    }
}

export def test_doctor_tool_missing_package_manager [] {
    with-temp-ygg { |home|
        let sb = $env.YGG_SANDBOX
        make-module $home "m" 'name = "m"
os = ["linux", "windows", "macos"]
[packages]
cargo = ["ripgrep"]
' | ignore
        write-host $home ["m"]
        let log = ($home | path join "pkg.log")
        with-env { YGG_HOST_OS_OVERRIDE: "cachyos", YGG_MOCK_PKG_LOG: $log, YGG_MOCK_PKG_MISSING: "cargo" } {
            let tool = (rows-of (run-doctor $home --sandbox $sb) "tool")
            assert equal ($tool | length) 1
            assert equal ($tool | first | get severity) "error"
            assert equal ($tool | first | get target) "cargo"
        }
        with-env { YGG_HOST_OS_OVERRIDE: "cachyos", YGG_MOCK_PKG_LOG: $log, YGG_MOCK_PKG_MISSING: "" } {
            # nu >= 0.116 and git are present on the test host; the manager is available
            assert equal (rows-of (run-doctor $home --sandbox $sb) "tool" | length) 0
        }
        assert (not ($log | path exists))
    }
}

export def test_doctor_collision_and_shadow [] {
    with-temp-ygg { |home|
        let sb = $env.YGG_SANDBOX
        with-env { YGG_HOST_OS_OVERRIDE: "cachyos" } {
            let a = (make-module $home "a" 'name = "a"
os = ["linux", "windows", "macos"]
[links]
"same.conf" = "~/.config/same.conf"
')
            let b = (make-module $home "b" 'name = "b"
os = ["linux", "windows", "macos"]
[links]
"same.conf" = "~/.config/same.conf"
[links.app]
target = "~/.config/app"
mode = "dir"
')
            "a\n" | save -f ($a | path join "same.conf")
            "b\n" | save -f ($b | path join "same.conf")
            mkdir ($b | path join "app")
            "common\n" | save -f ($b | path join "app" "common.txt")
            # Host directory with runtime state that the module does not ship
            let app = ($sb | path join ".config" "app")
            mkdir ($app | path join "sub")
            "host\n" | save -f ($app | path join "common.txt")
            "state\n" | save -f ($app | path join "sub" "runtime.db")
            write-host $home ["a", "b"]
            apply-all $home
            assert (is-link-or-junction $app)

            let rep = (run-doctor $home --sandbox $sb)
            let col = (rows-of $rep "collision")
            assert equal ($col | length) 1
            assert equal ($col | first | get severity) "warn"
            assert equal ($col | first | get target) ($sb | path join ".config" "same.conf")
            assert ($col | first | get detail | str contains "'a'")

            let shadow = (rows-of $rep "shadow")
            assert equal ($shadow | length) 1
            let row = ($shadow | first)
            assert equal $row.severity "warn"
            assert equal $row.target $app
            assert ($row.detail | str contains "sub/runtime.db")
            assert (not ($row.detail | str contains "common.txt"))
            let bkp_root = ($home | path join ".state" "backups")
            assert ($row.fix | str contains $bkp_root)
        }
    }
}

export def test_doctor_secrets_template [] {
    with-temp-ygg { |home|
        let sb = $env.YGG_SANDBOX
        with-env { YGG_HOST_OS_OVERRIDE: "cachyos" } {
            let src = (make-module $home "m" 'name = "m"
os = ["linux", "windows", "macos"]
')
            "[env]\nAPI_KEY = \"\"\nOTHER_TOKEN = \"\"\n" | save -f ($src | path join "secrets.example.toml")
            write-host $home ["m"]
            let secrets = ($home | path join "secrets.toml")
            "[env]\nAPI_KEY = \"value\"\n" | save -f $secrets
            ^chmod 0600 $secrets

            let sec = (rows-of (run-doctor $home --sandbox $sb) "secrets")
            assert equal ($sec | length) 1
            assert equal ($sec | first | get severity) "warn"
            assert ($sec | first | get detail | str contains "OTHER_TOKEN")
            assert (not ($sec | first | get detail | str contains "value"))

            "[env]\nAPI_KEY = \"value\"\nOTHER_TOKEN = \"t\"\n" | save -f $secrets
            assert equal (rows-of (run-doctor $home --sandbox $sb) "secrets" | length) 0
        }
    }
}

export def test_doctor_canonical_warns_and_cli_exits_0 [] {
    with-temp-ygg { |home|
        let sb = $env.YGG_SANDBOX
        let ygg_bin = ($env.FILE_PWD | path join "../bin/ygg.nu" | path expand)
        let host_os_ovr = if $nu.os-info.family == "windows" { "windows" } else { "cachyos" }
        with-env { YGG_HOST_OS_OVERRIDE: $host_os_ovr } {
            setup-links-module $home | ignore
            assert equal (rows-of (run-doctor $home --sandbox $sb) "canonical" | length) 0
        }
        with-env { YGG_HOST_OS_OVERRIDE: $host_os_ovr, YGG_MOCK_NO_CANONICALIZE: "1" } {
            let rep = (run-doctor $home --sandbox $sb)
            let can = (rows-of $rep "canonical")
            assert ($can | all { |r| $r.severity == "warn" })
            assert ($can | any { |r| $r.target == ($home | path join "modules" "m") })
            if $nu.os-info.family != "windows" {
                assert ($can | any { |r| $r.target == ($sb | path join ".config" "a.conf") })
            }
            assert (not ($rep | any { |r| $r.severity == "error" }))

            let res = (^nu $ygg_bin doctor --sandbox $sb | complete)
            assert equal $res.exit_code 0 $res.stderr
            assert ($res.stdout | str contains "canonical")
            assert ($res.stdout | str contains "0 error(s)")
            let js = (^nu $ygg_bin doctor --json --sandbox $sb | complete)
            assert equal $js.exit_code 0 $js.stderr
            let parsed = ($js.stdout | from json)
            assert (($parsed | length) > 0)
            assert equal ($parsed | first | columns | sort) ["check", "detail", "fix", "severity", "target"]
            assert ($parsed | any { |r| $r.check == "canonical" })
        }
    }
}

export def test_doctor_is_read_only_and_cli_exits_1_on_error [] {
    with-temp-ygg { |home|
        let sb = $env.YGG_SANDBOX
        let root = ($home | path dirname)
        let ygg_bin = ($env.FILE_PWD | path join "../bin/ygg.nu" | path expand)
        with-env { YGG_HOST_OS_OVERRIDE: "cachyos" } {
            setup-links-module $home | ignore
            let cfg = ($sb | path join ".config")
            rm ($cfg | path join "a.conf")
            test-dangling-link ($home | path join "nowhere") ($cfg | path join "a.conf")
            test-dangling-link ($home | path join "gone") ($cfg | path join "stale.conf")
            "[env]\nK = \"v\"\n" | save -f ($home | path join "secrets.toml")
            if $nu.os-info.family != "windows" {
                ^chmod 0644 ($home | path join "secrets.toml")
            }

            let before = (snapshot-tree $root)
            let state_before = (open --raw ($home | path join ".state" "state.json"))
            let rep = (run-doctor $home --sandbox $sb)
            assert ($rep | any { |r| $r.severity == "error" })
            let res = (^nu $ygg_bin doctor --sandbox $sb | complete)
            assert equal $res.exit_code 1
            assert ($res.stdout | str contains "error(s)")
            let js = (^nu $ygg_bin doctor --json --sandbox $sb | complete)
            assert equal $js.exit_code 1
            let parsed = ($js.stdout | from json)
            assert ($parsed | any { |r| ($r.check == "link") and ($r.severity == "error") })
            if $nu.os-info.family != "windows" {
                assert ($parsed | any { |r| ($r.check == "perm") and ($r.severity == "error") })
            }
            assert equal (snapshot-tree $root) $before
            assert equal (open --raw ($home | path join ".state" "state.json")) $state_before
        }
    }
}

export def test_doctor_does_not_create_ygg_dirs [] {
    with-temp-ygg { |home|
        let sb = $env.YGG_SANDBOX
        let ygg_bin = ($env.FILE_PWD | path join "../bin/ygg.nu" | path expand)
        let fresh = ($home | path join "fresh-home")
        mkdir $fresh
        let before = (snapshot-tree ($home | path dirname))
        with-env { YGG_HOME: $fresh } {
            assert equal (run-doctor $fresh --sandbox $sb | where severity == "error" | length) 0
            let res = (^nu $ygg_bin doctor --json --sandbox $sb | complete)
            assert equal $res.exit_code 0 $res.stderr
            assert equal ($res.stdout | from json | length) 0
        }
        assert equal (snapshot-tree ($home | path dirname)) $before
        assert (not ($fresh | path join ".state" | path exists))
        assert (not ($fresh | path join "modules" | path exists))
    }
}

export def test_doctor_core_has_no_user_specific_names [] {
    let doctor_src = ($env.FILE_PWD | path join "../src/doctor.nu" | path expand)
    let text = (open --raw $doctor_src | str lowercase)
    for word in ["chezmoi", "sops", "omni-dotfiles", "ai-dotfiles", "win-dotfiles", "hermes"] {
        assert (not ($text | str contains $word)) $"src/doctor.nu must not mention '($word)'"
    }
}

export def test_journal_transaction_lifecycle_and_doctor_detection [] {
    with-temp-ygg { |home|
        let sb = $env.YGG_SANDBOX
        ensure-ygg-dirs $home
        write-host $home []
        assert equal (rows-of (run-doctor $home --sandbox $sb) "journal_interrupted" | length) 0
        assert equal (rows-of (run-doctor $home --sandbox $sb) "journal_failed" | length) 0

        # Active transaction produces no doctor findings
        begin-journal-transaction $home { modules: ["m1"] }
        record-journal-step $home "links" "IN_PROGRESS"
        let active_st = (check-pending-journal $home)
        assert equal $active_st.state "active"
        assert equal (rows-of (run-doctor $home --sandbox $sb) "journal_interrupted" | length) 0
        assert equal (rows-of (run-doctor $home --sandbox $sb) "journal_failed" | length) 0

        # Interrupted transaction (dead pid) produces error finding
        let jfile = ($home | path join ".state" "journal.json")
        open $jfile | upsert pid 2147483646 | to json | save -f $jfile
        let int_st = (check-pending-journal $home)
        assert equal $int_st.state "interrupted"
        let rep_int = (run-doctor $home --sandbox $sb)
        let rows_int = (rows-of $rep_int "journal_interrupted")
        assert equal ($rows_int | length) 1
        assert equal ($rows_int | first | get severity) "error"

        # Failed transaction produces warn finding
        fail-journal-transaction $home "mock link failure"
        let fail_st = (check-pending-journal $home)
        assert equal $fail_st.state "failed"
        let rep_fail = (run-doctor $home --sandbox $sb)
        let rows_fail = (rows-of $rep_fail "journal_failed")
        assert equal ($rows_fail | length) 1
        assert equal ($rows_fail | first | get severity) "warn"
        assert ($rows_fail | first | get detail | str contains "mock link failure")

        # Commit removes journal and findings
        commit-journal-transaction $home
        assert (not ($home | path join ".state" "journal.json" | path exists)) "Journal must be deleted on commit"
        assert equal (rows-of (run-doctor $home --sandbox $sb) "journal_interrupted" | length) 0
        assert equal (rows-of (run-doctor $home --sandbox $sb) "journal_failed" | length) 0
    }
}

export def test_windows_acl_sid_parser [] {
    assert (is-windows-acl-insecure "S-1-5-32-545|ReadAndExecute, Synchronize|Allow")
    assert (is-windows-acl-insecure "S-1-5-21-1-2-3-1001|FullControl|Allow\r\nS-1-1-0|Read|Allow")
    assert (is-windows-acl-insecure "S-1-5-11|Modify|Allow")
    assert (not (is-windows-acl-insecure "S-1-5-21-1-2-3-1001|FullControl|Allow\nS-1-5-18|FullControl|Allow"))
    assert (not (is-windows-acl-insecure "S-1-1-0|FullControl|Deny"))
    assert (not (is-windows-acl-insecure ""))
}

export def test_doctor_windows_acl_audit_generates_perm_error [] {
    with-temp-ygg { |home|
        ensure-ygg-dirs $home
        "" | save -f ($home | path join "secrets.toml")
        with-env { YGG_MOCK_WINDOWS_INSECURE_ACL: "1", YGG_HOST_OS_OVERRIDE: "windows" } {
            let res = (check-perms $home { modules: [] } "")
            assert ($res | any { |f| ($f.check == "perm") and ($f.severity == "error") and ($f.detail | str contains "insecure Windows ACL") }) "Expected Windows ACL perm finding"
        }
    }
}

export def test_doctor_windows_acl_parser_detects_everyone [] {
    with-temp-ygg { |home|
        ensure-ygg-dirs $home
        "" | save -f ($home | path join "secrets.toml")
        with-env {
            YGG_HOST_OS_OVERRIDE: "windows",
            YGG_MOCK_WINDOWS_ICACLS_OUTPUT: "S-1-1-0|Read|Allow\nS-1-5-32-544|FullControl|Allow"
        } {
            let res = (check-perms $home { modules: [] } "")
            assert ($res | any { |f| ($f.check == "perm") and ($f.severity == "error") and ($f.detail | str contains "insecure Windows ACL") }) "Expected Windows ACL error from Everyone SID"
        }
    }
}

export def test_doctor_windows_acl_parser_passes_secure_acl [] {
    with-temp-ygg { |home|
        ensure-ygg-dirs $home
        "" | save -f ($home | path join "secrets.toml")
        with-env {
            YGG_HOST_OS_OVERRIDE: "windows",
            YGG_MOCK_WINDOWS_ICACLS_OUTPUT: "S-1-5-18|FullControl|Allow\nS-1-5-21-1-2-3-1001|FullControl|Allow"
        } {
            let res = (check-perms $home { modules: [] } "")
            assert ($res | is-empty) "Expected secure Windows ACL to produce no findings"
        }
    }
}

export def test_doctor_windows_acl_checks_env_ps1_and_private_files [] {
    with-temp-ygg { |home|
        let sb = $env.YGG_SANDBOX
        ensure-ygg-dirs $home
        let env_ps1 = ($home | path join ".state" "env" "env.ps1")
        mkdir ($env_ps1 | path dirname)
        "$env:YGG = '1'\n" | save -f $env_ps1
        let priv = ($sb | path join ".config" "my_token.txt")
        mkdir ($priv | path dirname)
        "secret" | save -f $priv
        let plan = {
            modules: [
                {
                    manifest: {
                        doctor: {
                            private_files: ["~/.config/my_token.txt"]
                        }
                    }
                }
            ]
        }
        with-env { YGG_MOCK_WINDOWS_INSECURE_ACL: "1", YGG_HOST_OS_OVERRIDE: "windows" } {
            let res = (check-perms $home $plan $sb)
            let targets = ($res | get target)
            assert ($targets | any { |t| $t == $env_ps1 }) "Expected env.ps1 in targets"
            assert ($targets | any { |t| $t == $priv }) "Expected private file in targets"
            assert ($res | all { |f| ($f.check == "perm") and ($f.severity == "error") and ($f.fix | str contains "icacls") and ($f.fix | str contains "${env:USERNAME}:F") and (not ($f.fix | str contains "%USERNAME%")) }) "All must have PowerShell icacls fix"
        }
    }
}

export def test_doctor_fix_resolves_perms_and_orphan_links [] {
    with-temp-ygg { |home|
        let sb = $env.YGG_SANDBOX
        ensure-ygg-dirs $home
        with-env { YGG_HOST_OS_OVERRIDE: "cachyos" } {
            let sec = ($home | path join "secrets.toml")
            "secret = true" | save -f $sec
            ^chmod 644 $sec | complete | ignore

            let cfg = ($sb | path join ".config")
            mkdir $cfg
            let dead_link = ($cfg | path join "dead.conf")
            test-dangling-link ($home | path join "nonexistent") $dead_link

            mut st = (load-state $home)
            let ghost_dest = ($cfg | path join "ghost.conf")
            $st.links = ($st.links | upsert $ghost_dest { module: "ghost", src: "/x", type: "symlink", cmd_shim: "" })
            let ghost_copy = ($cfg | path join "ghost.json")
            $st.copies = ($st.copies | upsert $ghost_copy { module: "ghost", src: "/y", dest: $ghost_copy, last_synced_hash: "" })
            save-state $home $st

            let findings = [
                { check: "perm", severity: "error", target: $sec, detail: "mode rw-r--r--, expected rw-------", fix: $"chmod 600 '($sec)'" }
                { check: "orphan_link", severity: "warn", target: $dead_link, detail: "dangling symlink", fix: "remove the link", owned: true }
                { check: "state_orphan", severity: "warn", target: $ghost_dest, detail: "state.links ghost", fix: "ygg apply" }
                { check: "state_orphan", severity: "warn", target: $ghost_copy, detail: "state.copies ghost", fix: "ygg apply" }
                { check: "sync", severity: "warn", target: "/dummy/sync", detail: "conflict", fix: "ygg apply --force" }
            ]

            let fixed = (doctor-fix $home $findings)
            assert equal ($fixed | length) 4 "Expected 4 fixed findings (perm, orphan_link, 2 state_orphans; sync skipped)"

            # Verify perm fixed to 0600 (Unix only; Windows uses NTFS ACLs tested separately)
            if $nu.os-info.family != "windows" {
                let mode = (ls -lD $sec | get -o 0.mode | default "")
                assert ($mode =~ 'rw-------') "Expected 0600 mode after fix"
            }

            # Verify orphan_link removed
            assert (not ($dead_link | path exists)) "Expected dead symlink to be removed"
            assert (try { ($dead_link | path type) != "symlink" } catch { true }) "Expected dead symlink does not exist as symlink"

            # Verify state_orphan cleaned from state
            let new_st = (load-state $home)
            assert ($ghost_dest not-in ($new_st.links | columns)) "ghost link should be removed from state.links"
            assert ($ghost_copy not-in ($new_st.copies | columns)) "ghost copy should be removed from state.copies"
        }
    }
}

export def test_doctor_secrets_materialized_warning [] {
    with-temp-ygg { |home|
        ensure-ygg-dirs $home
        let sb = ($home | path join "sb"); mkdir $sb
        let m = ($home | path join "modules" "m"); mkdir $m
        "name = \"m\"\nos = [\"linux\", \"windows\", \"macos\"]\n" | save -f ($m | path join "ygg.toml")
        "[[modules]]\nname = \"m\"\n\n[ygg.secrets]\nmaterialize = true\n" | save -f ($home | path join "host.toml")
        "K = \"op://v/i/f\"\n" | save -f ($home | path join "secrets.toml")
        let findings = (run-doctor $home --sandbox $sb)
        let mat = ($findings | where check == "secrets_materialized")
        assert equal ($mat | length) 1
        assert equal ($mat.0.severity) "warn"

        # When materialize is false or default, no secrets_materialized finding
        "[[modules]]\nname = \"m\"\n\n[ygg.secrets]\nmaterialize = false\n" | save -f ($home | path join "host.toml")
        let findings2 = (run-doctor $home --sandbox $sb)
        assert equal ($findings2 | where check == "secrets_materialized" | length) 0
    }
}






export def test_doctor_windows_acl_unreadable_warns [] {
    with-temp-ygg { |home|
        ensure-ygg-dirs $home
        "" | save -f ($home | path join "secrets.toml")
        with-env { YGG_HOST_OS_OVERRIDE: "windows", YGG_MOCK_WINDOWS_ACL_FAIL: "1" } {
            let res = (check-perms $home { modules: [] } "")
            assert ($res | any { |f| ($f.check == "acl_unreadable") and ($f.severity == "warn") }) "Expected acl_unreadable warn"
        }
    }
}

export def test_windows_acl_sid_parser_case_and_bom [] {
    assert (is-windows-acl-insecure "\u{feff}s-1-1-0|Read|allow")
}

export def test_doctor_fix_leaves_foreign_dangling_links [] {
    if $nu.os-info.family == "windows" { return }
    with-temp-ygg { |home|
        ensure-ygg-dirs $home
        let sb = ($home | path join "sb"); mkdir ($sb | path join ".config")
        let m = ($home | path join "modules" "m"); mkdir $m
        "name = \"m\"\nos = [\"linux\", \"windows\", \"macos\"]\n" | save -f ($m | path join "ygg.toml")
        "[[modules]]\nname = \"m\"\n" | save -f ($home | path join "host.toml")
        let foreign = ($sb | path join ".config" "foreign")
        let owned = ($sb | path join ".config" "owned")
        ^ln -s ($home | path dirname | path join "unmounted" "x") $foreign
        ^ln -s ($m | path join "gone.conf") $owned
        with-env { YGG_HOST_OS_OVERRIDE: "cachyos" } {
            let findings = (run-doctor $home --sandbox $sb)
            let f = ($findings | where check == "orphan_link")
            assert equal ($f | where target == $foreign | get 0.owned) false
            assert equal ($f | where target == $foreign | get 0.severity) "info"
            assert equal ($f | where target == $owned | get 0.owned) true
            doctor-fix $home $findings --sandbox $sb | ignore
        }
        assert (($foreign | path type) == "symlink")
        assert (not ($owned | path exists -n))
    }
}

export def test_doctor_fix_state_orphan_removes_link_too [] {
    if $nu.os-info.family == "windows" { return }
    with-temp-ygg { |home|
        ensure-ygg-dirs $home
        let sb = ($home | path join "sb"); mkdir $sb
        let dest = ($sb | path join "old-link")
        ^ln -s ($home | path join "host.toml") $dest
        "modules = []\n" | save -f ($home | path join "host.toml")
        save-state $home { links: { ($dest): { module: "removed-mod", src: "x" } }, copies: {}, hashes: {}, packages: {} }
        let findings = [{ check: "state_orphan", severity: "warn", target: $dest, detail: "", fix: "" }]
        let res = (doctor-fix $home $findings --sandbox $sb)
        assert equal ($res | get 0.action) "link and record removed"
        assert (not ($dest | path exists -n))
        assert equal ((load-state $home).links | columns) []
    }
}

export def test_doctor_fix_state_orphan_keeps_regular_file [] {
    if $nu.os-info.family == "windows" { return }
    with-temp-ygg { |home|
        ensure-ygg-dirs $home
        let sb = ($home | path join "sb"); mkdir $sb
        let dest = ($sb | path join "user-file")
        "precious" | save -f $dest
        "modules = []\n" | save -f ($home | path join "host.toml")
        save-state $home { links: { ($dest): { module: "removed-mod", src: "x" } }, copies: {}, hashes: {}, packages: {} }
        let findings = [{ check: "state_orphan", severity: "warn", target: $dest, detail: "", fix: "" }]
        let res = (doctor-fix $home $findings --sandbox $sb)
        assert (($dest | path type) == "file")
        assert equal (open --raw $dest) "precious"
        assert equal ((load-state $home).links | columns) []
        assert equal ($res | get 0.action) "record removed, file left in place"
    }
}

export def test_nu_version_ok [] {
    assert (nu-version-ok "1.0.0")
    assert (nu-version-ok "0.116.1")
    assert (nu-version-ok "0.117.0")
    assert (not (nu-version-ok "0.115.0"))
    assert (not (nu-version-ok "0.99.9"))
}
