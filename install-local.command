#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h}"
"$ROOT/build.sh"
DEST="/Applications/Mixer.app"
if [[ -d "$DEST" ]]; then
  INSTALLED_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$DEST/Contents/Info.plist")
  [[ "$INSTALLED_ID" == "com.codex.mixer" ]] || { echo "Já existe outro aplicativo com esse nome."; exit 1; }
fi
python3 - "$ROOT" <<'PY_STOP'
import os, re, signal, subprocess, sys, time
paths = ['/Applications/Mixer.app/Contents/MacOS/Mixer', sys.argv[1] + '/build/Mixer.app/Contents/MacOS/Mixer']
pids = []
for path in paths:
    result = subprocess.run(['pgrep', '-f', '^' + re.escape(path) + '$'], capture_output=True, text=True)
    for value in result.stdout.split():
        pid = int(value)
        try: os.kill(pid, signal.SIGTERM); pids.append(pid)
        except ProcessLookupError: pass
for _ in range(30):
    alive = []
    for pid in pids:
        try: os.kill(pid, 0); alive.append(pid)
        except ProcessLookupError: pass
    if not alive: break
    time.sleep(.1)
else: raise SystemExit('Feche o Mixer antes de atualizar a cópia instalada.')
PY_STOP
python3 - "$ROOT/build/Mixer.app" "$DEST" <<'PY'
import shutil, sys
from pathlib import Path
src, dst = map(Path, sys.argv[1:])
def clean_copy(source, target):
    shutil.copyfile(source, target)
    shutil.copymode(source, target)
    return target
shutil.copytree(src, dst, dirs_exist_ok=True, copy_function=clean_copy)
PY
codesign --verify --deep --strict "$DEST"
# Refresh the installed bundle registration after icon/version updates.
/usr/bin/touch "$DEST"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST"
if [[ "${1:-}" != "--no-open" ]]; then open "$DEST"; fi
echo "Mixer instalado em $DEST"
