#!/usr/bin/env bash
set -euo pipefail

# Script to update Wazuh agent version in the Nix flake
# Usage: ./update-version.sh <new_version> <dependency_version>
# Example: ./update-version.sh 4.13.1 43

if [ $# -ne 2 ]; then
    echo "Usage: $0 <new_version> <dependency_version>"
    echo "Example: $0 4.13.1 43"
    echo ""
    echo "To find the dependency version, check:"
    echo "https://github.com/wazuh/wazuh/blob/v<version>/src/Makefile"
    echo "Search for 'DEPS_VERSION' or similar variable"
    exit 1
fi

NEW_VERSION="$1"
DEP_VERSION="$2"

echo "Updating Wazuh agent to version $NEW_VERSION (dependency version: $DEP_VERSION)"
echo ""

# 1. Update version and dependency version in wazuh-agent.nix
echo "[1/6] Updating version numbers in wazuh-agent.nix..."
sed -i "s/version = \".*\";/version = \"$NEW_VERSION\";/" pkgs/wazuh-agent.nix
sed -i "s/dependencyVersion = \".*\";/dependencyVersion = \"$DEP_VERSION\";/" pkgs/wazuh-agent.nix

# 2. Fetch new Wazuh source SHA256
echo "[2/6] Fetching Wazuh source SHA256..."
WAZUH_SHA=$(nix-prefetch-url --unpack "https://github.com/wazuh/wazuh/archive/refs/tags/v${NEW_VERSION}.tar.gz" --type sha256 2>/dev/null | xargs nix hash convert --from nix32 --to sri --hash-algo sha256)
echo "  SHA256: $WAZUH_SHA"
sed -i "s|sha256 = \"sha256-.*\";  # src|sha256 = \"$WAZUH_SHA\";  # src|" pkgs/wazuh-agent.nix
# Fallback if no comment marker
sed -i "/fetchFromGitHub/,/};/{s/sha256 = \"sha256-.*\";/sha256 = \"$WAZUH_SHA\";/;}" pkgs/wazuh-agent.nix

# 3. Fetch modern.bpf.c hash
echo "[3/6] Fetching modern.bpf.c hash..."
BPF_HASH=$(nix-prefetch-url "https://raw.githubusercontent.com/wazuh/wazuh/v${NEW_VERSION}/src/syscheckd/src/ebpf/src/modern.bpf.c" --type sha256 2>/dev/null | xargs nix hash convert --from nix32 --to sri --hash-algo sha256)
echo "  Hash: $BPF_HASH"
sed -i "s|hash = \"sha256-.*\";  # modern.bpf.c|hash = \"$BPF_HASH\";  # modern.bpf.c|" pkgs/wazuh-agent.nix
# Fallback if no comment marker
sed -i "/modern_bpf_c = fetchurl/,/};/{s/hash = \"sha256-.*\";/hash = \"$BPF_HASH\";/;}" pkgs/wazuh-agent.nix

# 4. Fetch ossec-agent.conf hash
echo "[4/6] Fetching ossec-agent.conf hash..."
CONFIG_HASH=$(nix-prefetch-url "https://raw.githubusercontent.com/wazuh/wazuh/refs/tags/v${NEW_VERSION}/etc/ossec-agent.conf" --type sha256 2>/dev/null | xargs nix hash convert --from nix32 --to sri --hash-algo sha256)
echo "  Hash: $CONFIG_HASH"
sed -i "s|sha256 = \"sha256-.*\";  # ossec-agent.conf|sha256 = \"$CONFIG_HASH\";  # ossec-agent.conf|" modules/wazuh-agent/generate-agent-config.nix
# Fallback if no comment marker
sed -i "s/sha256 = \"sha256-.*\";/sha256 = \"$CONFIG_HASH\";/" modules/wazuh-agent/generate-agent-config.nix

# 5. Update dependency version in prefetch script
echo "[5/6] Updating dependency version in prefetch script..."
sed -i "s/DEPENDENCY_VERSION=.*/DEPENDENCY_VERSION=$DEP_VERSION/" pkgs/dependencies/prefetch-external-dependencies.sh

# 6. Update external dependencies hashes
echo "[6/6] Updating external dependency hashes..."
echo "  This may take a while..."
cd pkgs/dependencies
./prefetch-external-dependencies.sh > /dev/null 2>&1
cd ../..

echo ""
echo "✓ Update complete!"
echo ""
echo "Summary of changes:"
echo "  - Version: $NEW_VERSION"
echo "  - Dependency version: $DEP_VERSION"
echo "  - Wazuh source SHA: $WAZUH_SHA"
echo "  - modern.bpf.c hash: $BPF_HASH"
echo "  - ossec-agent.conf hash: $CONFIG_HASH"
echo "  - External dependencies updated"
echo ""
echo "Next steps:"
echo "  1. Review changes: git diff"
echo "  2. Test build: nix build .#wazuh-agent"
echo "  3. Test patches still apply (build will fail if they don't)"
echo "  4. Commit changes: git add -A && git commit -m 'Update Wazuh agent to v$NEW_VERSION'"
