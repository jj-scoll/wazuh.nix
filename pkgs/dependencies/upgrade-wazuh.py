#!/usr/bin/env python3
"""
upgrade-wazuh.py - Update Wazuh agent and all dependencies in NixOS configuration

Usage:
    ./upgrade-wazuh.py <new-version> [dependency-version]
    ./upgrade-wazuh.py 4.15.0
    ./upgrade-wazuh.py 4.15.0 48
    ./upgrade-wazuh.py --check      # Check for new versions without updating
    ./upgrade-wazuh.py --latest     # Update to latest release
"""

import subprocess
import sys
import re
import json
import urllib.request
from pathlib import Path
from typing import Optional
import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed

# Configuration
SCRIPT_DIR = Path(__file__).parent.resolve()
WAZUH_AGENT_NIX = SCRIPT_DIR.parent / "wazuh-agent.nix"
DEPS_DIR = SCRIPT_DIR

# External dependencies to fetch
EXTERNAL_DEPS = [
    "audit-userspace", "benchmark", "bzip2", "cJSON", "cpp-httplib", "curl",
    "dbus", "flatbuffers", "googletest", "jemalloc", "libarchive",
    "libbpf-bootstrap", "libdb", "libffi", "libpcre2", "libplist", "libyaml",
    "lua", "lzma", "msgpack", "nlohmann", "openssl", "pacman", "popt",
    "procps", "rocksdb", "rpm", "sqlite", "zlib"
]


class Colors:
    RED = "\033[0;31m"
    GREEN = "\033[0;32m"
    YELLOW = "\033[1;33m"
    CYAN = "\033[0;36m"
    BOLD = "\033[1m"
    NC = "\033[0m"


def print_color(msg: str, color: str = Colors.NC) -> None:
    print(f"{color}{msg}{Colors.NC}")


def print_step(step: int, msg: str) -> None:
    print_color(f"\n=== Step {step}: {msg} ===", Colors.BOLD)


def run_cmd(cmd: list[str], capture: bool = True) -> str:
    """Run a command and return stdout."""
    try:
        result = subprocess.run(
            cmd,
            capture_output=capture,
            text=True,
            check=True
        )
        return result.stdout.strip() if capture else ""
    except subprocess.CalledProcessError as e:
        print_color(f"Command failed: {' '.join(cmd)}", Colors.RED)
        if e.stderr:
            print_color(e.stderr, Colors.RED)
        raise


def get_latest_wazuh_version() -> str:
    """Fetch the latest Wazuh version from GitHub releases."""
    url = "https://api.github.com/repos/wazuh/wazuh/releases/latest"
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})

    try:
        with urllib.request.urlopen(req, timeout=10) as response:
            data = json.loads(response.read().decode())
            return data.get("tag_name", "").lstrip("v")
    except Exception as e:
        print_color(f"Failed to fetch latest version: {e}", Colors.RED)
        sys.exit(1)


def get_current_versions() -> tuple[str, str]:
    """Extract current version and dependency version from wazuh-agent.nix."""
    content = WAZUH_AGENT_NIX.read_text()

    version_match = re.search(r'^\s*version\s*=\s*"([^"]+)"', content, re.MULTILINE)
    dep_match = re.search(r'^\s*dependencyVersion\s*=\s*"([^"]+)"', content, re.MULTILINE)

    if not version_match or not dep_match:
        print_color("Could not parse current versions from wazuh-agent.nix", Colors.RED)
        sys.exit(1)

    return version_match.group(1), dep_match.group(1)


def infer_dependency_version(wazuh_version: str, current_dep_version: str) -> str:
    """Try to infer the dependency version from Wazuh's Makefile."""
    url = f"https://raw.githubusercontent.com/wazuh/wazuh/v{wazuh_version}/src/Makefile"

    try:
        req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
        with urllib.request.urlopen(req, timeout=10) as response:
            makefile = response.read().decode()
            # Look for patterns like "deps/47/" or "DEPENDENCY_VERSION := 47"
            match = re.search(r'(?:DEPENDENCY_VERSION|deps/)\s*[:=]?\s*(\d+)', makefile)
            if match:
                return match.group(1)
    except Exception:
        pass

    print_color(f"Could not infer dependency version, using current: {current_dep_version}", Colors.YELLOW)
    return current_dep_version


