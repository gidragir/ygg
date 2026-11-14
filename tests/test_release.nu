# tests/test_release.nu
# Tests for scripts/release.nu: tag/version consistency checked by the release workflow

use std/assert
use ../scripts/release.nu [read-ygg-version, release-tag-error, is-prerelease]
use helpers.nu [with-temp-ygg]

export def test_read_ygg_version_parses_const [] {
    with-temp-ygg { |home|
        let f = ($home | path join "ygg.nu")
        "#!/usr/bin/env nu\nuse ../src *\n\nconst YGG_VERSION = \"1.2.3-rc.1\"\n" | save -f $f
        assert equal (read-ygg-version $f) "1.2.3-rc.1"
    }
}

export def test_read_ygg_version_rejects_missing_const [] {
    with-temp-ygg { |home|
        let f = ($home | path join "ygg.nu")
        "def main [] {}\n" | save -f $f
        let failed = (try { read-ygg-version $f; false } catch { true })
        assert $failed "a file without YGG_VERSION must be rejected"
    }
}

export def test_read_ygg_version_matches_cli_output [] {
    let ygg_bin = ($env.FILE_PWD | path join ".." "bin" "ygg.nu" | path expand)
    let out = (^nu $ygg_bin --version | complete)
    assert equal $out.exit_code 0
    assert ($out.stdout | str starts-with $"ygg (read-ygg-version $ygg_bin)")
}

export def test_release_tag_error_accepts_matching_tag [] {
    assert equal (release-tag-error "v0.1.1" "0.1.1") ""
    assert equal (release-tag-error "v1.0.0-rc.2" "1.0.0-rc.2") ""
}

export def test_release_tag_error_rejects_mismatch_and_bad_format [] {
    assert ((release-tag-error "v0.1.2" "0.1.1") | str contains "does not match")
    assert ((release-tag-error "0.1.1" "0.1.1") | str contains "v<semver>")
    assert ((release-tag-error "v0.1" "0.1") | str contains "v<semver>")
    assert ((release-tag-error "vfoo" "foo") | str contains "v<semver>")
}

export def test_is_prerelease_detects_suffix [] {
    assert (is-prerelease "v1.0.0-rc.1")
    assert (not (is-prerelease "v1.0.0"))
}
