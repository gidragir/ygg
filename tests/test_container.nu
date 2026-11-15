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
