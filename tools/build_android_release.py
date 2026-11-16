#!/usr/bin/env python3
"""Build a signed Android release using a local, external signing configuration."""
import argparse
import json
import os
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--signing-config', type=Path, required=True,
                    help='Private JSON outside the checkout: keystore, store_password, alias, key_password')
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
config = args.signing_config.expanduser().resolve()
if config.is_relative_to(root):
    raise SystemExit('Keep signing material outside the source checkout')
settings = json.loads(config.read_text())
keystore = Path(settings['keystore']).expanduser().resolve()
if keystore.is_relative_to(root) or not keystore.is_file():
    raise SystemExit('Use an existing keystore outside the source checkout')
env = dict(os.environ, CMF_ANDROID_KEYSTORE=str(keystore),
           CMF_ANDROID_STORE_PASSWORD=settings['store_password'],
           CMF_ANDROID_KEY_ALIAS=settings['alias'],
           CMF_ANDROID_KEY_PASSWORD=settings['key_password'])
subprocess.run([str(root/'android/gradlew'), '-p', str(root/'android'),
                ':protocol:test', ':app:assembleRelease', '--no-daemon'],
               cwd=root, env=env, check=True)
print('Signed APK: android/app/build/outputs/apk/release/app-release.apk')
