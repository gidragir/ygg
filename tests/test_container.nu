# tests/test_container.nu
use std/assert
use ../src *
use helpers.nu [with-temp-ygg]

def mk-module [home: string, name: string]: nothing -> string {
    let d = ($home | path join "modules" $name)
    mkdir $d
    $"name = \"($name)\"\nos = [\"linux\", \"windows\", \"macos\", \"cachyos\"]\n" | save -f ($d | path join "ygg.toml")
    $d
}

export def test_container_discover_default_order [] {
    with-temp-ygg { |home|
        let d = (mk-module $home "ds")
        "services: {}\n" | save -f ($d | path join "docker-compose.yml")
        "services: {}\n" | save -f ($d | path join "compose.yml")
        let stacks = (discover-stacks "ds" $d {} [])
        assert equal ($stacks | get rel) ["compose.yml"]
        assert equal $stacks.0.project "ds"
        assert equal $stacks.0.module "ds"
        assert equal $stacks.0.enabled false
        assert equal $stacks.0.override ""
        assert equal $stacks.0.file ($d | path join "compose.yml")
    }
}

export def test_container_discover_explicit_files_and_empty_list [] {
    with-temp-ygg { |home|
        let d = (mk-module $home "ds")
        mkdir ($d | path join "infra" "pg")
        "services: {}\n" | save -f ($d | path join "infra" "pg" "compose.yml")
        "services: {}\n" | save -f ($d | path join "compose.yml")
        let stacks = (discover-stacks "ds" $d { files: ["infra/pg/compose.yml"] } [])
        assert equal ($stacks | get rel) ["infra/pg/compose.yml"]
        assert equal $stacks.0.project "ds-pg"
        let none = (discover-stacks "ds" $d { files: [] } [])
        assert equal $none []
    }
}

export def test_container_discover_scope_files_appended [] {
    with-temp-ygg { |home|
        let d = (mk-module $home "ds")
        for sub in ["a" "b"] {
            mkdir ($d | path join $sub)
            "services: {}\n" | save -f ($d | path join $sub "compose.yml")
        }
        let stacks = (discover-stacks "ds" $d { files: ["a/compose.yml"] } ["b/compose.yml"])
        assert equal ($stacks | get rel) ["a/compose.yml" "b/compose.yml"]
        # duplicates by rel are dropped
        let dup = (discover-stacks "ds" $d { files: ["a/compose.yml"] } ["a/compose.yml"])
        assert equal ($dup | get rel) ["a/compose.yml"]
        # scope-only files with no base config keep auto-discovery
        "services: {}\n" | save -f ($d | path join "compose.yml")
        let auto = (discover-stacks "ds" $d {} ["b/compose.yml"])
        assert equal ($auto | get rel) ["compose.yml" "b/compose.yml"]
    }
}

export def test_container_project_name_rules [] {
    with-temp-ygg { |home|
        let d = (mk-module $home "ds")
        mkdir ($d | path join "pg") ($d | path join "bad") ($d | path join "tag")
        "name: my-pg\nservices: {}\n" | save -f ($d | path join "pg" "compose.yml")
        assert equal (compose-project-name "ds" $d ($d | path join "pg" "compose.yml")) "my-pg"

        "services: {}\n" | save -f ($d | path join "compose.yml")
        assert equal (compose-project-name "ds" $d ($d | path join "compose.yml")) "ds"

        "name: [unclosed\n  : : {\n" | save -f ($d | path join "bad" "compose.yml")
        assert equal (compose-project-name "ds" $d ($d | path join "bad" "compose.yml")) "ds-bad"

        "name: tagged\nservices:\n  a:\n    ports: !reset []\n" | save -f ($d | path join "tag" "compose.yml")
        assert equal (compose-project-name "ds" $d ($d | path join "tag" "compose.yml")) "tagged"

        assert equal (normalize-project-name "My.Data") "my-data"
        assert equal (normalize-project-name "--a..b__") "a-b"
        let d2 = (mk-module $home "My.Data")
        "services: {}\n" | save -f ($d2 | path join "compose.yml")
        assert equal (compose-project-name "My.Data" $d2 ($d2 | path join "compose.yml")) "my-data"
    }
}

