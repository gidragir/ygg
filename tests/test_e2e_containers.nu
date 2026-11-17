use std/assert
use ../src/state.nu [ensure-ygg-dirs]
use ../src/link.nu [is-link-or-junction]
use ../scripts/release.nu [read-ygg-version]
use helpers.nu [with-temp-ygg, test-link-dir, test-dangling-link]

def ctr-mk-src [home: string, name: string, --compose = true, --scope-only]: nothing -> string {
    let d = ($home | path join "src" $name)
    mkdir $d
    let extra = if $scope_only { "[scope.linux.containers]\nfiles = [\"stack/app.yml\"]\n" } else { "" }
    $"name = \"($name)\"\nos = [\"linux\", \"windows\", \"macos\", \"cachyos\"]\n($extra)" | save -f ($d | path join "ygg.toml")
    if $scope_only {
        mkdir ($d | path join "stack")
        "services: {}\n" | save -f ($d | path join "stack" "app.yml")
    } else if $compose {
        "services: {}\n" | save -f ($d | path join "compose.yml")
    }
    $d
}

def ctr-log [log: string]: nothing -> list<string> {
    if ($log | path exists) { open --raw $log | lines | where { |l| $l | str starts-with "container: " } } else { [] }
}

def ctr-flags [home: string]: nothing -> record {
    let os = if $nu.os-info.family == "windows" { "windows" } else { "cachyos" }
    { YGG_HOME: $home, YGG_SANDBOX: ($home | path join "sb"), YGG_HOST_OS_OVERRIDE: $os, YGG_MOCK_PKG_LOG: ($home | path join "mock.log"), YGG_NONINTERACTIVE: "1" }
}

def ctr-flag-of [home: string, name: string]: nothing -> any {
    (open ($home | path join "host.toml")).modules | where name == $name | get -o 0 | get -o containers
}

def ctr-started [home: string, ygg_bin: string, src: string]: nothing -> nothing {
    let r = (^nu $ygg_bin add --containers $src | complete)
    assert equal $r.exit_code 0 $r.stderr
}

export def test_cli_apply_runs_container_step_from_host_toml [] {
    with-temp-ygg { |home|
        let sb = ($home | path join "sb")
        mkdir $sb ($home | path join "modules" "ds")
        let d = ($home | path join "modules" "ds")
        "name = \"ds\"\nos = [\"linux\", \"windows\", \"macos\", \"cachyos\"]\n" | save -f ($d | path join "ygg.toml")
        "services: {}\n" | save -f ($d | path join "compose.yml")
        "[[modules]]\nname = \"ds\"\ncontainers = true\n" | save -f ($home | path join "host.toml")
        let log = ($home | path join "mock.log")
        let ygg_bin = ($env.FILE_PWD | path join "../bin/ygg.nu" | path expand)
        let host_os_ovr = if $nu.os-info.family == "windows" { "windows" } else { "cachyos" }
        let count = { if ($log | path exists) { open --raw $log | lines | where { |l| $l | str starts-with "container: " } | length } else { 0 } }
        with-env { YGG_HOME: $home, YGG_SANDBOX: $sb, YGG_HOST_OS_OVERRIDE: $host_os_ovr, YGG_MOCK_PKG_LOG: $log, YGG_NONINTERACTIVE: "1" } {
            let r1 = (^nu $ygg_bin apply --sandbox $sb | complete)
            assert equal $r1.exit_code 0
            assert equal (do $count) 1
            assert ((open --raw $log) | str contains "-p ds up -d --remove-orphans")
            let r2 = (^nu $ygg_bin apply --sandbox $sb | complete)
            assert equal $r2.exit_code 0
            assert equal (do $count) 1
            "services: {}\n# edit\n" | save -f ($d | path join "compose.yml")
            let r3 = (^nu $ygg_bin apply --dry-run --sandbox $sb | complete)
            assert equal $r3.exit_code 0
            assert ($r3.stdout | str contains "CONTAINER")
            assert ($r3.stdout | str contains " up ds  (ds: compose.yml)")
            assert equal (do $count) 1
        }
    }
}

