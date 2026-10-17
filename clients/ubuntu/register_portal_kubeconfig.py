#!/usr/bin/env python3
"""One-shot Ubuntu registration; no login, cache access or kubeconfig merge.

TrustDirectory must originate from the independently authenticated distribution,
not the HTTP bundle. It contains minisign, minisign.sha256 and portal-kubeconfig.pub.
"""
from __future__ import annotations
import argparse
import base64
import hashlib
import io
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import tempfile
import zipfile

MAX_CONFIG = 1048576
MAX_SIGNATURE = 16384
NAMES = {'cluster.yaml': MAX_CONFIG, 'cluster.yaml.minisig': MAX_SIGNATURE}


class RegistrationError(Exception):
    pass


def read_limited(path, limit):
    with open(path, 'rb') as stream:
        data = stream.read(limit+1)
    if not data or len(data) > limit:
        raise RegistrationError('INPUT_SIZE_INVALID')
    return data


def bundle_bytes(bundle):
    raw = read_limited(bundle, 2*MAX_CONFIG)
    try:
        with zipfile.ZipFile(io.BytesIO(raw)) as archive:
            members = archive.infolist()
            if len(members) != 2 or {m.filename for m in members} != set(NAMES):
                raise RegistrationError('BUNDLE_MEMBERS_INVALID')
            result = {}
            for member in members:
                mode = member.external_attr >> 16
                if member.flag_bits & 1 or stat.S_ISLNK(mode) or not 0 < member.file_size <= NAMES[member.filename]:
                    raise RegistrationError('BUNDLE_MEMBER_INVALID')
                with archive.open(member) as stream:
                    data = stream.read(NAMES[member.filename]+1)
                if len(data) != member.file_size:
                    raise RegistrationError('BUNDLE_MEMBER_INVALID')
                result[member.filename] = data
            return result
    except (zipfile.BadZipFile, RuntimeError, NotImplementedError, EOFError):
        raise RegistrationError('BUNDLE_INVALID') from None


def trust_material(directory):
    directory = Path(directory).absolute()
    verifier = directory/'minisign'
    expected = read_limited(directory/'minisign.sha256', 100).decode('ascii').strip()
    if not re.fullmatch('[0-9a-f]{64}', expected):
        raise RegistrationError('VERIFIER_PIN_INVALID')
    if hashlib.sha256(read_limited(verifier, 16000000)).hexdigest() != expected:
        raise RegistrationError('VERIFIER_HASH_MISMATCH')
    lines = read_limited(directory/'portal-kubeconfig.pub', 4096).decode('ascii').splitlines()
    if len(lines) != 2 or not lines[0].startswith('untrusted comment: '):
        raise RegistrationError('TRUST_KEY_INVALID')
    try:
        key = base64.b64decode(lines[1], validate=True)
        if len(key) != 42 or key[:2] != b'Ed':
            raise ValueError()
    except ValueError:
        raise RegistrationError('TRUST_KEY_INVALID') from None
    return verifier, lines[1]


def private_root(directory):
    root = Path(os.path.abspath(os.path.expanduser(str(directory))))
    for item in (root, *root.parents):
        if item.is_symlink():
            raise RegistrationError('DESTINATION_SYMLINK')
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    info = root.stat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise RegistrationError('DESTINATION_NOT_PRIVATE')
    return root


def existing_matches(path, content):
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except FileNotFoundError:
        return False
    with os.fdopen(fd, 'rb') as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
            raise RegistrationError('EXISTING_FILE_NOT_PRIVATE')
        if stream.read(MAX_CONFIG+1) != content:
            raise RegistrationError('EXISTING_FILE_CONFLICT')
    return True


def register(bundle, trust_directory, destination_directory):
    if os.name != 'posix':
        raise RegistrationError('UBUNTU_ENTRYPOINT_REQUIRED')
    verifier, public_key = trust_material(trust_directory)
    content = bundle_bytes(bundle)
    config = content['cluster.yaml']
    digest = hashlib.sha256(config).hexdigest()
    root = private_root(destination_directory)
    # Private staging holds a single snapshot of both members. No archive paths
    # are extracted, and verifier stdout/stderr/comments never reach the user.
    with tempfile.TemporaryDirectory(prefix='.register-', dir=root) as temporary:
        stage = Path(temporary)
        for name, value in content.items():
            fd = os.open(stage/name, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, 'wb') as stream:
                stream.write(value)
        result = subprocess.run([str(verifier), '-V', '-H', '-q', '-P', public_key,
                                 '-m', str(stage/'cluster.yaml'), '-x', str(stage/'cluster.yaml.minisig')],
                                stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                stderr=subprocess.DEVNULL, timeout=15, check=False)
        if result.returncode != 0:
            raise RegistrationError('SIGNATURE_INVALID')
        if read_limited(stage/'cluster.yaml', MAX_CONFIG) != config:
            raise RegistrationError('STAGED_BYTES_CHANGED')
        target = root/('portal-'+digest+'.yaml')
        if existing_matches(target, config):
            return {'status':'already_registered', 'path':str(target), 'sha256':digest}
        # Install the exact verified bytes, never a newly read HTTP input. Hard
        # link publishes a complete private inode atomically without overwrite.
        install = stage/'verified.yaml'
        fd = os.open(install, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, 'wb') as stream:
            stream.write(config)
            stream.flush()
            os.fsync(stream.fileno())
        try:
            os.link(install, target, follow_symlinks=False)
        except FileExistsError:
            if not existing_matches(target, config):
                raise RegistrationError('INSTALL_CONFLICT') from None
        return {'status':'registered', 'path':str(target), 'sha256':digest}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bundle', required=True)
    parser.add_argument('--trust-directory', default=str(Path(__file__).resolve().parent))
    parser.add_argument('--destination-directory', default=str(Path.home()/'.kube'/'portal'))
    args = parser.parse_args()
    try:
        print(json.dumps(register(args.bundle, args.trust_directory, args.destination_directory)))
        return 0
    except (RegistrationError, OSError, UnicodeError, subprocess.SubprocessError, ValueError):
        # Never echo file content, subprocess output or a raw exception.
        print(json.dumps({'status':'failed', 'error':'REGISTRATION_FAILED'}))
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
