set shell := ["nu", "-c"]

default:
    @just --list

test:
    nu tests/run.nu

# Run Stage 2 sandbox verification against migrated Phase 2 module worktrees
test-phase2 target="all":
    nu tests/test_phase2_modules.nu {{target}}