export def test_cli_add_noninteractive_defaults_containers_off [] {
    with-temp-ygg { |home|
        let ygg_bin = ($env.FILE_PWD | path join "../bin/ygg.nu" | path expand)
        let src = (ctr-mk-src $home "ds")
        with-env (ctr-flags $home) {
            let r = (^nu $ygg_bin add $src | complete)
            assert equal $r.exit_code 0 $r.stderr
            assert equal (ctr-flag-of $home "ds") false
            assert ($r.stderr | str contains "ygg apply --containers ds") $r.stderr
            assert equal (ctr-log ($home | path join "mock.log")) []
        }
    }
}

export def test_cli_add_scope_only_stack_triggers_question_path [] {
    with-temp-ygg { |home|
        let ygg_bin = ($env.FILE_PWD | path join "../bin/ygg.nu" | path expand)
        let src = (ctr-mk-src $home "ds" --scope-only)
        with-env ((ctr-flags $home) | upsert YGG_HOST_OS_OVERRIDE "cachyos") {
            let r = (^nu $ygg_bin add $src | complete)
            assert equal $r.exit_code 0 $r.stderr
            assert equal (ctr-flag-of $home "ds") false
        }
    }
}

export def test_cli_add_scope_inactive_stack_not_detected [] {
    with-temp-ygg { |home|
        let ygg_bin = ($env.FILE_PWD | path join "../bin/ygg.nu" | path expand)
        let src = (ctr-mk-src $home "ds" --scope-only)
        with-env ((ctr-flags $home) | upsert YGG_HOST_OS_OVERRIDE "windows") {
            let r = (^nu $ygg_bin add $src | complete)
            assert equal $r.exit_code 0 $r.stderr
            assert equal (ctr-flag-of $home "ds") null
        }
    }
}

export def test_cli_add_containers_flags_mutually_exclusive [] {
    with-temp-ygg { |home|
        let ygg_bin = ($env.FILE_PWD | path join "../bin/ygg.nu" | path expand)
        let src = (ctr-mk-src $home "ds")
        with-env (ctr-flags $home) {
            let r = (^nu $ygg_bin add --containers --no-containers $src | complete)
            assert ($r.exit_code != 0)
            assert ($r.stderr | str contains "--containers and --no-containers are mutually exclusive") $r.stderr
        }
    }
}

export def test_cli_apply_containers_preflight_failure_keeps_host_toml [] {
    with-temp-ygg { |home|
        let ygg_bin = ($env.FILE_PWD | path join "../bin/ygg.nu" | path expand)
        mkdir ($home | path join "sb")
        for n in ["first" "second"] {
            let d = ($home | path join "modules" $n)
            mkdir $d
            $"name = \"($n)\"\nos = [\"linux\", \"windows\", \"macos\", \"cachyos\"]\n" | save -f ($d | path join "ygg.toml")
            "name: pg\nservices: {}\n" | save -f ($d | path join "compose.yml")
        }
        "[[modules]]\nname = \"first\"\ncontainers = true\n[[modules]]\nname = \"second\"\n" | save -f ($home | path join "host.toml")
        let h0 = (open --raw ($home | path join "host.toml") | hash sha256)
        with-env (ctr-flags $home) {
            let r = (^nu $ygg_bin apply --containers second | complete)
            assert ($r.exit_code != 0)
            assert ($r.stderr | str contains "container_project_collision") $r.stderr
            assert equal (open --raw ($home | path join "host.toml") | hash sha256) $h0
            # dry-run surfaces the same preflight errors and leaves host.toml alone
            let d = (^nu $ygg_bin apply --dry-run --containers second | complete)
            assert ($d.exit_code != 0)
            assert ($d.stderr | str contains "container_project_collision") $d.stderr
            assert equal (open --raw ($home | path join "host.toml") | hash sha256) $h0
            # missing compose file
            "name = \"first\"\nos = [\"linux\", \"windows\", \"macos\", \"cachyos\"]\n[containers]\nfiles = [\"compose.yml\"]\n" | save -f ($home | path join "modules" "first" "ygg.toml")
            rm ($home | path join "modules" "first" "compose.yml")
            let m = (^nu $ygg_bin apply --dry-run --containers first | complete)
            assert ($m.exit_code != 0)
            assert ($m.stderr | str contains "container_file_missing") $m.stderr
            assert equal (open --raw ($home | path join "host.toml") | hash sha256) $h0
        }
    }
}

