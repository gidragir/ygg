#!/usr/bin/env nu
# scripts/release.nu — Release preparation (local) and tag checks (.github/workflows/release.yml)
#
#   nu scripts/release.nu prepare [version] [--dry-run]   bump YGG_VERSION, regenerate CHANGELOG.md, commit; tag on main
#   nu scripts/release.nu tag                             tag main's HEAD with the version from YGG_VERSION
#   nu scripts/release.nu verify <tag>                    CI check (writes `version`/`prerelease` to $GITHUB_OUTPUT)
#
# Local entry points: `mise run release [version] [--dry-run]` and `mise run release-tag`.

export use ../src/engine.nu [read-ygg-version]

const SEMVER = '^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(-[0-9A-Za-z.-]+)?$'

# "" when `tag` is a v<semver> tag for `version`, otherwise the reason it is not
export def release-tag-error [tag: string, version: string]: nothing -> string {
    if not (($tag | str starts-with "v") and (($tag | str substring 1..) =~ $SEMVER)) {
        return $"tag '($tag)' is not v<semver> \(e.g. v1.2.3 or v1.2.3-rc.1\)"
    }
    if ($tag != $"v($version)") {
        return $"tag '($tag)' does not match YGG_VERSION '($version)' in bin/ygg.nu"
    }
    ""
}

# A semver pre-release suffix (v1.2.3-rc.1) marks a GitHub pre-release
export def is-prerelease [tag: string]: nothing -> bool {
    $tag =~ '^v[^-]+-.+'
}

# "v0.3.0" / "0.3.0" -> "0.3.0"; error for anything that is not semver
export def normalize-version [raw: string]: nothing -> string {
    let v = ($raw | str trim | str replace --regex '^v' '')
    if not ($v =~ $SEMVER) {
        error make { msg: $"'($raw)' is not a semver version \(e.g. 0.3.0 or 1.0.0-rc.1\)" }
    }
    $v
}

# `content` of bin/ygg.nu with YGG_VERSION set to `version`
export def set-ygg-version [content: string, version: string]: nothing -> string {
    if not ($content =~ '(?m)^const YGG_VERSION = "[^"]+"') {
        error make { msg: "YGG_VERSION constant not found" }
    }
    $content | str replace --regex '(?m)^const YGG_VERSION = "[^"]+"' $'const YGG_VERSION = "($version)"'
}

# `content` of .github/workflows/module-check.yml with inputs.ygg-version.default set to `v<version>`
export def set-workflow-ygg-version [content: string, version: string]: nothing -> string {
    let ver = ($version | str trim | str replace --regex '^v' '')
    let default_pat = r#'^([ \t]+default:[ \t]*)['"]?v[^#'"\r\n]+['"]?([ \t]*(?:#.*)?\r?)$'#
    let lines = ($content | split row "\n")
    mut in_block = false
    mut base_indent = -1
    mut replaced = false
    mut out: list<string> = []

    for line in $lines {
        let trimmed = ($line | str trim)
        let indent = (($line | str length) - ($line | str trim --left | str length))
        if (not $replaced) and ($line =~ '^[ \t]*ygg-version:[ \t]*(?:#.*)?\r?$') {
            $in_block = true
            $base_indent = $indent
            $out = ($out | append $line)
            continue
        }
        if $in_block and (not $replaced) {
            if ($trimmed == "") or ($trimmed starts-with "#") {
                $out = ($out | append $line)
                continue
            }
            if $indent <= $base_indent {
                $in_block = false
            } else if ($line =~ $default_pat) {
                let rep = ('${1}' + $"'v($ver)'" + '${2}')
                $out = ($out | append ($line | str replace --regex $default_pat $rep))
                $replaced = true
                $in_block = false
                continue
            }
        }
        $out = ($out | append $line)
    }

    if not $replaced {
        error make { msg: "ygg-version default not found in workflow" }
    }
    $out | str join "\n"
}

def repo-root []: nothing -> string {
    $env.FILE_PWD | path dirname
}

def git [root: string, ...args: string]: nothing -> record {
    ^git -C $root ...$args | complete
}

def git-ok [root: string, ...args: string]: nothing -> string {
    let r = (^git -C $root ...$args | complete)
    if $r.exit_code != 0 {
        error make { msg: $"git ($args | str join ' ') failed: ($r.stderr | str trim)" }
    }
    $r.stdout | str trim
}

def fail [msg: string] {
    print -e $"Error: ($msg)"
    exit 1
}

def assert-clean [root: string] {
    if (git-ok $root "status" "--porcelain" "--untracked-files=no") != "" {
        fail "working tree has uncommitted changes; commit or stash them first"
    }
}

def tag-exists [root: string, tag: string]: nothing -> bool {
    (git $root "rev-parse" "--verify" "--quiet" $"refs/tags/($tag)").exit_code == 0
}

def push-hint [tag: string]: nothing -> string {
    $"git push --atomic origin main ($tag)"
}