def nix_prefetch_url(url: str) -> str:
    """Prefetch a URL and return the SRI hash."""
    raw_hash = run_cmd(["nix-prefetch-url", url, "--type", "sha256"])
    sri_hash = run_cmd(["nix", "hash", "convert", "--from", "nix32", "--to", "sri", "--hash-algo", "sha256", raw_hash])
    return sri_hash


def nix_prefetch_git(repo_url: str, rev: Optional[str] = None, fetch_submodules: bool = False) -> tuple[str, str]:
    """Prefetch a git repo and return (commit, SRI hash)."""
    cmd = ["nix-prefetch-git", repo_url, "--quiet"]
    if rev:
        cmd.extend(["--rev", rev])
    if fetch_submodules:
        cmd.append("--fetch-submodules")

    output = run_cmd(cmd)
    data = json.loads(output)

    raw_hash = data["sha256"]
    sri_hash = run_cmd(["nix", "hash", "convert", "--from", "nix32", "--to", "sri", "--hash-algo", "sha256", raw_hash])

    return data["rev"], sri_hash


def get_latest_git_commit(repo_url: str) -> str:
    """Get the latest commit from a git repository."""
    output = run_cmd(["git", "ls-remote", repo_url, "HEAD"])
    return output.split()[0]


def prefetch_external_dependency(dep: str, dep_version: str) -> tuple[str, str]:
    """Prefetch a single external dependency and return (name, hash)."""
    url = f"https://packages.wazuh.com/deps/{dep_version}/libraries/sources/{dep}.tar.gz"
    try:
        sri_hash = nix_prefetch_url(url)
        return dep, sri_hash
    except Exception as e:
        print_color(f"  Failed to fetch {dep}: {e}", Colors.RED)
        return dep, ""


def update_external_dependencies(dep_version: str) -> None:
    """Update all external dependencies in parallel."""
    print_color("Fetching external dependencies (this may take a while)...", Colors.CYAN)

    deps_file = DEPS_DIR / "external_dependencies.nix"
    results: dict[str, str] = {}

    # Parallel fetch for speed
    with ThreadPoolExecutor(max_workers=8) as executor:
        futures = {
            executor.submit(prefetch_external_dependency, dep, dep_version): dep
            for dep in EXTERNAL_DEPS
        }

        for future in as_completed(futures):
            dep, sri_hash = future.result()
            if sri_hash:
                results[dep] = sri_hash
                print_color(f"  ✓ {dep}", Colors.GREEN)
            else:
                print_color(f"  ✗ {dep} (failed)", Colors.RED)

    # Write the nix file
    with deps_file.open("w") as f:
        f.write("{\n")
        for dep in EXTERNAL_DEPS:
            if dep in results:
                f.write(f'\n  "{dep}" = {{\n')
                f.write(f'    name = "{dep}";\n')
                f.write(f'    sha256 = "{results[dep]}";\n')
                f.write("  };\n")
        f.write("}\n")

    # Format with nixfmt if available
    try:
        run_cmd(["nixfmt", str(deps_file)])
    except Exception:
        pass  # nixfmt not available, that's fine


