#!/usr/bin/env bash
# scripts/install.sh — Pure user-space bootstrapper for Yggdrasil (ygg) on Unix/Linux/macOS
set -euo pipefail

echo "==> Installing Yggdrasil (ygg)..."

# 1. Ensure user-space directory ~/.local/bin exists and is in PATH
mkdir -p "$HOME/.local/bin"
export PATH="$HOME/.local/bin:$PATH"

# 2. Check or install mise (user-space polyglot runtime manager)
if ! command -v mise >/dev/null 2>&1; then
    echo "==> mise not found, installing mise (user-space)..."
    curl -fsSL https://mise.run | sh
fi

# Activate mise shims in current subshell
if command -v mise >/dev/null 2>&1; then
    eval "$(mise activate bash --shims 2>/dev/null || true)"
elif [ -x "$HOME/.local/bin/mise" ]; then
    eval "$("$HOME/.local/bin/mise" activate bash --shims 2>/dev/null || true)"
fi

# 3. Ensure nushell is installed via mise
if ! command -v nu >/dev/null 2>&1; then
    echo "==> Installing nushell via mise..."
    mise use -g nushell
    eval "$(mise activate bash --shims 2>/dev/null || true)"
fi

if ! command -v nu >/dev/null 2>&1; then
    echo "Error: failed to install or locate nushell ('nu')." >&2
    exit 1
fi

# 4. Clone or update ygg engine in ~/.ygg/.engine
#    YGG_CHANNEL=stable (default): latest v<semver> release tag; YGG_CHANNEL=main: tip of main
YGG_DIR="${YGG_HOME:-$HOME/.ygg}"
ENGINE_DIR="${YGG_DIR}/.engine"
YGG_CHANNEL="${YGG_CHANNEL:-stable}"
case "$YGG_CHANNEL" in
    stable|main) ;;
    *) echo "Error: YGG_CHANNEL must be 'stable' or 'main' (got '$YGG_CHANNEL')." >&2; exit 1 ;;
esac

mkdir -p "$YGG_DIR"
if [ ! -d "${ENGINE_DIR}/.git" ]; then
    echo "==> Cloning ygg engine to ${ENGINE_DIR}..."
    rm -rf "${ENGINE_DIR}"
    git clone --quiet https://github.com/gidragir/ygg.git "${ENGINE_DIR}"
elif [ -n "$(git -C "${ENGINE_DIR}" status --porcelain --untracked-files=no)" ]; then
    echo "==> ${ENGINE_DIR} has uncommitted changes, leaving the engine as is." >&2
    YGG_CHANNEL=keep
else
    echo "==> Updating existing ygg engine in ${ENGINE_DIR}..."
    git -C "${ENGINE_DIR}" fetch --quiet --tags --force origin
fi

if [ "$YGG_CHANNEL" = "stable" ]; then
    YGG_TAG="$(git -C "${ENGINE_DIR}" tag --list 'v*' --sort=v:refname | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | tail -n 1 || true)"
    if [ -n "$YGG_TAG" ]; then
        echo "==> Using ygg release ${YGG_TAG}"
        git -C "${ENGINE_DIR}" -c advice.detachedHead=false checkout --quiet --detach "$YGG_TAG"
    else
        echo "==> No ygg release tags found, falling back to main." >&2
        YGG_CHANNEL=main
    fi
fi
if [ "$YGG_CHANNEL" = "main" ]; then
    echo "==> Using ygg main branch"
    git -C "${ENGINE_DIR}" checkout --quiet main
    git -C "${ENGINE_DIR}" merge --quiet --ff-only origin/main
fi

# 5. Create user-space shim in ~/.local/bin/ygg
echo "==> Creating shim in $HOME/.local/bin/ygg..."
chmod +x "${ENGINE_DIR}/bin/ygg"
ln -sfn "${ENGINE_DIR}/bin/ygg" "$HOME/.local/bin/ygg"

echo ""
echo "✅ Yggdrasil installed successfully!"
echo "Make sure '$HOME/.local/bin' is in your PATH."
