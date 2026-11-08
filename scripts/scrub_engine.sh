#!/bin/bash
# Removes build-machine paths (your home folder, this project's location) from the staged
# engine, so the app you share doesn't reveal them. Safe to run more than once.
# Fails if any such path is still left anywhere in build/engine-stage.
set -euo pipefail

cd "$(dirname "$0")/.."
STAGE="$PWD/build/engine-stage"
PY_DIR="$STAGE/python"
[ -d "$PY_DIR" ] || { echo "No staged engine at $STAGE" >&2; exit 1; }

# 1. Launcher scripts pip wrote into python/bin start with the build folder's path.
#    The engine only ever runs `python3 main.py`, so they are not needed.
for script in "$PY_DIR"/bin/*; do
    [ -L "$script" ] && continue
    case "$(basename "$script")" in python3*|python) continue ;; esac
    if grep -qF "$STAGE" "$script" 2>/dev/null; then
        rm -f "$script"
    fi
done

# 2. Python's build settings record where uv unpacked it. Put back the standalone build's
#    own placeholder prefix (/install); Python finds its real location at run time.
/usr/bin/python3 - "$STAGE" "$PY_DIR"/lib/python3*/_sysconfigdata_*.py <<'EOF'
import re, sys
stage, files = sys.argv[1], sys.argv[2:]
pattern = re.compile(re.escape(stage) + r"/(?:\.uv/[^/'\" ]+|python)")
for path in files:
    text = open(path).read()
    cleaned = pattern.sub("/install", text)
    if cleaned != text:
        open(path, "w").write(cleaned)
EOF

# 3. The Python library's install name is the folder uv unpacked it into. Nothing links to it
#    by that name (the python3 executable is self-contained), so use a neutral one.
for lib in "$PY_DIR"/lib/libpython3*.dylib; do
    [ -L "$lib" ] && continue
    install_name_tool -id "@rpath/$(basename "$lib")" "$lib" 2>/dev/null
done

# 4. Check: no file may mention the home folder or the project folder.
leaks="$(grep -rlaF -e "$HOME" -e "$PWD" "$STAGE" 2>/dev/null || true)"
if [ -n "$leaks" ]; then
    echo "Build-machine paths are still in these engine files:" >&2
    echo "$leaks" >&2
    exit 1
fi
echo "Engine contains no build-machine paths."