export def test_container_override_detected [] {
    with-temp-ygg { |home|
        let d = (mk-module $home "ds")
        "services: {}\n" | save -f ($d | path join "compose.yml")
        "services: {}\n" | save -f ($d | path join "compose.override.yml")
        let s1 = (discover-stacks "ds" $d {} [])
        assert equal $s1.0.override ($d | path join "compose.override.yml")
        rm ($d | path join "compose.yml") ($d | path join "compose.override.yml")
        "services: {}\n" | save -f ($d | path join "docker-compose.yml")
        "services: {}\n" | save -f ($d | path join "docker-compose.override.yml")
        let s2 = (discover-stacks "ds" $d {} [])
        assert equal $s2.0.override ($d | path join "docker-compose.override.yml")
        assert equal (find-override-file ($d | path join "docker-compose.yml")) ($d | path join "docker-compose.override.yml")
        rm ($d | path join "docker-compose.override.yml")
        assert equal (find-override-file ($d | path join "docker-compose.yml")) ""
    }
}

export def test_container_plan_enabled_flag_and_settings [] {
    with-temp-ygg { |home|
        let d = (mk-module $home "ds")
        "services: {}\n" | save -f ($d | path join "compose.yml")
        let d2 = (mk-module $home "plain")
        '[[modules]]
name = "ds"
containers = true
[[modules]]
name = "plain"
[ygg.containers]
runtime = "podman"
' | save -f ($home | path join "host.toml")
        with-env { YGG_HOST_OS_OVERRIDE: "cachyos" } {
            let plan = (resolve-effective-plan $home)
            assert equal ($plan.containers | length) 1
            assert equal $plan.containers.0.enabled true
            assert equal $plan.containers.0.module "ds"
            assert equal $plan.container_settings { runtime: "podman", timeout: 600 }
            let by = ($plan.modules | where name == "ds" | first)
            assert equal $by.containers_raw true
            assert equal ($plan.modules | where name == "plain" | first | get containers_raw) null
        }
    }
}

export def test_container_plan_scope_files_and_default_settings [] {
    with-temp-ygg { |home|
        let d = (mk-module $home "ds")
        mkdir ($d | path join "x")
        "services: {}\n" | save -f ($d | path join "x" "compose.yml")
        $"name = \"ds\"\nos = [\"linux\", \"cachyos\"]\n[containers]\nfiles = []\n[scope.pc.containers]\nfiles = [\"x/compose.yml\"]\n" | save -f ($d | path join "ygg.toml")
        '[[modules]]
name = "ds"
scopes = ["pc"]
containers = false
' | save -f ($home | path join "host.toml")
        with-env { YGG_HOST_OS_OVERRIDE: "cachyos" } {
            let plan = (resolve-effective-plan $home)
            assert equal ($plan.containers | get rel) ["x/compose.yml"]
            assert equal $plan.containers.0.enabled false
            assert equal $plan.container_settings { runtime: "", timeout: 600 }
        }
    }
}

export def test_container_load_state_without_containers_key [] {
    with-temp-ygg { |home|
        mkdir ($home | path join ".state")
        '{"links":{}}' | save -f ($home | path join ".state" "state.json")
        assert equal (load-state $home).containers []
    }
}

def pf-reasons [problems: list<record>]: nothing -> list<string> {
    $problems | get reason | sort
}