def update_wazuh_agent_nix(
    new_version: str,
    new_dep_version: str,
    main_hash: str,
    http_request_commit: str,
    http_request_hash: str,
    libbpf_commit: str,
    libbpf_hash: str,
    modern_bpf_hash: str
) -> None:
    """Update all version and hash references in wazuh-agent.nix."""
    content = WAZUH_AGENT_NIX.read_text()

    # Update version
    content = re.sub(
        r'(^\s*version\s*=\s*")[^"]+(")',
        rf'\g<1>{new_version}\2',
        content,
        flags=re.MULTILINE
    )

    # Update dependency version
    content = re.sub(
        r'(^\s*dependencyVersion\s*=\s*")[^"]+(")',
        rf'\g<1>{new_dep_version}\2',
        content,
        flags=re.MULTILINE
    )

    # Update main source hash (the one after src = fetchFromGitHub)
    # This is tricky - we need to find the right sha256 in the main src block
    content = re.sub(
        r'(src = fetchFromGitHub \{[^}]*sha256 = ")[^"]+(")',
        rf'\g<1>{main_hash}\2',
        content,
        flags=re.DOTALL
    )

    # Update wazuh-http-request
    content = re.sub(
        r'(wazuh-http-request = fetchFromGitHub \{[^}]*rev = ")[^"]+(")',
        rf'\g<1>{http_request_commit}\2',
        content,
        flags=re.DOTALL
    )
    content = re.sub(
        r'(wazuh-http-request = fetchFromGitHub \{[^}]*sha256 = ")[^"]+(")',
        rf'\g<1>{http_request_hash}\2',
        content,
        flags=re.DOTALL
    )

    # Update libbpf-bootstrap
    content = re.sub(
        r'(bootstrap = fetchFromGitHub \{[^}]*repo = "libbpf-bootstrap"[^}]*rev = ")[^"]+(")',
        rf'\g<1>{libbpf_commit}\2',
        content,
        flags=re.DOTALL
    )
    content = re.sub(
        r'(bootstrap = fetchFromGitHub \{[^}]*repo = "libbpf-bootstrap"[^}]*sha256 = ")[^"]+(")',
        rf'\g<1>{libbpf_hash}\2',
        content,
        flags=re.DOTALL
    )

    # Update modern.bpf.c hash
    content = re.sub(
        r'(modern_bpf_c = fetchurl \{[^}]*hash = ")[^"]+(")',
        rf'\g<1>{modern_bpf_hash}\2',
        content,
        flags=re.DOTALL
    )

    # Update comments with prefetch commands
    content = re.sub(
        r'# nix-prefetch-git https://github.com/wazuh/wazuh\.git v[0-9.]+',
        f'# nix-prefetch-git https://github.com/wazuh/wazuh.git v{new_version}',
        content
    )
    content = re.sub(
        r'# nix-prefetch-git https://github.com/libbpf/libbpf-bootstrap\.git [a-f0-9]+',
        f'# nix-prefetch-git https://github.com/libbpf/libbpf-bootstrap.git {libbpf_commit}',
        content
    )
    content = re.sub(
        r'# nix-prefetch-url https://raw\.githubusercontent\.com/wazuh/wazuh/v[0-9.]+/src/syscheckd',
        f'# nix-prefetch-url https://raw.githubusercontent.com/wazuh/wazuh/v{new_version}/src/syscheckd',
        content
    )

    WAZUH_AGENT_NIX.write_text(content)


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Update Wazuh agent and dependencies in NixOS configuration"
    )
    parser.add_argument("version", nargs="?", help="New Wazuh version (e.g., 4.15.0)")
    parser.add_argument("dep_version", nargs="?", help="Dependency version (optional, will be inferred)")
    parser.add_argument("--check", action="store_true", help="Only check for updates")
    parser.add_argument("--latest", action="store_true", help="Update to latest release")
    parser.add_argument("--skip-deps", action="store_true", help="Skip external dependencies update")
    args = parser.parse_args()

    print_color("=== Wazuh Agent Upgrade Script (Python) ===", Colors.BOLD + Colors.GREEN)

    # Get current versions
    current_version, current_dep_version = get_current_versions()
    print_color(f"Current Wazuh version: {current_version}", Colors.CYAN)
    print_color(f"Current dependency version: {current_dep_version}", Colors.CYAN)

    # Determine target version
    if args.check:
        latest = get_latest_wazuh_version()
        print_color(f"\nLatest available: {latest}", Colors.GREEN)
        if current_version == latest:
            print_color("You're already on the latest version!", Colors.GREEN)
        else:
            print_color(f"Update available: {current_version} → {latest}", Colors.YELLOW)
        return

    if args.latest:
        new_version = get_latest_wazuh_version()
        print_color(f"Latest version: {new_version}", Colors.GREEN)
    elif args.version:
        new_version = args.version
    else:
        parser.print_help()
        sys.exit(1)

    if current_version == new_version:
        print_color("Already at target version!", Colors.GREEN)
        sys.exit(0)

    print_color(f"\nUpgrading: {current_version} → {new_version}", Colors.YELLOW)

    # Determine dependency version
    dep_version = args.dep_version or infer_dependency_version(new_version, current_dep_version)
    print_color(f"Dependency version: {dep_version}", Colors.CYAN)

    # Step 1: Update external dependencies
    if not args.skip_deps:
        print_step(1, "Updating external dependencies")
        update_external_dependencies(dep_version)

    # Step 2: Prefetch main Wazuh source
    print_step(2, "Prefetching main Wazuh source")
    main_commit, main_hash = nix_prefetch_git(
        "https://github.com/wazuh/wazuh.git",
        rev=f"v{new_version}"
    )
    print_color(f"Main source hash: {main_hash}", Colors.GREEN)

    # Step 3: Update libbpf-bootstrap
    print_step(3, "Updating libbpf-bootstrap")
    libbpf_commit = get_latest_git_commit("https://github.com/libbpf/libbpf-bootstrap.git")
    print_color(f"Latest commit: {libbpf_commit[:12]}...", Colors.CYAN)
    _, libbpf_hash = nix_prefetch_git(
        "https://github.com/libbpf/libbpf-bootstrap.git",
        rev=libbpf_commit,
        fetch_submodules=True
    )
    print_color(f"Hash: {libbpf_hash}", Colors.GREEN)

    # Step 4: Update modern.bpf.c
    print_step(4, "Updating modern.bpf.c hash")
    modern_bpf_url = f"https://raw.githubusercontent.com/wazuh/wazuh/v{new_version}/src/syscheckd/src/ebpf/src/modern.bpf.c"
    modern_bpf_hash = nix_prefetch_url(modern_bpf_url)
    print_color(f"Hash: {modern_bpf_hash}", Colors.GREEN)

    # Step 5: Update wazuh-http-request
    print_step(5, "Updating wazuh-http-request")
    http_commit = get_latest_git_commit("https://github.com/wazuh/wazuh-http-request.git")
    print_color(f"Latest commit: {http_commit[:12]}...", Colors.CYAN)
    _, http_hash = nix_prefetch_git(
        "https://github.com/wazuh/wazuh-http-request.git",
        rev=http_commit
    )
    print_color(f"Hash: {http_hash}", Colors.GREEN)

    # Step 6: Update wazuh-agent.nix
    print_step(6, "Updating wazuh-agent.nix")
    update_wazuh_agent_nix(
        new_version=new_version,
        new_dep_version=dep_version,
        main_hash=main_hash,
        http_request_commit=http_commit,
        http_request_hash=http_hash,
        libbpf_commit=libbpf_commit,
        libbpf_hash=libbpf_hash,
        modern_bpf_hash=modern_bpf_hash
    )
    print_color(f"Updated {WAZUH_AGENT_NIX}", Colors.GREEN)

    # Summary
    print_color("\n=== Summary ===", Colors.BOLD + Colors.GREEN)
    print_color(f"✓ Updated version: {current_version} → {new_version}", Colors.GREEN)
    print_color(f"✓ Updated dependency version: {current_dep_version} → {dep_version}", Colors.GREEN)
    if not args.skip_deps:
        print_color("✓ Updated external dependencies", Colors.GREEN)
    print_color(f"✓ Updated libbpf-bootstrap: {libbpf_commit[:12]}...", Colors.GREEN)
    print_color("✓ Updated modern.bpf.c hash", Colors.GREEN)
    print_color(f"✓ Updated wazuh-http-request: {http_commit[:12]}...", Colors.GREEN)

    print_color("\nPlease review the changes and test the build!", Colors.YELLOW)
    print_color("  nix build .#wazuh-agent --dry-run", Colors.CYAN)
    print_color("  # or", Colors.NC)
    print_color("  nh os switch --verbose --update .", Colors.CYAN)


if __name__ == "__main__":
    main()
