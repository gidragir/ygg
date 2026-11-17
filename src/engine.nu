# src/engine.nu
# The ygg engine checkout itself: version, release channels and self-update

use progress.nu [progress-step]

const STABLE_TAG = '^v(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$'
const CHANNELS = ["stable", "main"]

# Version from `const YGG_VERSION = "..."` in bin/ygg.nu (the single source of truth)
export def read-ygg-version [file: string]: nothing -> string {
    let m = (open --raw $file | parse --regex '(?m)^const YGG_VERSION = "(?<v>[^"]+)"')
    if ($m | is-empty) {
        error make { msg: $"YGG_VERSION constant not found in '($file)'" }
    }
    $m | first | get v
}

# Highest stable v<major>.<minor>.<patch> tag (pre-releases excluded), "" when there is none
export def latest-stable-tag [tags: list<string>]: nothing -> string {
    let stable = ($tags
        | each { |t| $t | str trim }
        | where { |t| $t =~ $STABLE_TAG }
        | each { |t|
            let p = ($t | str substring 1.. | split row "." | each { |n| $n | into int })
            { tag: $t, major: $p.0, minor: $p.1, patch: $p.2 }
        })
    if ($stable | is-empty) {
        return ""
    }
    $stable | sort-by major minor patch | last | get tag
}

# Tag names from `git ls-remote --tags --refs` output
export def parse-remote-tags [output: string]: nothing -> list<string> {
    $output | lines | each { |l| $l | parse --regex 'refs/tags/(?<t>\S+)$' | get -o t.0 } | compact
}

def git-out [dir: string, ...args: string]: nothing -> record {
    ^git -C $dir ...$args | complete
}

def engine-version-or-unknown [engine_dir: string]: nothing -> string {
    try { read-ygg-version ($engine_dir | path join "bin" "ygg.nu") } catch { "unknown" }
}

def assert-engine-checkout [engine_dir: string]: nothing -> nothing {
    if not (($engine_dir | path join ".git") | path exists) {
        error make { msg: $"ygg engine at '($engine_dir)' is not a git checkout; reinstall it with scripts/install.sh or scripts/install.ps1" }
    }
}

# Latest stable release on the remote vs the installed version, without touching the checkout
export def engine-check-update [engine_dir: string]: nothing -> record<current: string, latest: string, update_available: bool> {
    assert-engine-checkout $engine_dir
    let res = (git-out $engine_dir "ls-remote" "--tags" "--refs" "origin" "v*")
    if $res.exit_code != 0 {
        error make { msg: $"cannot list remote tags: ($res.stderr | str trim)" }
    }
    let current = (engine-version-or-unknown $engine_dir)
    let tag = (latest-stable-tag (parse-remote-tags $res.stdout))
    let latest = if $tag == "" { "" } else { $tag | str substring 1.. }
    { current: $current, latest: $latest, update_available: (($latest != "") and ($latest != $current)) }
}

# Move the engine checkout to the latest stable tag (default) or to the tip of `main`.
# Refuses a checkout with uncommitted changes to tracked files and never rewrites local history.
export def engine-self-update [
    engine_dir: string,
    --channel: string = "stable" # stable: latest v<semver> tag; main: tip of origin/main
]: nothing -> record<status: string, channel: string, ref: string, from: string, to: string> {
    if $channel not-in $CHANNELS {
        error make { msg: $"unknown channel '($channel)'; expected one of: ($CHANNELS | str join ', ')" }
    }
    assert-engine-checkout $engine_dir

    let st = (git-out $engine_dir "status" "--porcelain" "--untracked-files=no")
    if $st.exit_code != 0 {
        error make { msg: $"cannot read git status of the engine: ($st.stderr | str trim)" }
    }
    if ($st.stdout | str trim) != "" {
        error make { msg: $"engine checkout '($engine_dir)' has uncommitted changes; commit or stash them first" }
    }

    let from = (engine-version-or-unknown $engine_dir)
    let head_before = ((git-out $engine_dir "rev-parse" "HEAD").stdout | str trim)

    progress-step "engine" "fetching releases"
    let fetch = (git-out $engine_dir "fetch" "--quiet" "--tags" "--force" "origin")
    if $fetch.exit_code != 0 {
        error make { msg: $"git fetch failed: ($fetch.stderr | str trim)" }
    }

    let ref = if $channel == "stable" {
        let tag = (latest-stable-tag ((git-out $engine_dir "tag" "--list" "v*").stdout | lines))
        if $tag == "" {
            error make { msg: "no stable release tags found on origin; use --channel main" }
        }
        let target = ((git-out $engine_dir "rev-parse" $"($tag)^{commit}").stdout | str trim)
        let branch = ((git-out $engine_dir "branch" "--show-current").stdout | str trim)
        if ($target != $head_before) or ($branch != "") {
            let co = (git-out $engine_dir "-c" "advice.detachedHead=false" "checkout" "--quiet" "--detach" $tag)
            if $co.exit_code != 0 {
                error make { msg: $"cannot check out ($tag): ($co.stderr | str trim)" }
            }
        }
        $tag
    } else {
        let has_main = ((git-out $engine_dir "rev-parse" "--verify" "--quiet" "refs/heads/main").exit_code == 0)
        let co = if $has_main {
            git-out $engine_dir "checkout" "--quiet" "main"
        } else {
            git-out $engine_dir "checkout" "--quiet" "-b" "main" "--track" "origin/main"
        }
        if $co.exit_code != 0 {
            error make { msg: $"cannot check out main: ($co.stderr | str trim)" }
        }
        let ff = (git-out $engine_dir "merge" "--quiet" "--ff-only" "origin/main")
        if $ff.exit_code != 0 {
            error make { msg: $"local main has diverged from origin/main; resolve it manually: ($ff.stderr | str trim)" }
        }
        "main"
    }

    let head_after = ((git-out $engine_dir "rev-parse" "HEAD").stdout | str trim)
    {
        status: (if $head_after == $head_before { "up_to_date" } else { "updated" })
        channel: $channel
        ref: $ref
        from: $from
        to: (engine-version-or-unknown $engine_dir)
    }
}