export def test_container_preflight_missing_file_and_outside_path [] {
    with-temp-ygg { |home|
        let d = (mk-module $home "ds")
        "services: {}\n" | save -f ($d | path join "compose.yml")
        $"name = \"ds\"\nos = [\"linux\", \"cachyos\"]\n[containers]\nfiles = [\"nope.yml\", \"../x/compose.yml\", \"($home | path join 'abs.yml')\"]\n" | save -f ($d | path join "ygg.toml")
        "[[modules]]\nname = \"ds\"\ncontainers = true\n" | save -f ($home | path join "host.toml")
        with-env { YGG_HOST_OS_OVERRIDE: "cachyos" } {
            let probs = (check-container-stacks (resolve-effective-plan $home))
            assert equal (pf-reasons $probs) ["container_file_missing" "container_path_outside_module" "container_path_outside_module"]
            assert equal ($probs | get module | uniq) ["ds"]
            let pre = (preflight-check $home (resolve-effective-plan $home) --quiet)
            assert equal ($pre | where reason =~ "^container_" | length) 3
        }
        "[[modules]]\nname = \"ds\"\ncontainers = false\n" | save -f ($home | path join "host.toml")
        with-env { YGG_HOST_OS_OVERRIDE: "cachyos" } {
            assert equal (check-container-stacks (resolve-effective-plan $home)) []
        }
    }
}

export def test_container_preflight_project_collision [] {
    with-temp-ygg { |home|
        let a = (mk-module $home "a")
        let b = (mk-module $home "b")
        "name: pg\nservices: {}\n" | save -f ($a | path join "compose.yml")
        "name: pg\nservices: {}\n" | save -f ($b | path join "compose.yml")
        "[[modules]]\nname = \"a\"\ncontainers = true\n[[modules]]\nname = \"b\"\ncontainers = true\n" | save -f ($home | path join "host.toml")
        with-env { YGG_HOST_OS_OVERRIDE: "cachyos" } {
            let probs = (check-container-stacks (resolve-effective-plan $home))
            assert equal (pf-reasons $probs) ["container_project_collision"]
            assert ($probs.0.detail | str contains "pg")
        }
    }
}

export def test_container_preflight_runtime_and_flag_validation [] {
    with-temp-ygg { |home|
        let d = (mk-module $home "ds")
        "services: {}\n" | save -f ($d | path join "compose.yml")
        "[[modules]]\nname = \"ds\"\ncontainers = true\n[ygg.containers]\nruntime = \"nerdctl\"\n" | save -f ($home | path join "host.toml")
        with-env { YGG_HOST_OS_OVERRIDE: "cachyos" } {
            assert equal (pf-reasons (check-container-stacks (resolve-effective-plan $home))) ["invalid_container_runtime"]
        }
        "[[modules]]\nname = \"ds\"\ncontainers = \"yes\"\n" | save -f ($home | path join "host.toml")
        with-env { YGG_HOST_OS_OVERRIDE: "cachyos" } {
            let probs = (check-container-stacks (resolve-effective-plan $home))
            assert equal (pf-reasons $probs) ["invalid_containers_flag"]
            assert equal $probs.0.module "ds"
        }
    }
}

def mk-stack [d: string, ovr: string = ""]: nothing -> record {
    { module: "ds", rel: "compose.yml", file: ($d | path join "compose.yml"), override: $ovr, project: "ds", enabled: true }
}

export def test_container_compose_version_parsing [] {
    assert (compose-version-ok "Docker Compose version v2.29.7")
    assert (compose-version-ok ">>>> Executing external compose provider \"/usr/bin/docker-compose\".\nDocker Compose version 2.31.0")
    assert (not (compose-version-ok "podman-compose version 1.2.0\npodman version 5.3.1"))
    assert (not (compose-version-ok "docker-compose version 1.29.2, build 5becea4c"))
}

