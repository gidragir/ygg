# tests/test_engine.nu
# Tests for src/engine.nu: release tag selection, update check and engine self-update

use std/assert
use ../src/engine.nu *
use helpers.nu [with-temp-ygg]

def g [dir: string, ...args: string]: nothing -> string {
    let r = (^git -C $dir -c user.name=Tester -c user.email=t@t.local -c commit.gpgsign=false -c tag.gpgsign=false ...$args | complete)
    if $r.exit_code != 0 {
        error make { msg: $"git ($args | str join ' ') failed: ($r.stderr)" }
    }
    $r.stdout | str trim
}

def commit-version [work: string, version: string] {
    mkdir ($work | path join "bin")
    $"#!/usr/bin/env nu\nconst YGG_VERSION = \"($version)\"\n" | save -f ($work | path join "bin" "ygg.nu")
    g $work "add" "." | ignore
    g $work "commit" "--quiet" "-m" $"release ($version)" | ignore
}

# origin.git with v0.1.0, v0.2.0, v0.3.0-rc.1 and an untagged 0.3.0-dev tip on main; engine = a clone of it
def make-engine [home: string]: nothing -> record<origin: string, work: string, engine: string> {
    let origin = ($home | path join "origin.git")
    let work = ($home | path join "work")
    let engine = ($home | path join "engine")
    ^git init --quiet --bare -b main $origin
    ^git init --quiet -b main $work
    g $work "remote" "add" "origin" $origin | ignore
    commit-version $work "0.1.0"
    g $work "tag" "v0.1.0" | ignore
    commit-version $work "0.2.0"
    g $work "tag" "v0.2.0" | ignore
    commit-version $work "0.3.0-rc.1"
    g $work "tag" "v0.3.0-rc.1" | ignore
    commit-version $work "0.3.0-dev"
    g $work "push" "--quiet" "origin" "main" "--tags" | ignore
    ^git clone --quiet $origin $engine
    { origin: $origin, work: $work, engine: $engine }
}

def engine-version [engine: string]: nothing -> string {
    read-ygg-version ($engine | path join "bin" "ygg.nu")
}

export def test_latest_stable_tag_orders_numerically_and_skips_prereleases [] {
    assert equal (latest-stable-tag ["v0.9.0", "v0.10.0", "v0.2.1", "v1.0.0-rc.1", "vfoo", "0.11.0"]) "v0.10.0"
    assert equal (latest-stable-tag ["v1.0.0-rc.1"]) ""
    assert equal (latest-stable-tag []) ""
}

export def test_parse_remote_tags_reads_ls_remote_output [] {
    let out = "abc123\trefs/tags/v0.1.0\ndef456\trefs/tags/v0.2.0\n"
    assert equal (parse-remote-tags $out) ["v0.1.0", "v0.2.0"]
}

export def test_self_update_stable_checks_out_latest_release [] {
    with-temp-ygg { |home|
        let r = (make-engine $home)
        assert equal (engine-version $r.engine) "0.3.0-dev"
        let res = (engine-self-update $r.engine)
        assert equal $res.status "updated"
        assert equal $res.ref "v0.2.0"
        assert equal $res.from "0.3.0-dev"
        assert equal $res.to "0.2.0"
        assert equal (engine-version $r.engine) "0.2.0"
        assert equal (g $r.engine "branch" "--show-current") ""

        let again = (engine-self-update $r.engine)
        assert equal $again.status "up_to_date"
    }
}

export def test_self_update_stable_picks_up_new_release [] {
    with-temp-ygg { |home|
        let r = (make-engine $home)
        engine-self-update $r.engine | ignore
        commit-version $r.work "0.3.0"
        g $r.work "tag" "v0.3.0" | ignore
        g $r.work "push" "--quiet" "origin" "main" "--tags" | ignore

        let check = (engine-check-update $r.engine)
        assert equal $check { current: "0.2.0", latest: "0.3.0", update_available: true }

        let res = (engine-self-update $r.engine)
        assert equal $res.status "updated"
        assert equal $res.to "0.3.0"
        assert equal (engine-check-update $r.engine).update_available false
    }
}

export def test_self_update_main_follows_branch_tip [] {
    with-temp-ygg { |home|
        let r = (make-engine $home)
        engine-self-update $r.engine | ignore
        commit-version $r.work "0.4.0-dev"
        g $r.work "push" "--quiet" "origin" "main" | ignore

        let res = (engine-self-update $r.engine --channel main)
        assert equal $res.status "updated"
        assert equal $res.ref "main"
        assert equal (engine-version $r.engine) "0.4.0-dev"
        assert equal (g $r.engine "branch" "--show-current") "main"
    }
}

export def test_self_update_refuses_dirty_checkout [] {
    with-temp-ygg { |home|
        let r = (make-engine $home)
        "# local edit\n" | save --append ($r.engine | path join "bin" "ygg.nu")
        let err = (try { engine-self-update $r.engine; "" } catch { |e| $e.msg })
        assert ($err | str contains "uncommitted changes") $err
        assert equal (engine-version $r.engine) "0.3.0-dev"
    }
}

export def test_self_update_rejects_unknown_channel_and_non_git_dir [] {
    with-temp-ygg { |home|
        let r = (make-engine $home)
        let err = (try { engine-self-update $r.engine --channel nightly; "" } catch { |e| $e.msg })
        assert ($err | str contains "unknown channel") $err

        let plain = ($home | path join "plain")
        mkdir $plain
        let err2 = (try { engine-self-update $plain; "" } catch { |e| $e.msg })
        assert ($err2 | str contains "not a git checkout") $err2
    }
}