export def test_cli_add_containers_flag_starts_stack [] {
    with-temp-ygg { |home|
        let ygg_bin = ($env.FILE_PWD | path join "../bin/ygg.nu" | path expand)
        let src = (ctr-mk-src $home "ds")
        let plain = (ctr-mk-src $home "plain" --compose=false)
        let log = ($home | path join "mock.log")
        with-env (ctr-flags $home) {
            let r = (^nu $ygg_bin add --containers $src | complete)
            assert equal $r.exit_code 0 $r.stderr
            assert equal (ctr-flag-of $home "ds") true
            assert ((ctr-log $log) | where { |l| $l | str contains " up " } | is-not-empty)
            let r2 = (^nu $ygg_bin add $plain | complete)
            assert equal $r2.exit_code 0 $r2.stderr
            let mods = (open ($home | path join "host.toml")).modules
            assert equal ($mods | where name == "plain" | get 0 | get -o containers) null
        }
    }
}

export def test_cli_readd_preserves_existing_containers_flag [] {
    with-temp-ygg { |home|
        let ygg_bin = ($env.FILE_PWD | path join "../bin/ygg.nu" | path expand)
        let src = (ctr-mk-src $home "ds")
        let log = ($home | path join "mock.log")
        with-env (ctr-flags $home) {
            let r1 = (^nu $ygg_bin add --containers $src | complete)
            assert equal $r1.exit_code 0 $r1.stderr
            assert equal (ctr-flag-of $home "ds") true
            rm -f $log
            let r2 = (^nu $ygg_bin add $src | complete)
            assert equal $r2.exit_code 0 $r2.stderr
            assert equal (ctr-flag-of $home "ds") true
            assert (not ((ctr-log $log) | any { |l| $l | str contains " down" }))
        }
    }
}

export def test_cli_add_dry_run_does_not_touch_host_toml [] {
    with-temp-ygg { |home|
        let ygg_bin = ($env.FILE_PWD | path join "../bin/ygg.nu" | path expand)
        let src = (ctr-mk-src $home "ds")
        with-env (ctr-flags $home) {
            let r = (^nu $ygg_bin add --dry-run --containers $src | complete)
            assert equal $r.exit_code 0 $r.stderr
            assert (not ($home | path join "host.toml" | path exists))
            assert equal (ctr-log ($home | path join "mock.log")) []
        }
    }
}

export def test_cli_apply_containers_enable_disable_targets [] {
    with-temp-ygg { |home|
        let ygg_bin = ($env.FILE_PWD | path join "../bin/ygg.nu" | path expand)
        let log = ($home | path join "mock.log")
        let ds = (ctr-mk-src $home "ds")
        let ml = (ctr-mk-src $home "ml")
        "services: {}\nx-n: ml\n" | save -f ($ml | path join "compose.yml")
        with-env (ctr-flags $home) {
            for s in [$ds $ml] {
                assert equal (^nu $ygg_bin add --no-containers $s | complete).exit_code 0
            }
            assert equal (ctr-flag-of $home "ds") false
            let r1 = (^nu $ygg_bin apply --containers ds | complete)
            assert equal $r1.exit_code 0 $r1.stderr
            assert equal (ctr-flag-of $home "ds") true
            assert equal (ctr-flag-of $home "ml") false
            let l1 = (ctr-log $log)
            assert ($l1 | where { |l| $l | str contains "-p ds up" } | is-not-empty)
            assert ($l1 | where { |l| $l | str contains "-p ml " } | is-empty)
            let r2 = (^nu $ygg_bin apply --no-containers | complete)
            assert equal $r2.exit_code 0 $r2.stderr
            assert equal (ctr-flag-of $home "ds") false
            assert equal (ctr-flag-of $home "ml") false
            assert ((ctr-log $log) | where { |l| $l | str contains "-p ds down" } | is-not-empty)
            let r3 = (^nu $ygg_bin apply --containers | complete)
            assert equal $r3.exit_code 0 $r3.stderr
            assert equal (ctr-flag-of $home "ds") true
            assert equal (ctr-flag-of $home "ml") true
            let l3 = (ctr-log $log)
            assert ($l3 | where { |l| $l | str contains "-p ml up" } | is-not-empty)
            assert (($l3 | where { |l| $l | str contains "-p ds up" } | length) >= 2)
        }
    }
}