export def test_container_argv_shapes_and_no_volume_flags [] {
    let st = { module: "ds", rel: "x", file: "/m/my mod/compose.yml", override: "/m/my mod/compose.override.yml", project: "ds", enabled: true }
    assert equal (build-compose-argv "docker" "up" $st) ["docker" "compose" "-f" "/m/my mod/compose.yml" "-f" "/m/my mod/compose.override.yml" "-p" "ds" "up" "-d" "--remove-orphans"]
    assert equal (build-compose-argv "podman" "down" $st) ["podman" "compose" "-p" "ds" "down"]
    assert equal (build-compose-argv "docker" "pull" $st) ["docker" "compose" "-f" "/m/my mod/compose.yml" "-f" "/m/my mod/compose.override.yml" "-p" "ds" "pull" "--ignore-buildable"]
    assert equal (build-compose-argv "docker" "build" $st) ["docker" "compose" "-f" "/m/my mod/compose.yml" "-f" "/m/my mod/compose.override.yml" "-p" "ds" "build" "--pull"]
    for a in ["up" "down" "pull" "build"] {
        let argv = (build-compose-argv "docker" $a $st)
        for bad in ["-v" "--volumes" "--rmi"] { assert (not ($bad in $argv)) }
    }
}

export def test_container_run_compose_mock_sandbox_dry_run [] {
    with-temp-ygg { |home|
        let log = ($home | path join "mock.log")
        let argv = ["docker" "compose" "-p" "ds" "down"]
        with-env { YGG_MOCK_PKG_LOG: $log } {
            assert equal (run-compose $argv 5).status "ok"
        }
        assert ((open --raw $log) | str contains "container: docker compose -p ds down\n")
        let log2 = ($home | path join "mock2.log")
        with-env { YGG_MOCK_PKG_LOG: $log2, YGG_MOCK_CONTAINER_FAIL: "down" } {
            assert equal (run-compose $argv 5).status "failed"
        }
        assert equal (run-compose $argv 5).status "skipped_sandbox"
        assert equal (run-compose $argv 5 --dry-run).status "dry_run"
        with-env { YGG_MOCK_PKG_LOG: ($home | path join "never.log") } {
            assert equal (run-compose $argv 5 --dry-run).status "dry_run"
        }
        assert (not (($home | path join "never.log") | path exists))
    }
}

export def test_container_detect_runtime_mock [] {
    with-temp-ygg { |home|
        let log = ($home | path join "mock.log")
        with-env { YGG_MOCK_PKG_LOG: $log } {
            let r = (detect-container-runtime { runtime: "" })
            assert equal $r.runtime "docker"
            assert equal $r.status "ok"
            assert equal (detect-container-runtime { runtime: "podman" }).runtime "podman"
            assert equal (detect-container-runtime { runtime: "docker" } --runtime podman).runtime "podman"
        }
        assert ((open --raw $log) | str contains "container-probe: docker compose version")
        with-env { YGG_MOCK_PKG_LOG: $log, YGG_MOCK_CONTAINER_STATUS: "daemon_down" } {
            assert equal (detect-container-runtime { runtime: "" }).status "daemon_down"
        }
        # sandbox without mock log: nothing is created anywhere under home
        let log2 = ($home | path join "none.log")
        let before = (glob ($home | path join "**" "*") | sort)
        with-env { YGG_MOCK_PKG_LOG: "" } {
            assert equal (detect-container-runtime { runtime: "" }).status "skipped_sandbox"
        }
        assert equal (glob ($home | path join "**" "*") | sort) $before
        assert (not ($log2 | path exists))
        # control: the same call with a mock log (and sandbox) does write to that path
        with-env { YGG_MOCK_PKG_LOG: $log2 } {
            assert equal (detect-container-runtime { runtime: "" }).status "ok"
        }
        assert ($log2 | path exists)
        # dry-run of run-compose: a real mock log is set but never created
        let log3 = ($home | path join "dry.log")
        with-env { YGG_MOCK_PKG_LOG: $log3 } {
            assert equal (run-compose ["docker" "compose" "-p" "ds" "down"] 5 --dry-run).status "dry_run"
        }
        assert (not ($log3 | path exists))
    }
}

