#!/usr/bin/env bash
set -euo pipefail

# Upgrade script for Wazuh dependencies
# Usage: ./upgrade-wazuh.sh <new-version> [dependency-version]
# Example: ./upgrade-wazuh.sh 4.14.2 47

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WAZUH_AGENT_NIX="${SCRIPT_DIR}/../wazuh-agent.nix"
DEPS_DIR="${SCRIPT_DIR}"

if [ $# -lt 1 ]; then
    echo "Usage: $0 <new-wazuh-version> [dependency-version]"
    echo "Example: $0 4.14.2 47"
    echo ""
    echo "If dependency-version is not provided, it will be inferred from the current version."
    exit 1
fi

NEW_VERSION="$1"
DEPENDENCY_VERSION="${2:-}"

# Extract current version and dependency version from wazuh-agent.nix
CURRENT_VERSION=$(grep -E '^\s*version\s*=' "$WAZUH_AGENT_NIX" | head -1 | sed -E 's/.*"([^"]+)".*/\1/')
CURRENT_DEP_VERSION=$(grep -E '^\s*dependencyVersion\s*=' "$WAZUH_AGENT_NIX" | head -1 | sed -E 's/.*"([^"]+)".*/\1/')

echo "Current Wazuh version: ${CURRENT_VERSION}"
echo "Current dependency version: ${CURRENT_DEP_VERSION}"
echo "Upgrading to Wazuh version: ${NEW_VERSION}"

# If dependency version not provided, try to infer it or use current
if [ -z "$DEPENDENCY_VERSION" ]; then
    echo "Checking Wazuh Makefile for dependency version..."
    # Try to fetch the Makefile from GitHub to check dependency version
    TEMP_MAKEFILE=$(mktemp)
    if curl -sf "https://raw.githubusercontent.com/wazuh/wazuh/v${NEW_VERSION}/src/Makefile" > "$TEMP_MAKEFILE" 2>/dev/null; then
        # Look for DEPENDENCY_VERSION or similar pattern in Makefile
        NEW_DEP_VERSION=$(grep -E "DEPENDENCY_VERSION|deps/[0-9]+" "$TEMP_MAKEFILE" | head -1 | grep -oE '[0-9]+' | head -1 || echo "")
        rm -f "$TEMP_MAKEFILE"
        if [ -n "$NEW_DEP_VERSION" ]; then
            DEPENDENCY_VERSION="$NEW_DEP_VERSION"
            echo "Found dependency version in Makefile: ${DEPENDENCY_VERSION}"
        else
            DEPENDENCY_VERSION="$CURRENT_DEP_VERSION"
            echo "Could not determine dependency version, using current: ${DEPENDENCY_VERSION}"
        fi
    else
        DEPENDENCY_VERSION="$CURRENT_DEP_VERSION"
        echo "Could not fetch Makefile, using current dependency version: ${DEPENDENCY_VERSION}"
    fi
fi

echo ""
echo "=== Step 1: Updating external dependencies ==="
cd "$DEPS_DIR"
./prefetch-external-dependencies.sh

echo ""
echo "=== Step 2: Updating libbpf-bootstrap commit ==="
# Get latest commit from libbpf-bootstrap
LIBBPF_COMMIT=$(git ls-remote https://github.com/libbpf/libbpf-bootstrap.git HEAD | cut -f1)
echo "Latest libbpf-bootstrap commit: ${LIBBPF_COMMIT}"

# Get hash for the commit
LIBBPF_HASH=$(nix-prefetch-git https://github.com/libbpf/libbpf-bootstrap.git --rev "$LIBBPF_COMMIT" --quiet | \
    jq -r '.sha256' | \
    xargs nix hash convert --from nix32 --to sri --hash-algo sha256)
echo "Hash: ${LIBBPF_HASH}"

echo ""
echo "=== Step 3: Updating modern.bpf.c hash ==="
MODERN_BPF_URL="https://raw.githubusercontent.com/wazuh/wazuh/v${NEW_VERSION}/src/syscheckd/src/ebpf/src/modern.bpf.c"
MODERN_BPF_HASH=$(nix-prefetch-url "$MODERN_BPF_URL" --type sha256 | \
    xargs nix hash convert --from nix32 --to sri --hash-algo sha256)
echo "modern.bpf.c hash: ${MODERN_BPF_HASH}"

echo ""
echo "=== Step 4: Updating wazuh-http-request ==="
# Get the commit from the wazuh-http-request repo that matches the Wazuh version
# Usually it's in a submodule or referenced in the Wazuh repo
HTTP_REQUEST_COMMIT=$(git ls-remote https://github.com/wazuh/wazuh-http-request.git HEAD | cut -f1)
echo "Latest wazuh-http-request commit: ${HTTP_REQUEST_COMMIT}"

HTTP_REQUEST_HASH=$(nix-prefetch-git https://github.com/wazuh/wazuh-http-request.git --rev "$HTTP_REQUEST_COMMIT" --quiet | \
    jq -r '.sha256' | \
    xargs nix hash convert --from nix32 --to sri --hash-algo sha256)
echo "Hash: ${HTTP_REQUEST_HASH}"

echo ""
echo "=== Step 5: Updating wazuh-agent.nix ==="
cd "$(dirname "$WAZUH_AGENT_NIX")"

# Update version
sed -i "s/version = \"${CURRENT_VERSION}\";/version = \"${NEW_VERSION}\";/" "$WAZUH_AGENT_NIX"

# Update dependency version
sed -i "s/dependencyVersion = \"${CURRENT_DEP_VERSION}\";/dependencyVersion = \"${DEPENDENCY_VERSION}\";/" "$WAZUH_AGENT_NIX"

# Update wazuh-http-request
CURRENT_HTTP_REV=$(grep -E '^\s*rev\s*=' "$WAZUH_AGENT_NIX" | grep -A 2 "wazuh-http-request" | grep rev | sed -E 's/.*"([^"]+)".*/\1/')
CURRENT_HTTP_HASH=$(grep -E '^\s*sha256\s*=' "$WAZUH_AGENT_NIX" | grep -B 2 "wazuh-http-request" | grep sha256 | sed -E 's/.*"([^"]+)".*/\1/')
sed -i "s|rev = \"${CURRENT_HTTP_REV}\";|rev = \"${HTTP_REQUEST_COMMIT}\";|" "$WAZUH_AGENT_NIX"
sed -i "s|sha256 = \"${CURRENT_HTTP_HASH}\";|sha256 = \"${HTTP_REQUEST_HASH}\";|" "$WAZUH_AGENT_NIX"

# Update libbpf-bootstrap
CURRENT_LIBBPF_REV=$(grep -E '^\s*rev\s*=' "$WAZUH_AGENT_NIX" | grep -A 2 "libbpf-bootstrap" | grep rev | sed -E 's/.*"([^"]+)".*/\1/')
CURRENT_LIBBPF_HASH=$(grep -E '^\s*sha256\s*=' "$WAZUH_AGENT_NIX" | grep -B 2 "libbpf-bootstrap" | grep sha256 | head -1 | sed -E 's/.*"([^"]+)".*/\1/')
sed -i "s|rev = \"${CURRENT_LIBBPF_REV}\";|rev = \"${LIBBPF_COMMIT}\";|" "$WAZUH_AGENT_NIX"
sed -i "s|sha256 = \"${CURRENT_LIBBPF_HASH}\";|sha256 = \"${LIBBPF_HASH}\";|" "$WAZUH_AGENT_NIX"

# Update modern.bpf.c URL and hash
sed -i "s|url = \"https://raw.githubusercontent.com/wazuh/wazuh/v\${version}/src/syscheckd/src/ebpf/src/modern.bpf.c\";|url = \"https://raw.githubusercontent.com/wazuh/wazuh/v${NEW_VERSION}/src/syscheckd/src/ebpf/src/modern.bpf.c\";|" "$WAZUH_AGENT_NIX"
CURRENT_MODERN_HASH=$(grep -E '^\s*hash\s*=' "$WAZUH_AGENT_NIX" | grep -B 2 "modern.bpf.c" | grep hash | sed -E 's/.*"([^"]+)".*/\1/')
sed -i "s|hash = \"${CURRENT_MODERN_HASH}\";|hash = \"${MODERN_BPF_HASH}\";|" "$WAZUH_AGENT_NIX"

# Update comments with prefetch commands
sed -i "s|# nix-prefetch-git https://github.com/libbpf/libbpf-bootstrap.git.*|# nix-prefetch-git https://github.com/libbpf/libbpf-bootstrap.git ${LIBBPF_COMMIT}|" "$WAZUH_AGENT_NIX"
sed -i "s|# nix-prefetch-url https://raw.githubusercontent.com/wazuh/wazuh/v[0-9.]+/src/syscheckd/src/ebpf/src/modern.bpf.c.*|# nix-prefetch-url https://raw.githubusercontent.com/wazuh/wazuh/v${NEW_VERSION}/src/syscheckd/src/ebpf/src/modern.bpf.c --type sha256 | xargs nix hash convert --from nix32 --to sri --hash-algo sha256|" "$WAZUH_AGENT_NIX"

echo ""
echo "=== Summary ==="
echo "✓ Updated version: ${CURRENT_VERSION} → ${NEW_VERSION}"
echo "✓ Updated dependency version: ${CURRENT_DEP_VERSION} → ${DEPENDENCY_VERSION}"
echo "✓ Updated external dependencies"
echo "✓ Updated libbpf-bootstrap: ${CURRENT_LIBBPF_REV} → ${LIBBPF_COMMIT}"
echo "✓ Updated modern.bpf.c hash"
echo "✓ Updated wazuh-http-request: ${CURRENT_HTTP_REV} → ${HTTP_REQUEST_COMMIT}"
echo ""
echo "Please review the changes in ${WAZUH_AGENT_NIX} and test the build!"