export def test_cli_apply_container_argument_errors [] {
    with-temp-ygg { |home|
        let ygg_bin = ($env.FILE_PWD | path join "../bin/ygg.nu" | path expand)
        let ds = (ctr-mk-src $home "ds")
        let plain = (ctr-mk-src $home "plain" --compose=false)
        with-env (ctr-flags $home) {
            ^nu $ygg_bin add --no-containers $ds | complete | ignore
            ^nu $ygg_bin add $plain | complete | ignore
            let h0 = (open --raw ($home | path join "host.toml") | hash sha256)
            let r1 = (^nu $ygg_bin apply ds | complete)
            assert ($r1.exit_code != 0)
            assert ($r1.stderr | str contains "module names require --containers or --no-containers") $r1.stderr
            let r2 = (^nu $ygg_bin apply --containers --no-containers | complete)
            assert ($r2.exit_code != 0)
            assert ($r2.stderr | str contains "mutually exclusive") $r2.stderr
            let r3 = (^nu $ygg_bin apply --containers nope | complete)
            assert ($r3.exit_code != 0)
            assert ($r3.stderr | str contains "Module 'nope' not found") $r3.stderr
            let r4 = (^nu $ygg_bin apply --containers plain | complete)
            assert ($r4.exit_code != 0)
            assert ($r4.stderr | str contains "declares no containers") $r4.stderr
            assert equal (open --raw ($home | path join "host.toml") | hash sha256) $h0
        }
    }
}

export def test_cli_apply_containers_strict_when_runtime_down [] {
    with-temp-ygg { |home|
        let ygg_bin = ($env.FILE_PWD | path join "../bin/ygg.nu" | path expand)
        let ds = (ctr-mk-src $home "ds")
        with-env ((ctr-flags $home) | upsert YGG_MOCK_CONTAINER_STATUS "no_runtime") {
            assert equal (^nu $ygg_bin add --no-containers $ds | complete).exit_code 0
            let r = (^nu $ygg_bin apply --containers ds | complete)
            assert ($r.exit_code != 0) $r.stderr
            assert ($r.stderr | str contains "no_runtime") $r.stderr
            # plain apply with an already-enabled flag only warns
            let r2 = (^nu $ygg_bin apply | complete)
            assert equal $r2.exit_code 0 $r2.stderr
            assert ($r2.stderr | str contains "unavailable (no_runtime)") $r2.stderr
            let mods = (open ($home | path join "host.toml")).modules
            assert equal ($mods | where name == "ds" | get 0.containers) true
        }
    }
}

export def test_cli_upgrade_order_pull_down_up [] {
    with-temp-ygg { |home|
        let ygg_bin = ($env.FILE_PWD | path join "../bin/ygg.nu" | path expand)
        let src = (ctr-mk-src $home "ds")
        let log = ($home | path join "mock.log")
        with-env (ctr-flags $home) {
            ctr-started $home $ygg_bin $src
            rm -f $log
            let r = (^nu $ygg_bin upgrade --containers | complete)
            assert equal $r.exit_code 0 $r.stderr
            let l = (ctr-log $log)
            assert equal ($l | length) 3 ($l | str join "\n")
            assert ($l.0 | str ends-with "-p ds pull --ignore-buildable") $l.0
            assert equal $l.1 "container: docker compose -p ds down"
            assert ($l.2 | str ends-with "-p ds up -d --remove-orphans") $l.2
            assert (not ($l | any { |x| $x | str contains " -v" }))
            assert (not ($l | any { |x| ($x | str contains "--volumes") or ($x | str contains "--rmi") }))
            assert equal (open ($home | path join ".state" "state.json")).containers.0.project "ds"
        }
    }
}

export def test_cli_upgrade_with_build_service [] {
    with-temp-ygg { |home|
        let ygg_bin = ($env.FILE_PWD | path join "../bin/ygg.nu" | path expand)
        let src = (ctr-mk-src $home "ds")
        "services:\n  app:\n    build: .\n" | save -f ($src | path join "compose.yml")
        let log = ($home | path join "mock.log")
        with-env (ctr-flags $home) {
            ctr-started $home $ygg_bin $src
            rm -f $log
            let r = (^nu $ygg_bin upgrade --containers ds | complete)
            assert equal $r.exit_code 0 $r.stderr
            let l = (ctr-log $log)
            assert equal ($l | length) 4 ($l | str join "\n")
            assert ($l.0 | str contains " pull ")
            assert ($l.1 | str ends-with "-p ds build --pull") $l.1
            assert ($l.2 | str ends-with "-p ds down") $l.2
            assert ($l.3 | str contains " up -d ")
        }
    }
}