export def test_container_has_build_yaml_and_tag_fallback [] {
    with-temp-ygg { |home|
        let a = ($home | path join "a.yml")
        "services:\n  app:\n    build: .\n" | save -f $a
        assert (stack-has-build $a)
        let b = ($home | path join "b.yml")
        "services:\n  app:\n    image: nginx\n" | save -f $b
        assert (not (stack-has-build $b))
        let c = ($home | path join "c.yml")
        "services:\n  app:\n    image: x\n    build: !override\n      context: .\n" | save -f $c
        assert (stack-has-build $c)
    }
}

export def test_container_inputs_hash_tracks_override_and_env [] {
    with-temp-ygg { |home|
        let d = ($home | path join "stk")
        mkdir $d
        "services: {}\n" | save -f ($d | path join "compose.yml")
        "services: {}\n" | save -f ($d | path join "compose.override.yml")
        "A=1\n" | save -f ($d | path join ".env")
        "FROM x\n" | save -f ($d | path join "Dockerfile")
        let st = (mk-stack $d ($d | path join "compose.override.yml"))
        let h0 = (stack-inputs-hash $st)
        "FROM y\n" | save -f ($d | path join "Dockerfile")
        assert equal (stack-inputs-hash $st) $h0
        for f in ["compose.yml" "compose.override.yml" ".env"] {
            let before = (stack-inputs-hash $st)
            "# changed\n" | save --append ($d | path join $f)
            assert ((stack-inputs-hash $st) != $before)
        }
    }
}

# --- Task 4: containers step -------------------------------------------------

def step-setup [home: string, mods: list<string> = ["ds"]]: nothing -> nothing {
    mut host = ""
    for m in $mods {
        let d = (mk-module $home $m)
        "services: {}\n" | save -f ($d | path join "compose.yml")
        $host = $host + $"[[modules]]\nname = \"($m)\"\ncontainers = true\n"
    }
    $host | save -f ($home | path join "host.toml")
}

def step-plan [home: string]: nothing -> record {
    with-env { YGG_HOST_OS_OVERRIDE: "cachyos" } { resolve-effective-plan $home }
}

def log-lines [log: string]: nothing -> list<string> {
    if ($log | path exists) { open --raw $log | lines | where { |l| $l != "" } } else { [] }
}

export def test_container_step_up_once_then_noop_then_hash_change [] {
    with-temp-ygg { |home|
        step-setup $home
        let log = ($home | path join "mock.log")
        let f = ($home | path join "modules" "ds" "compose.yml")
        with-env { YGG_MOCK_PKG_LOG: $log } {
            let plan = (step-plan $home)
            let r1 = (run-container-step $home $plan)
            assert equal $r1.status "ok"
            assert equal (log-lines $log | where { |l| $l | str starts-with "container:" }) [$"container: docker compose -f ($f) -p ds up -d --remove-orphans"]
            let st = (load-state $home)
            assert equal $st.containers.0.project "ds"
            assert equal $st.containers.0.runtime "docker"
            assert (($st.hashes | get -o "containers:ds:ds") != null)
            let n = (log-lines $log | length)
            let r2 = (run-container-step $home $plan)
            assert equal $r2.status "noop"
            assert equal (log-lines $log | length) $n
            assert equal (log-lines $log | where { |l| $l | str starts-with "container-probe:" } | length) 1
            "services: {}\n# changed\n" | save -f $f
            let r3 = (run-container-step $home (step-plan $home))
            assert equal $r3.status "ok"
            assert equal (log-lines $log | where { |l| $l | str starts-with "container: " } | length) 2
        }
    }
}