# Tag HEAD as `tag` (annotated); HEAD must be on main and equal to origin/main
def create-release-tag [root: string, tag: string] {
    let branch = (git-ok $root "branch" "--show-current")
    if $branch != "main" {
        fail $"release tags are created on main \(current branch: '($branch)'\)"
    }
    if (tag-exists $root $tag) {
        fail $"tag ($tag) already exists"
    }
    git-ok $root "tag" "--annotate" $tag "--message" $"ygg ($tag)" | ignore
    print $"Tagged ($tag). Publish it with: (push-hint $tag)"
    print "The Release workflow runs the test matrix and creates the GitHub Release."
}

def main [] {
    print "Usage: nu scripts/release.nu (prepare [version] [--dry-run] | tag | verify <tag>)"
}

# Bump YGG_VERSION, regenerate CHANGELOG.md and commit; on main also create the tag
def "main prepare" [
    version: string = "", # Explicit version; default: next version from conventional commits (git-cliff)
    --dry-run # Print the plan without changing anything
] {
    let root = (repo-root)
    if (which git-cliff | is-empty) {
        fail "git-cliff is not on PATH (run `mise install`)"
    }
    if $dry_run {
        if (git-ok $root "status" "--porcelain" "--untracked-files=no") != "" {
            print -e "Warning: working tree has uncommitted changes; a real run would refuse"
        }
    } else {
        assert-clean $root
    }

    let ygg_bin = ($root | path join "bin" "ygg.nu")
    let workflow_file = ($root | path join ".github" "workflows" "module-check.yml")
    let current = (read-ygg-version $ygg_bin)
    let next = if $version != "" {
        normalize-version $version
    } else {
        let r = (do { cd $root; ^git-cliff --bumped-version } | complete)
        if $r.exit_code != 0 {
            fail $"git-cliff --bumped-version failed: ($r.stderr | str trim)"
        }
        normalize-version ($r.stdout | lines | last | default "")
    }
    let tag = $"v($next)"
    if ($next == $current) or (tag-exists $root $tag) {
        fail $"nothing to release: ($tag) already exists or equals YGG_VERSION \(no feat/fix/perf commits since the last tag?\)"
    }

    let branch = (git-ok $root "branch" "--show-current")
    print $"Release ($current) -> ($next) on branch '($branch)'"
    if $dry_run {
        print "  would set YGG_VERSION in bin/ygg.nu"
        print "  would set ygg-version default in .github/workflows/module-check.yml"
        print $"  would regenerate CHANGELOG.md with git-cliff --tag ($tag)"
        print $"  would commit 'chore\(release\): ($tag)'"
        if $branch == "main" { print $"  would create tag ($tag)" }
        return
    }

    let updated_bin = (set-ygg-version (open --raw $ygg_bin) $next)
    let updated_wf = (set-workflow-ygg-version (open --raw $workflow_file) $next)
    $updated_bin | save --force $ygg_bin
    $updated_wf | save --force $workflow_file
    let cl = (do { cd $root; ^git-cliff --tag $tag --output CHANGELOG.md } | complete)
    if $cl.exit_code != 0 {
        git $root "checkout" "--" "bin/ygg.nu" ".github/workflows/module-check.yml" "CHANGELOG.md" | ignore
        fail $"git-cliff failed: ($cl.stderr | str trim)"
    }
    git-ok $root "add" "bin/ygg.nu" ".github/workflows/module-check.yml" "CHANGELOG.md" | ignore
    git-ok $root "commit" "--quiet" "--message" $"chore\(release\): ($tag)" | ignore
    print $"Committed chore\(release\): ($tag)"

    if $branch == "main" {
        create-release-tag $root $tag
    } else {
        print "Push the branch and merge the PR, then on main run: mise run release-tag"
    }
}

# Tag main's HEAD with the version from YGG_VERSION (after a release PR is merged)
def "main tag" [] {
    let root = (repo-root)
    assert-clean $root
    git-ok $root "fetch" "--quiet" "origin" "main" | ignore
    if (git-ok $root "rev-parse" "HEAD") != (git-ok $root "rev-parse" "origin/main") {
        fail "local main is not at origin/main; run `git pull --ff-only` first"
    }
    let version = (read-ygg-version ($root | path join "bin" "ygg.nu"))
    create-release-tag $root $"v($version)"
}

# CI: the pushed tag matches YGG_VERSION
def "main verify" [tag: string] {
    let ygg_bin = (repo-root | path join "bin" "ygg.nu")
    let version = (read-ygg-version $ygg_bin)
    let err = (release-tag-error $tag $version)
    if ($err != "") {
        fail $err
    }
    let pre = (is-prerelease $tag)
    print $"Release ($tag): version ($version), prerelease ($pre)"
    let out = ($env.GITHUB_OUTPUT? | default "")
    if ($out != "") {
        $"version=($version)\nprerelease=($pre)\n" | save --append $out
    }
}
