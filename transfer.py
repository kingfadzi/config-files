#!/usr/bin/env python3
"""
tar_and_scp.py

Creates a gzip-compressed tarball of a given path—excluding any paths matching
skip_patterns—and uploads it via SFTP using username/password credentials
collected at runtime. Supports multiple transfers defined in YAML, each of which
can be enabled or disabled.

Requires:
    pip install PyYAML paramiko
"""

import argparse
import sys
import tarfile
import datetime
from pathlib import Path
import getpass
import fnmatch

import yaml   # assumes PyYAML is installed
import paramiko

def parse_args():
  parser = argparse.ArgumentParser(
    description="Archive files/dirs (with excludes) and upload them via SFTP"
  )
  parser.add_argument(
    "config_file",
    help="Path to config.yaml defining transfers"
  )
  return parser.parse_args()

def load_config(path: Path):
  if not path.is_file():
    print(f"Error: config file not found: {path}", file=sys.stderr)
    sys.exit(1)
  cfg = yaml.safe_load(path.read_text())
  transfers = cfg.get("transfers")
  if not isinstance(transfers, list) or not transfers:
    print("Error: config.yaml must contain a 'transfers:' list", file=sys.stderr)
    sys.exit(1)
  return transfers

def make_tarball(src: Path, skip_patterns: list[str]) -> Path:
  """
  Create a tar.gz of `src`, excluding any files/dirs whose
  path relative to `src` matches one of skip_patterns.
  """
  base = src.name
  date_str = datetime.date.today().isoformat()
  tarball = Path(f"{base}-{date_str}.tar.gz")
  print(f"Creating archive '{tarball}' from '{src}', excluding {skip_patterns}...")
  def _filter(tarinfo: tarfile.TarInfo):
    # path inside archive, relative to base/
    name = Path(tarinfo.name)
    try:
      rel = name.relative_to(base)
    except Exception:
      rel = name
    rel_str = rel.as_posix()
    for pat in skip_patterns:
      if fnmatch.fnmatch(rel_str, pat) or fnmatch.fnmatch(rel.name, pat):
        print(f"  Skipping {tarinfo.name} (matches '{pat}')")
        return None
    return tarinfo

  with tarfile.open(tarball, "w:gz") as tf:
    tf.add(src, arcname=base, filter=_filter)
  print("Archive created.")
  return tarball

def sftp_upload(tarball: Path, host: str, username: str, password: str, remote_dir: str):
  print(f"Uploading '{tarball}' to {username}@{host}:{remote_dir}/ via SFTP")
  ssh = paramiko.SSHClient()
  ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
  ssh.connect(hostname=host, username=username, password=password)
  sftp = ssh.open_sftp()
  try:
    # mkdir -p remote_dir
    try:
      sftp.chdir(remote_dir)
    except IOError:
      curr = Path("/")
      for part in Path(remote_dir).parts:
        curr = curr / part
        try:
          sftp.chdir(str(curr))
        except IOError:
          sftp.mkdir(str(curr))
          sftp.chdir(str(curr))
    remote_path = f"{remote_dir.rstrip('/')}/{tarball.name}"
    sftp.put(str(tarball), remote_path)
    print("Upload complete.")
  finally:
    sftp.close()
    ssh.close()

def main():
  args = parse_args()
  transfers = load_config(Path(args.config_file))

  for job in transfers:
    enabled = job.get("enabled", True)
    if not enabled:
      print(f"Skipping disabled transfer for source '{job.get('source')}'")
      continue

    src = Path(job.get("source", ""))
    if not src.exists():
      print(f"Warning: source '{src}' does not exist, skipping.", file=sys.stderr)
      continue

    host       = job.get("host")
    remote_dir = job.get("remote_dir")
    skip       = job.get("skip_patterns", [])
    if not host or not remote_dir:
      print("Warning: missing host/remote_dir in entry, skipping.", file=sys.stderr)
      continue

    # prompt for username (default from YAML if provided)
    default_user = job.get("username", "")
    prompt = f"Username for {host}"
    if default_user:
      prompt += f" [{default_user}]"
    prompt += ": "
    user = input(prompt).strip() or default_user
    if not user:
      print("Error: username is required", file=sys.stderr)
      continue

    # prompt for password
    password = getpass.getpass(f"Password for {user}@{host}: ")

    tarball = make_tarball(src, skip)
    try:
      sftp_upload(tarball, host, user, password, remote_dir)
    except Exception as e:
      print(f"Error uploading to {host}: {e}", file=sys.stderr)
    finally:
      # optionally cleanup:
      # tarball.unlink()
      pass

if __name__ == "__main__":
  main()