export def test_container_step_down_for_removed_and_disabled [] {
    with-temp-ygg { |home|
        step-setup $home
        let log = ($home | path join "mock.log")
        with-env { YGG_MOCK_PKG_LOG: $log } {
            run-container-step $home (step-plan $home) | ignore
            # disabled
            "[[modules]]\nname = \"ds\"\ncontainers = false\n" | save -f ($home | path join "host.toml")
            let r = (run-container-step $home (step-plan $home))
            assert equal $r.results.0.action "down"
            assert equal $r.results.0.reason "disabled"
            assert equal $r.results.0.status "ok"
            assert ((log-lines $log | last) == "container: docker compose -p ds down")
            let st = (load-state $home)
            assert equal $st.containers []
            assert equal ($st.hashes | get -o "containers:ds:ds") null
        }
    }
    with-temp-ygg { |home|
        step-setup $home
        let log = ($home | path join "mock.log")
        with-env { YGG_MOCK_PKG_LOG: $log } {
            run-container-step $home (step-plan $home) | ignore
            "" | save -f ($home | path join "host.toml")
            let r = (run-container-step $home (step-plan $home))
            assert equal $r.results.0.reason "module removed"
            assert equal (load-state $home).containers []
        }
    }
    with-temp-ygg { |home|
        step-setup $home
        let d = ($home | path join "modules" "ds")
        let log = ($home | path join "mock.log")
        with-env { YGG_MOCK_PKG_LOG: $log } {
            run-container-step $home (step-plan $home) | ignore
            rm ($d | path join "compose.yml")
            "name = \"ds\"\nos = [\"linux\", \"windows\", \"macos\", \"cachyos\"]\n[containers]\nfiles = []\n" | save -f ($d | path join "ygg.toml")
            let r = (run-container-step $home (step-plan $home))
            assert equal $r.results.0.reason "removed from manifest"
            assert equal (log-lines $log | last) "container: docker compose -p ds down"
            assert equal (load-state $home).containers []
        }
    }
    # down uses the runtime the stack was started with, not the current setting
    with-temp-ygg { |home|
        step-setup $home
        let log = ($home | path join "mock.log")
        with-env { YGG_MOCK_PKG_LOG: $log } {
            run-container-step $home (step-plan $home) | ignore
            "[ygg.containers]\nruntime = \"podman\"\n[[modules]]\nname = \"ds\"\ncontainers = false\n" | save -f ($home | path join "host.toml")
            let r = (run-container-step $home (step-plan $home))
            assert equal $r.results.0.status "ok"
            assert equal (log-lines $log | last) "container: docker compose -p ds down"
        }
    }
}

export def test_container_step_sandbox_without_mock_touches_nothing [] {
    with-temp-ygg { |home|
        step-setup $home
        let before = (glob ($home | path join "**" "*") | sort)
        with-env { YGG_MOCK_PKG_LOG: "" } {
            let r = (run-container-step $home (step-plan $home))
            assert equal $r.status "skipped_sandbox"
        }
        assert equal (load-state $home).containers []
        assert equal ((load-state $home).hashes | get -o "containers:ds:ds") null
        assert equal (glob ($home | path join "**" "*") | sort) $before
    }
}

export def test_container_step_partial_failure [] {
    with-temp-ygg { |home|
        step-setup $home ["a" "b"]
        let log = ($home | path join "mock.log")
        with-env { YGG_MOCK_PKG_LOG: $log, YGG_MOCK_CONTAINER_FAIL: "-p a " } {
            let r = (run-container-step $home (step-plan $home))
            assert equal $r.status "failed"
            assert equal ($r.results | where status == "failed" | get project) ["a"]
            let st = (load-state $home)
            assert equal ($st.containers | get project) ["b"]
            assert equal ($st.hashes | get -o "containers:a:a") null
            assert (($st.hashes | get -o "containers:b:b") != null)
        }
    }
}

