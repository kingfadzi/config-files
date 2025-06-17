#!/usr/bin/env python3

import argparse
import os
import sys
import subprocess
import shutil
import zipfile
import urllib.request
from pathlib import Path

# You need PyYAML: pip install PyYAML
try:
    import yaml
except ImportError:
    print("Error: PyYAML is required. Install with 'pip install PyYAML'")
    sys.exit(1)


def load_config(path):
    if not os.path.isfile(path):
        print(f"Error: config file not found: {path}")
        sys.exit(1)
    with open(path, 'r') as f:
        return yaml.safe_load(f)


def git_pull_if_repo(target_dir):
    git_dir = os.path.join(target_dir, '.git')
    if os.path.isdir(git_dir):
        print(f"Running git pull in {target_dir}")
        subprocess.run(['git', '-C', target_dir, 'pull'], check=True)


def download_zip(url, dest):
    print(f"Downloading: {url}")
    dest_parent = os.path.dirname(dest)
    os.makedirs(dest_parent, exist_ok=True)
    urllib.request.urlretrieve(url, dest)


def unzip_file(zip_path, extract_to):
    print(f"Unzipping to: {extract_to}")
    # ensure clean extract directory
    if os.path.isdir(extract_to):
        shutil.rmtree(extract_to)
    with zipfile.ZipFile(zip_path, 'r') as z:
        z.extractall(os.path.dirname(extract_to))


def clean_target_dirs(target_dir, dirs):
    print(f"Cleaning target directories in: {target_dir}")
    for d in dirs:
        sub = os.path.join(target_dir, d)
        if os.path.isdir(sub):
            print(f"Deleting {sub}")
            shutil.rmtree(sub)


def copy_dirs(unzip_dir, target_dir, dirs):
    print("Copying updated directories")
    for d in dirs:
        src = os.path.join(unzip_dir, d)
        dest = os.path.join(target_dir, d)
        if os.path.isdir(src):
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            shutil.copytree(src, dest)
            print(f"Copied {src} → {dest}")
        else:
            print(f"Warning: {src} not found")


def main():
    parser = argparse.ArgumentParser(
        description="Pull, download, unzip, clean and copy directories based on a YAML config"
    )
    parser.add_argument('config_file', help='Path to config.yaml')
    args = parser.parse_args()

    cfg = load_config(args.config_file)
    repo_owner   = cfg.get('repo_owner')
    repo_name    = cfg.get('repo_name')
    branch       = cfg.get('branch')
    target_dir   = cfg.get('target_dir')
    dirs_to_copy = cfg.get('dirs_to_copy', [])

    if not all([repo_owner, repo_name, branch, target_dir]):
        print("Error: config.yaml must define repo_owner, repo_name, branch, and target_dir")
        sys.exit(1)

    downloads = Path.home() / 'Downloads'
    tmp_zip   = str(downloads / f"{repo_name}_{branch}.zip")
    unzip_dir = str(downloads / f"{repo_name}-{branch}")

    zip_url = f"https://github.com/{repo_owner}/{repo_name}/archive/refs/heads/{branch}.zip"

    # 1. git pull if needed
    git_pull_if_repo(target_dir)

    # 2. download ZIP
    download_zip(zip_url, tmp_zip)

    # 3. unzip
    unzip_file(tmp_zip, unzip_dir)

    # 4. clean old
    clean_target_dirs(target_dir, dirs_to_copy)

    # 5. copy new
    copy_dirs(unzip_dir, target_dir, dirs_to_copy)

    print("Done.")


if __name__ == '__main__':
    main()
