# tests/test_release.nu
# Tests for scripts/release.nu: tag/version consistency checked by the release workflow

use std/assert
use ../scripts/release.nu [read-ygg-version, release-tag-error, is-prerelease, normalize-version, set-ygg-version, set-workflow-ygg-version]
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

export def test_normalize_version_strips_v_and_validates [] {
    assert equal (normalize-version "v0.3.0") "0.3.0"
    assert equal (normalize-version " 1.0.0-rc.1
") "1.0.0-rc.1"
    let failed = (try { normalize-version "0.3"; false } catch { true })
    assert $failed "a non-semver version must be rejected"
}

export def test_set_ygg_version_replaces_only_the_const [] {
    let src = "use ../src *

const YGG_VERSION = \"0.2.0\"
# YGG_VERSION is the single source
"
    let out = (set-ygg-version $src "0.3.0")
    assert ($out | str contains 'const YGG_VERSION = "0.3.0"')
    assert ($out | str contains "# YGG_VERSION is the single source")
    assert equal ($out | lines | length) ($src | lines | length)
    let failed = (try { set-ygg-version "def main [] {}" "0.3.0"; false } catch { true })
    assert $failed "content without YGG_VERSION must be rejected"
}

# regression: #38
export def test_set_workflow_ygg_version [] {
    let sample = "on:
  workflow_call:
    inputs:
      ygg-version:
        description: 'Version of ygg'
        type: string
        default: 'v0.3.0'
      module-path:
        default: '.'
"
    let updated = (set-workflow-ygg-version $sample "0.4.0")
    assert ($updated | str contains "default: 'v0.4.0'")
    assert ($updated | str contains "default: '.'")
    assert equal ($updated | lines | length) ($sample | lines | length)

    let pre = (set-workflow-ygg-version $sample "v0.4.0-rc.1")
    assert ($pre | str contains "default: 'v0.4.0-rc.1'")

    let missing_nested = "on:
  workflow_call:
    inputs:
      ygg-version:
        type: string
      other-input:
        default: 'v0.1.0'
"
    let failed_missing = (try { set-workflow-ygg-version "on: [push]" "0.4.0"; false } catch { true })
    assert $failed_missing "content without ygg-version must be rejected"
    let failed_nested = (try { set-workflow-ygg-version $missing_nested "0.4.0"; false } catch { true })
    assert $failed_nested "ygg-version without default must not touch sibling input"

    let root = ($env.FILE_PWD | path join ".." | path expand)
    let ygg_ver = (read-ygg-version ($root | path join "bin" "ygg.nu"))
    let wf_path = ($root | path join ".github" "workflows" "module-check.yml")
    let wf_raw = (open --raw $wf_path)
    assert ($wf_raw | str contains $"default: 'v($ygg_ver)'") "module-check.yml default ygg-version must match YGG_VERSION"
}