export def test_cli_upgrade_pull_failure_keeps_containers [] {
    with-temp-ygg { |home|
        let ygg_bin = ($env.FILE_PWD | path join "../bin/ygg.nu" | path expand)
        let src = (ctr-mk-src $home "ds")
        let log = ($home | path join "mock.log")
        with-env (ctr-flags $home) {
            ctr-started $home $ygg_bin $src
            rm -f $log
            let r = (with-env { YGG_MOCK_CONTAINER_FAIL: "pull" } { ^nu $ygg_bin upgrade --containers | complete })
            assert ($r.exit_code != 0) $r.stdout
            let l = (ctr-log $log)
            assert equal ($l | length) 1 ($l | str join "\n")
            assert ($l.0 | str contains " pull ")
            assert (not ($l | any { |x| $x | str contains " down" }))
            assert equal (open ($home | path join ".state" "state.json")).containers.0.project "ds"
        }
    }
}

export def test_cli_upgrade_errors [] {
    with-temp-ygg { |home|
        let ygg_bin = ($env.FILE_PWD | path join "../bin/ygg.nu" | path expand)
        let src = (ctr-mk-src $home "ds")
        let log = ($home | path join "mock.log")
        with-env (ctr-flags $home) {
            assert equal (^nu $ygg_bin add --no-containers $src | complete).exit_code 0
            let r1 = (^nu $ygg_bin upgrade | complete)
            assert ($r1.exit_code != 0)
            assert ($r1.stderr | str contains "upgrade requires a target: --containers") $r1.stderr
            let r2 = (^nu $ygg_bin upgrade --containers ds | complete)
            assert ($r2.exit_code != 0)
            assert ($r2.stderr | str contains "Containers of 'ds' are disabled. Run: ygg apply --containers ds") $r2.stderr
            assert equal (ctr-log $log | length) 0
            ctr-started $home $ygg_bin $src
            rm -f $log
            let d = (^nu $ygg_bin upgrade --containers --dry-run | complete)
            assert equal $d.exit_code 0 $d.stderr
            assert ($d.stdout | str contains "  CONTAINER       ")
            assert ($d.stdout | str contains "  CONTAINER       docker compose -p ds down")
            assert ($d.stdout | str contains "-p ds pull --ignore-buildable")
            assert (not ($log | path exists)) "dry-run must not write the mock log (no probe either)"
        }
    }
}

export def test_cli_upgrade_partial_failure_continues [] {
    with-temp-ygg { |home|
        let ygg_bin = ($env.FILE_PWD | path join "../bin/ygg.nu" | path expand)
        let a = (ctr-mk-src $home "a")
        let b = (ctr-mk-src $home "b")
        let log = ($home | path join "mock.log")
        with-env (ctr-flags $home) {
            ctr-started $home $ygg_bin $a
            ctr-started $home $ygg_bin $b
            let b_compose = ($home | path join "modules" "b" "compose.yml")
            "services:\n  app:\n    image: alpine:latest\n" | save -f $b_compose
            let old_hash_b = ((open ($home | path join ".state" "state.json")).hashes | get "containers:b:b")
            rm -f $log
            let r = (with-env { YGG_MOCK_CONTAINER_FAIL: "-p a pull" } { ^nu $ygg_bin upgrade --containers | complete })
            assert ($r.exit_code != 0) $r.stdout
            let l = (ctr-log $log)
            assert ($l | any { |x| $x | str contains "-p a pull" }) ($l | str join "\n")
            assert (not ($l | any { |x| ($x | str contains "-p a down") or ($x | str contains "-p a up") })) ($l | str join "\n")
            assert ($l | any { |x| $x | str contains "-p b up -d --remove-orphans" }) ($l | str join "\n")
            let st = (open ($home | path join ".state" "state.json"))
            assert equal ($st.containers | get project | sort) ["a" "b"]
            let new_hash_b = ($st.hashes | get "containers:b:b")
            assert ($new_hash_b != $old_hash_b) "expected b hash to be updated after upgrade"
        }
    }
}

