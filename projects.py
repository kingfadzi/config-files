#!/usr/bin/env python3

import argparse
import os
import sys
import subprocess
import shutil
import zipfile
import urllib.request
import fnmatch
from pathlib import Path
import yaml  # assumes PyYAML is installed

def load_config(path):
    if not os.path.isfile(path):
        print(f"Error: config file not found: {path}")
        sys.exit(1)
    with open(path, 'r') as f:
        return yaml.safe_load(f)

def setup_proxy():
    opener = urllib.request.build_opener(urllib.request.ProxyHandler())
    urllib.request.install_opener(opener)
    proxies = {k: os.environ.get(k) for k in ("HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY")}
    if any(proxies.values()):
        print(f"Loaded proxy settings from env: {proxies}")

def git_pull_if_repo(target_dir):
    git_dir = os.path.join(target_dir, '.git')
    if os.path.isdir(git_dir):
        print(f"Running git pull in {target_dir}")
        subprocess.run(['git', '-C', target_dir, 'pull'], check=True)

def download_zip(url, dest):
    print(f"Downloading: {url}")
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    urllib.request.urlretrieve(url, dest)

def unzip_file(zip_path, extract_to):
    print(f"Unzipping to: {extract_to}")
    if os.path.isdir(extract_to):
        shutil.rmtree(extract_to)
    with zipfile.ZipFile(zip_path, 'r') as z:
        z.extractall(os.path.dirname(extract_to))

def clean_target_dir(target_dir, skip_patterns):
    """
    Delete everything in target_dir except:
      1) the .git directory
      2) hidden files/dirs (starting with '.')
      3) names matching any skip_patterns
    """
    if not os.path.isdir(target_dir):
        return
    print(f"Cleaning {target_dir}, preserving .git, hidden files, and patterns: {skip_patterns}")
    for name in os.listdir(target_dir):
        full = os.path.join(target_dir, name)

        # 1) always preserve the VCS directory
        if name == '.git':
            print(f"  Preserving VCS dir {name}")
            continue

        # 2) always preserve hidden files/dirs
        if name.startswith('.'):
            print(f"  Preserving hidden {name}")
            continue

        # 3) preserve skip patterns
        if any(fnmatch.fnmatch(name, pat) for pat in skip_patterns):
            print(f"  Preserving {name}")
            continue

        # otherwise delete
        print(f"  Deleting {full}")
        if os.path.isdir(full):
            shutil.rmtree(full)
        else:
            os.remove(full)

def copy_with_skip(src_root, dst_root, skip_patterns):
    """Recursively copy src_root → dst_root, skipping any file/dir matching skip_patterns."""
    print(f"Copying from {src_root} to {dst_root}, skipping patterns: {skip_patterns}")
    for root, dirs, files in os.walk(src_root):
        rel = os.path.relpath(root, src_root)
        dst_dir = os.path.join(dst_root, rel) if rel != '.' else dst_root

        # skip entire directory if its basename matches skip_patterns
        base = os.path.basename(root)
        if rel != '.' and any(fnmatch.fnmatch(base, pat) for pat in skip_patterns):
            print(f"  Skipping directory {rel}")
            dirs[:] = []  # do not recurse
            continue

        os.makedirs(dst_dir, exist_ok=True)

        # copy files
        for f in files:
            if any(fnmatch.fnmatch(f, pat) for pat in skip_patterns):
                print(f"  Skipping file {os.path.join(rel, f)}")
                continue
            src_file = os.path.join(root, f)
            dst_file = os.path.join(dst_dir, f)
            shutil.copy2(src_file, dst_file)
            print(f"  Copied {os.path.join(rel, f)}")

def process_repo(repo_cfg, downloads):
    owner       = repo_cfg.get('repo_owner')
    name        = repo_cfg.get('repo_name')
    branch      = repo_cfg.get('branch')
    target      = repo_cfg.get('target_dir')
    skip        = repo_cfg.get('skip_patterns', [])
    enabled     = repo_cfg.get('enabled', True)

    if not all([owner, name, branch, target]):
        print("  Error: each repo needs repo_owner, repo_name, branch, target_dir")
        return
    if not enabled:
        print(f"  Skipping {owner}/{name}@{branch} (enabled: false)")
        return

    zip_path   = downloads / f"{name}_{branch}.zip"
    extract_to = downloads / f"{name}-{branch}"
    url        = f"https://github.com/{owner}/{name}/archive/refs/heads/{branch}.zip"

    print(f"\n=== Processing {owner}/{name}@{branch} ===")
    git_pull_if_repo(target)
    download_zip(url, str(zip_path))
    unzip_file(str(zip_path), str(extract_to))
    clean_target_dir(target, skip)
    copy_with_skip(str(extract_to), target, skip)

def main():
    parser = argparse.ArgumentParser(
        description="Pull, unzip & sync one or more GitHub repos, preserving .git and hidden files"
    )
    parser.add_argument('config_file', help='Path to config.yaml')
    args = parser.parse_args()

    cfg = load_config(args.config_file)
    repos = cfg.get('repos', [])
    if not isinstance(repos, list) or not repos:
        print("Error: config.yaml must have a top-level 'repos:' list")
        sys.exit(1)

    downloads = Path.home() / 'Downloads'
    setup_proxy()

    for repo in repos:
        process_repo(repo, downloads)

    print("\nAll done.")

if __name__ == '__main__':
    main()
