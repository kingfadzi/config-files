#!/usr/bin/env python3

import argparse
import sys
import tarfile
import datetime
from pathlib import Path
import getpass

import yaml   # assumes PyYAML is installed
import paramiko

def parse_args():
  parser = argparse.ArgumentParser(
    description="Archive files/dirs and upload them to multiple remotes via SFTP"
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
  with path.open() as f:
    cfg = yaml.safe_load(f)
  transfers = cfg.get("transfers")
  if not isinstance(transfers, list) or not transfers:
    print("Error: config.yaml must contain a 'transfers:' list", file=sys.stderr)
    sys.exit(1)
  return transfers

def make_tarball(src: Path) -> Path:
  base = src.name
  date_str = datetime.date.today().isoformat()
  tarball = Path(f"{base}-{date_str}.tar.gz")
  print(f"Creating archive '{tarball}' from '{src}'...")
  with tarfile.open(tarball, "w:gz") as tf:
    tf.add(src, arcname=base)
  print("Archive created.")
  return tarball

def sftp_upload(tarball: Path, host: str, username: str, password: str, remote_dir: str):
  print(f"Uploading '{tarball}' to {username}@{host}:{remote_dir}/ via SFTP")
  ssh = paramiko.SSHClient()
  ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
  ssh.connect(hostname=host, username=username, password=password)
  sftp = ssh.open_sftp()
  try:
    # mkdir -p equivalent
    try:
      sftp.chdir(remote_dir)
    except IOError:
      parts = Path(remote_dir).parts
      curr = ""
      for p in parts:
        curr = f"{curr}/{p}" if curr else p
        try:
          sftp.chdir(curr)
        except IOError:
          sftp.mkdir(curr)
          sftp.chdir(curr)
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
    src = Path(job.get("source", ""))
    if not src.exists():
      print(f"Warning: source '{src}' does not exist, skipping.", file=sys.stderr)
      continue

    host = job.get("host")
    remote_dir = job.get("remote_dir")
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

    tarball = make_tarball(src)
    try:
      sftp_upload(tarball, host, user, password, remote_dir)
    except Exception as e:
      print(f"Error uploading to {host}: {e}", file=sys.stderr)
    finally:
      # optionally remove local tarball:
      # tarball.unlink()
      pass

if __name__ == "__main__":
  main()
