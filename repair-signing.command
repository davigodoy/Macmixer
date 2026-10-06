#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h}"
python3 - "$ROOT" <<'PY'
from pathlib import Path
import subprocess, secrets, sys, hashlib, tempfile, shutil, os
root=Path(sys.argv[1]); p=root/'build/Signing'; p.mkdir(mode=0o700,parents=True,exist_ok=True)
secret=p/'keychain-password'
if not secret.exists(): secret.write_text(secrets.token_hex(32)); secret.chmod(0o600)
pw=secret.read_text(); keychain=p/'Mixer.keychain-db'; cert=p/'certificate.pem'
def run(args):
    result=subprocess.run(args,capture_output=True,text=True)
    if result.returncode:
        raise SystemExit(result.stderr.replace(pw,'[oculto]'))
    return result.stdout
if not keychain.exists():
    cert=p/'certificate.pem'
    if not cert.exists():
        config=p/'certificate.conf'
        config.write_text('[req]\nprompt=no\ndistinguished_name=dn\nx509_extensions=extensions\n[dn]\nCN=Mixer Local Development\n[extensions]\nbasicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=codeSigning\nsubjectKeyIdentifier=hash\n')
        run(['openssl','req','-new','-newkey','rsa:2048','-x509','-days','3650','-nodes','-config',str(config),'-keyout',str(p/'private.pem'),'-out',str(cert)])
        (p/'private.pem').chmod(0o600)
    run(['security','create-keychain','-p',pw,str(keychain)])
if (p/'private.pem').exists():
    run(['openssl','pkcs12','-export','-inkey',str(p/'private.pem'),'-in',str(cert),'-out',str(p/'identity.p12'),'-certpbe','PBE-SHA1-3DES','-keypbe','PBE-SHA1-3DES','-macalg','sha1','-passout','file:'+str(secret)])
    (p/'identity.p12').chmod(0o600)
if (p/'identity.p12').exists():
    run(['security','import',str(p/'identity.p12'),'-k',str(keychain),'-P',pw,'-T','/usr/bin/codesign'])
run(['security','unlock-keychain','-p',pw,str(keychain)])
run(['security','set-key-partition-list','-S','apple-tool:,apple:','-s','-k',pw,str(keychain)])
app=root/'build/Mixer.app'
if not app.exists(): raise SystemExit('Compile o Mixer antes de executar o reparo.')
der=subprocess.check_output(['openssl','x509','-in',str(p/'certificate.pem'),'-outform','DER'])
fingerprint=hashlib.sha1(der).hexdigest()
requirement='designated => identifier "com.codex.mixer" and certificate leaf = H"'+fingerprint+'"'
# File Provider may recreate FinderInfo in Documents while codesign runs.
# Sign a clean staging copy, then copy its contents without extended attributes.
with tempfile.TemporaryDirectory(prefix='Mixer-sign-') as staging:
    staged=Path(staging)/'Mixer.app'
    shutil.copytree(app,staged,copy_function=shutil.copyfile)
    run(['codesign','--force','--sign','Mixer Local Development','--keychain',str(keychain),'--timestamp=none','-r','='+requirement,str(staged)])
    run(['codesign','--verify','--deep','--strict',str(staged)])
    shutil.copytree(staged/'Contents',app/'Contents',dirs_exist_ok=True,copy_function=shutil.copyfile)
for attr in ['com.apple.FinderInfo','com.apple.ResourceFork']:
    subprocess.run(['xattr','-dr',attr,str(app)],capture_output=True)
run(['codesign','--verify','--deep',str(app)])
for name in ['private.pem','identity.p12']:
    (p/name).unlink(missing_ok=True)
print('Assinatura estável aplicada e verificada.')
print('Em Acessibilidade: remova a entrada antiga do Mixer e adicione o Mixer.app mostrado no Finder.')
print('Depois, feche e reabra o Mixer.')
PY
if [[ "${1:-}" != "--sign-only" ]]; then
open -R "$ROOT/build/Mixer.app"
open 'x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility'

fi