export def test_cli_upgrade_runtime_switch_uses_state_runtime_for_down [] {
    with-temp-ygg { |home|
        let ygg_bin = ($env.FILE_PWD | path join "../bin/ygg.nu" | path expand)
        let src = (ctr-mk-src $home "ds")
        let log = ($home | path join "mock.log")
        with-env (ctr-flags $home) {
            ctr-started $home $ygg_bin $src
            assert equal (open ($home | path join ".state" "state.json")).containers.0.runtime "docker"
            let host_toml = ($home | path join "host.toml")
            ("[ygg.containers]\nruntime = \"podman\"\n\n" + (open --raw $host_toml)) | save -f $host_toml
            rm -f $log
            let r = (^nu $ygg_bin upgrade --containers | complete)
            assert equal $r.exit_code 0 $r.stderr
            let l = (ctr-log $log)
            assert equal ($l | length) 3 ($l | str join "\n")
            assert ($l.0 | str starts-with "container: podman compose ") $l.0
            assert ($l.0 | str ends-with "-p ds pull --ignore-buildable") $l.0
            assert equal $l.1 "container: docker compose -p ds down"
            assert ($l.2 | str starts-with "container: podman compose ") $l.2
            assert ($l.2 | str ends-with "-p ds up -d --remove-orphans") $l.2
            assert equal (open ($home | path join ".state" "state.json")).containers.0.runtime "podman"
        }
    }
}

export def test_cli_remove_downs_stacks_without_volumes [] {
    with-temp-ygg { |home|
        let ygg_bin = ($env.FILE_PWD | path join "../bin/ygg.nu" | path expand)
        let src = (ctr-mk-src $home "ds")
        let log = ($home | path join "mock.log")
        with-env (ctr-flags $home) {
            ctr-started $home $ygg_bin $src
            rm -f $log
            let r = (^nu $ygg_bin remove ds | complete)
            assert equal $r.exit_code 0 $r.stderr
            let l = (ctr-log $log)
            assert equal ($l | length) 1 ($l | str join "\n")
            assert equal $l.0 "container: docker compose -p ds down"
            assert (not (open --raw $log | str contains " -v"))
            assert (not (open --raw $log | str contains "--volumes"))
            assert equal (open ($home | path join ".state" "state.json")).containers []
        }
    }
}

export def test_cli_remove_warns_when_down_fails [] {
    with-temp-ygg { |home|
        let ygg_bin = ($env.FILE_PWD | path join "../bin/ygg.nu" | path expand)
        let src = (ctr-mk-src $home "ds")
        let log = ($home | path join "mock.log")
        with-env (ctr-flags $home) {
            ctr-started $home $ygg_bin $src
            let r = (with-env { YGG_MOCK_CONTAINER_FAIL: "down" } { ^nu $ygg_bin remove ds | complete })
            assert equal $r.exit_code 0 $r.stderr
            assert ($r.stderr | str contains "docker compose -p ds down") $r.stderr
            assert equal (open ($home | path join ".state" "state.json")).containers []
        }
    }
}

export def test_cli_status_shows_containers_column [] {
    with-temp-ygg { |home|
        let ygg_bin = ($env.FILE_PWD | path join "../bin/ygg.nu" | path expand)
        let src = (ctr-mk-src $home "ds")
        with-env (ctr-flags $home | merge { YGG_MOCK_CONTAINER_RUNNING: "ds" }) {
            ctr-started $home $ygg_bin $src
            let broken = ($home | path join "modules" "broken")
            mkdir $broken
            "not = [valid toml\n" | save -f ($broken | path join "ygg.toml")
            ($"\n[[modules]]\nname = \"broken\"\n") | save --append ($home | path join "host.toml")

            let res = (^nu $ygg_bin status --json | complete)
            assert equal $res.exit_code 0 $res.stderr
            let rows = ($res.stdout | from json)
            let ds_row = ($rows | where name == "ds" | first)
            let broken_row = ($rows | where name == "broken" | first)
            assert equal $ds_row.containers "on 1/1 running"
            assert equal $broken_row.containers "?"
        }
    }
}

