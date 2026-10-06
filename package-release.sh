#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h}"
python3 - "$ROOT" <<'PY'
from pathlib import Path
import hashlib, os, plistlib, shutil, subprocess, sys, tempfile, zipfile
root = Path(sys.argv[1])
version = plistlib.loads((root/'Info.plist').read_bytes())['CFBundleShortVersionString']
arch = os.environ.get('MIXER_ARCH', subprocess.check_output(['uname','-m'], text=True).strip())
if arch not in ('arm64', 'x86_64'): raise SystemExit('Unsupported architecture')
def clean_copy(src, dst):
    shutil.copyfile(src, dst)
    shutil.copymode(src, dst)
    return dst
with tempfile.TemporaryDirectory(prefix='macmixer-release-', dir='/tmp') as directory:
    staged = Path(directory)
    for name in ('Sources', 'Resources'):
        shutil.copytree(root/name, staged/name, copy_function=clean_copy)
    for name in ('build.sh', 'Info.plist'):
        clean_copy(root/name, staged/name)
    env = dict(os.environ, MIXER_SIGNING='adhoc', MIXER_ARCH=arch)
    subprocess.run(['zsh', str(staged/'build.sh')], env=env, check=True)
    app = staged/'build/Mixer.app'
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
    binary = (app/'Contents/MacOS/Mixer').read_bytes()
    home = str(Path.home()).encode()
    if home in binary: raise SystemExit('Personal home path found in release binary')
    out = root/'dist'; out.mkdir(exist_ok=True)
    archive = out/f'Mixer-{version}-macos-{arch}.zip'
    with zipfile.ZipFile(archive, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        for path in sorted(app.rglob('*')):
            if path.is_file() and path.name != '.DS_Store':
                z.write(path, path.relative_to(app.parent).as_posix())
    checksum = hashlib.sha256(archive.read_bytes()).hexdigest()
    archive.with_suffix('.zip.sha256').write_text(f'{checksum}  {archive.name}\n')
    print(f'Packaged {archive.name}: {archive.stat().st_size} bytes')
PY