export def test_container_step_runtime_unavailable_soft_and_strict [] {
    with-temp-ygg { |home|
        step-setup $home
        let log = ($home | path join "mock.log")
        with-env { YGG_MOCK_PKG_LOG: $log, YGG_MOCK_CONTAINER_STATUS: "daemon_down" } {
            let plan = (step-plan $home)
            let r = (run-container-step $home $plan)
            assert equal $r.status "skipped_daemon_down"
            assert equal $r.results.0.status "skipped_daemon_down"
            assert equal (load-state $home).containers []
            assert equal ((load-state $home).hashes | get -o "containers:ds:ds") null
            assert equal (log-lines $log | where { |l| $l | str starts-with "container: " }) []
            let msg = (try { run-container-step $home $plan --strict; "" } catch { |e| $e.msg })
            assert ($msg | str contains "Container runtime 'docker' unavailable (daemon_down)") $"unexpected strict error: ($msg)"
        }
        with-env { YGG_MOCK_PKG_LOG: $log, YGG_MOCK_CONTAINER_STATUS: "no_runtime" } {
            assert equal (run-container-step $home (step-plan $home)).status "skipped_no_runtime"
        }
    }
}

export def test_container_step_force_up_and_dry_run [] {
    with-temp-ygg { |home|
        step-setup $home
        let log = ($home | path join "mock.log")
        with-env { YGG_MOCK_PKG_LOG: $log } {
            let plan = (step-plan $home)
            run-container-step $home $plan | ignore
            let ups = { log-lines $log | where { |l| $l | str starts-with "container: " } | length }
            assert equal (do $ups) 1
            let r = (run-container-step $home $plan --force-up ["ds"])
            assert equal $r.status "ok"
            assert equal (do $ups) 2
            # dry-run: results only, log and state.json untouched
            let sj = ($home | path join ".state" "state.json")
            let h0 = (open --raw $sj | hash sha256)
            let n = (log-lines $log | length)
            let d = (run-container-step $home $plan --dry-run --force-up ["ds"])
            assert equal ($d.results | get status) ["dry_run"]
            assert equal $d.results.0.action "up"
            assert equal $d.results.0.reason "compose.yml"
            assert equal (log-lines $log | length) $n
            assert equal (open --raw $sj | hash sha256) $h0
            # dry-run without candidates never probes the runtime
            assert equal (run-container-step $home $plan --dry-run).status "noop"
            assert equal (log-lines $log | length) $n
        }
    }
}

export def test_container_hash_keys_survive_gc [] {
    with-temp-ygg { |home|
        step-setup $home
        let plan = (step-plan $home)
        assert ("containers:ds:ds" in (collect-active-hash-keys $plan))
        mkdir ($home | path join ".state")
        save-state $home ((load-state $home) | upsert hashes { "containers:ds:ds": "h1", "containers:gone:gone": "h2", "other:x": "h3" })
        gc-state-hashes $home (collect-active-hash-keys $plan) ["ds"] | ignore
        let h = (load-state $home).hashes
        assert equal ($h | columns | sort) ["containers:ds:ds" "other:x"]
    }
}

export def test_container_overrides_set_enabled [] {
    with-temp-ygg { |home|
        step-setup $home ["a" "b"]
        let plan = (step-plan $home)
        let p = (apply-container-overrides $plan ["a"] ["b"])
        assert equal ($p.containers | where module == "a" | get enabled) [true]
        assert equal ($p.containers | where module == "b" | get enabled) [false]
        assert equal (apply-container-overrides $plan [] []) $plan
    }
}

export def test_container_parse_yes_answer [] {
    assert (parse-yes-answer "y"); assert (parse-yes-answer " YES ")
    assert (not (parse-yes-answer "")); assert (not (parse-yes-answer "n")); assert (not (parse-yes-answer "yep"))
}

