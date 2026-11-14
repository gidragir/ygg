#!/usr/bin/env nu
# scripts/release.nu — Release tag checks for .github/workflows/release.yml
# Usage: nu scripts/release.nu <tag>   (writes `version` and `prerelease` to $GITHUB_OUTPUT if set)

const SEMVER_TAG = '^v(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(-[0-9A-Za-z.-]+)?$'

# Version from `const YGG_VERSION = "..."` in bin/ygg.nu (the single source of truth)
export def read-ygg-version [file: string]: nothing -> string {
    let m = (open --raw $file | parse --regex '(?m)^const YGG_VERSION = "(?<v>[^"]+)"')
    if ($m | is-empty) {
        error make { msg: $"YGG_VERSION constant not found in '($file)'" }
    }
    $m | first | get v
}

# "" when `tag` is a v<semver> tag for `version`, otherwise the reason it is not
export def release-tag-error [tag: string, version: string]: nothing -> string {
    if not ($tag =~ $SEMVER_TAG) {
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

def main [tag: string] {
    let ygg_bin = ($env.FILE_PWD | path join ".." "bin" "ygg.nu")
    let version = (read-ygg-version $ygg_bin)
    let err = (release-tag-error $tag $version)
    if ($err != "") {
        print -e $"Error: ($err)"
        exit 1
    }
    let pre = (is-prerelease $tag)
    print $"Release ($tag): version ($version), prerelease ($pre)"
    let out = ($env.GITHUB_OUTPUT? | default "")
    if ($out != "") {
        $"version=($version)\nprerelease=($pre)\n" | save --append $out
    }
}
