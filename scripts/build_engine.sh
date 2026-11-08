#!/bin/bash
# Stages the ComfyUI engine that ships inside RelayVSR.app:
#   - a standalone Python 3.13 (python-build-standalone, fetched by uv)
#   - PyTorch (pinned below) and the ComfyUI requirements
#   - ComfyUI (without models, outputs or other custom nodes)
#   - the ComfyUI-AppleSilicon-int8-Fast custom node
# ComfyUI and int8-Fast are downloaded from GitHub at the commits pinned below, so no local
# ComfyUI is needed. To use local copies instead, set COMFY_SRC (and INT8_SRC).
# Output: build/engine-stage (copied into the app by build_app.sh).
# Run once; delete build/engine-stage to rebuild from scratch.
set -euo pipefail

cd "$(dirname "$0")/.."

# Sources, pinned to the commits the app was tested with. ComfyUI's RelayVSR nodes are on its
# main branch (not yet in a release); int8-Fast 1.2.0.
COMFY_REPO="https://github.com/comfyanonymous/ComfyUI.git"
COMFY_COMMIT="c76e64fe5f9108af6946ac3a39ff4280142d6dcd"
INT8_REPO="https://github.com/Illuminus7/ComfyUI-AppleSilicon-int8-Fast.git"
INT8_COMMIT="d79490cf566af1c29e8bfab41ef9f0359dc6b5d2"

# PyTorch for Apple Silicon, pinned to the versions the engine was tested with. int8-Fast's Metal
# kernels need PyTorch 2.13 or later; 2.14.1 is the newest with a matching torchvision.
# torchaudio is left out: it stops at 2.11, and the engine does not process audio.
TORCH_PINS=("torch==2.14.1" "torchvision==0.29.2")
STAGE="build/engine-stage"
SOURCES="build/sources"
PY_VERSION="3.13"

if [ -f "$STAGE/.complete" ]; then
    echo "Engine already staged at $STAGE (delete it to rebuild)."
    exit 0
fi

# Downloads one repository at one commit (no history) into build/sources/<name>.
fetch_source() {
    local name="$1" repo="$2" commit="$3" dest="$SOURCES/$1"
    if [ "$(git -C "$dest" rev-parse HEAD 2>/dev/null || true)" = "$commit" ]; then
        echo "==> $name already at ${commit:0:12}"
        return
    fi
    echo "==> Downloading $name at ${commit:0:12}"
    rm -rf "$dest"
    mkdir -p "$dest"
    git -C "$dest" init -q
    git -C "$dest" fetch -q --depth 1 "$repo" "$commit"
    git -C "$dest" -c advice.detachedHead=false checkout -q FETCH_HEAD
}

if [ -z "${COMFY_SRC:-}" ]; then
    fetch_source ComfyUI "$COMFY_REPO" "$COMFY_COMMIT"
    COMFY_SRC="$SOURCES/ComfyUI"
fi
if [ -z "${INT8_SRC:-}" ]; then
    if [ -d "$COMFY_SRC/custom_nodes/ComfyUI-AppleSilicon-int8-Fast" ] && [ "$COMFY_SRC" != "$SOURCES/ComfyUI" ]; then
        INT8_SRC="$COMFY_SRC/custom_nodes/ComfyUI-AppleSilicon-int8-Fast"
    else
        fetch_source ComfyUI-AppleSilicon-int8-Fast "$INT8_REPO" "$INT8_COMMIT"
        INT8_SRC="$SOURCES/ComfyUI-AppleSilicon-int8-Fast"
    fi
fi
NODE_SRC="$INT8_SRC"

for required in "$COMFY_SRC/main.py" "$COMFY_SRC/requirements.txt" "$NODE_SRC/__init__.py"; do
    if [ ! -e "$required" ]; then
        echo "Missing: $required" >&2
        exit 1
    fi
done

rm -rf "$STAGE"
mkdir -p "$STAGE"

echo "==> Fetching standalone Python $PY_VERSION"
UV_PYTHON_INSTALL_DIR="$PWD/$STAGE/.uv" uv python install --no-bin "$PY_VERSION"
PY_BIN="$(UV_PYTHON_INSTALL_DIR="$PWD/$STAGE/.uv" uv python find --managed-python "$PY_VERSION")"
PY_ROOT="$(cd "$(dirname "$PY_BIN")/.." && pwd -P)"
mv "$PY_ROOT" "$STAGE/python"
rm -rf "$STAGE/.uv"
PY="$STAGE/python/bin/python3"
# uv marks its interpreters as externally managed (PEP 668); this copy is ours to fill.
rm -f "$STAGE"/python/lib/python3*/EXTERNALLY-MANAGED

echo "==> Installing PyTorch and ComfyUI requirements"
"$PY" -m pip --version >/dev/null 2>&1 || "$PY" -m ensurepip
"$PY" -m pip install --no-cache-dir --disable-pip-version-check \
    "${TORCH_PINS[@]}" \
    -r "$COMFY_SRC/requirements.txt" \
    -r "$NODE_SRC/requirements.txt"

echo "==> Copying ComfyUI"
mkdir -p "$STAGE/ComfyUI"
# '/.*' skips every hidden top-level entry, including the source install's own .venv
# (about 2 GB that the bundled engine never uses) and .git.
rsync -a \
    --exclude='/.*' --exclude='/models' --exclude='/input' --exclude='/output' \
    --exclude='/temp' --exclude='/user' --exclude='/custom_nodes' --exclude='/tests' \
    --exclude='/tests-unit' --exclude='__pycache__' \
    "$COMFY_SRC/" "$STAGE/ComfyUI/"
mkdir -p "$STAGE/ComfyUI/models/diffusion_models" "$STAGE/ComfyUI/models/vae" "$STAGE/ComfyUI/custom_nodes"

echo "==> Copying the int8-Fast node"
rsync -a --exclude='/.*' --exclude='/tests' --exclude='__pycache__' \
    "$NODE_SRC/" "$STAGE/ComfyUI/custom_nodes/ComfyUI-AppleSilicon-int8-Fast/"

echo "==> Removing bytecode caches"
find "$STAGE" -name "__pycache__" -type d -prune -exec rm -rf {} +

./scripts/scrub_engine.sh

date -u +%Y-%m-%dT%H:%M:%SZ > "$STAGE/.complete"
echo "Engine staged at $STAGE"