export def test_container_resolve_targets_and_set_flag [] {
    with-temp-ygg { |home|
        step-setup $home ["ds" "ml"]
        mk-module $home "plain" | ignore
        "[[modules]]\nname = \"plain\"\n[[modules]]\nname = \"ds\"\ncontainers = true\n[[modules]]\nname = \"ml\"\n" | save -f ($home | path join "host.toml")
        let plan = (step-plan $home)
        assert equal (resolve-container-targets $plan [] "enable" | sort) ["ds" "ml"]
        assert equal (resolve-container-targets $plan [] "disable") ["ds"]
        assert equal (resolve-container-targets $plan ["ml"] "enable") ["ml"]
        let m1 = (try { resolve-container-targets $plan ["nope"] "enable"; "" } catch { |e| $e.msg })
        assert equal $m1 "Module 'nope' not found"
        let m2 = (try { resolve-container-targets $plan ["plain"] "enable"; "" } catch { |e| $e.msg })
        assert equal $m2 "Module 'plain' declares no containers"
        set-modules-containers $home ["ml"] true
        set-modules-containers $home ["ds"] false
        let mods = (open ($home | path join "host.toml")).modules
        assert equal ($mods | where name == "ml" | get 0.containers) true
        assert equal ($mods | where name == "ds" | get 0.containers) false
        assert equal ($mods | where name == "plain" | get 0 | get -o containers) null
    }
}

export def test_container_down_module_stacks_sandbox_and_unavailable [] {
    with-temp-ygg { |home|
        let log = ($home | path join "mock.log")
        let entry = { module: "ds", project: "ds", file: "", override: "", runtime: "podman" }
        let seed = { save-state $home ((load-state $home) | upsert containers [$entry]) }
        # sandbox without mock log: no external calls, no probe, entry dropped
        do $seed
        with-env { YGG_MOCK_PKG_LOG: "" } {
            let r = (down-module-stacks $home "ds" { runtime: "", timeout: 600 } --sandbox ($home | path join "sb"))
            assert equal ($r | get status) ["skipped_sandbox"]
        }
        assert equal (load-state $home).containers []
        assert (not ($log | path exists))
        # runtime unavailable: probe happens, no compose call, entry dropped
        do $seed
        with-env { YGG_MOCK_PKG_LOG: $log, YGG_MOCK_CONTAINER_STATUS: "no_runtime" } {
            let r = (down-module-stacks $home "ds" { runtime: "", timeout: 600 })
            assert equal ($r | get status) ["skipped_no_runtime"]
        }
        let txt = (open --raw $log)
        assert ($txt | str contains "container-probe: podman compose version")
        assert (not ($txt | str contains "container: "))
        assert equal (load-state $home).containers []
        # ok path uses entry.runtime and never -v
        do $seed
        with-env { YGG_MOCK_PKG_LOG: $log } {
            down-module-stacks $home "ds" { runtime: "docker", timeout: 600 } | ignore
        }
        assert ((open --raw $log) | str contains "container: podman compose -p ds down\n")
    }
}

export def test_container_status_label_values [] {
    let ok_rt = { runtime: "docker", status: "ok", detail: "" }
    assert equal (container-status-label [] [] $ok_rt []) "-"

    let s1 = { module: "ds", rel: "a/compose.yml", file: "", override: "", project: "ds-a", enabled: false }
    let s2 = { module: "ds", rel: "b/compose.yml", file: "", override: "", project: "ds-b", enabled: false }
    assert equal (container-status-label [$s1 $s2] [] $ok_rt []) "off"

    let e1 = ($s1 | upsert enabled true)
    let e2 = ($s2 | upsert enabled true)
    assert equal (container-status-label [$e1 $e2] [] $ok_rt ["ds-a"]) "on 1/2 running"
    assert equal (container-status-label [$e1 $e2] [] $ok_rt ["ds-a" "ds-b"]) "on 2/2 running"
    assert equal (container-status-label [$e1 $e2] [] $ok_rt []) "on 0/2 running"

    let down_rt = { runtime: "docker", status: "daemon_down", detail: "" }
    let no_rt = { runtime: "", status: "no_runtime", detail: "" }
    assert equal (container-status-label [$e1 $e2] [] $down_rt []) "on (daemon down)"
    assert equal (container-status-label [$e1 $e2] [] $no_rt []) "on (no runtime)"
}
