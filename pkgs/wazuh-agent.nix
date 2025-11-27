{
  autoconf,
  automake,
  clang,
  cmake,
  curl,
  elfutils,
  expat,
  fetchFromGitHub,
  fetchurl,
  lib,
  libbfd,
  libbpf,
  libcap,
  libelf,
  libgcc,
  libtool,
  llvm,
  nlohmann_json,
  openssl,
  patchelf,
  perl,
  pkg-config,
  policycoreutils,
  python311,
  removeReferencesTo,
  stdenv,
  systemd,
  zlib,
  ...
}:
let
  version = "4.14.1";
  dependencyVersion = "47";
  external_dependencies = (
    import ./dependencies {
      inherit fetchurl lib dependencyVersion;
    }
  );
  wazuh-http-request = fetchFromGitHub {
    owner = "wazuh";
    repo = "wazuh-http-request";
    rev = "7667e79a0f2782c268b286d10e7a4526cc8bb6e6";
    sha256 = "sha256-NpBGjQjGIp2HORqwN7v5g5sdk6a2LIuHXYaKzQxrDsM=";
  };
  libbpf_bootstrap_deps = {
    bootstrap = fetchFromGitHub {
      owner = "libbpf";
      repo = "libbpf-bootstrap";
      rev = "7cab3cd36f37e4fc714be3468f46dcfb1902420b";
      sha256 = "sha256-HaLF0i/BPKTi8MhlBhfViZEOC8zXw7XwaiuM0GDETMg="; # nix-prefetch-git https://github.com/libbpf/libbpf-bootstrap.git 7cab3cd36f37e4fc714be3468f46dcfb1902420b
      fetchSubmodules = true;
    };
    modern_bpf_c = fetchurl {
      url = "https://raw.githubusercontent.com/wazuh/wazuh/v${version}/src/syscheckd/src/ebpf/src/modern.bpf.c"; # nix-prefetch-url https://raw.githubusercontent.com/wazuh/wazuh/v4.14.1/src/syscheckd/src/ebpf/src/modern.bpf.c
      hash = "sha256-D7NPWwrBblP43U7DoBgZewo4wmn3HWGr14wU85+fOC8="; # nix-prefetch-url https://raw.githubusercontent.com/wazuh/wazuh/v4.14.1/src/syscheckd/src/ebpf/src/modern.bpf.c --type sha256 | xargs nix hash convert --from nix32 --to sri --hash-algo sha256
    };
  };
in
stdenv.mkDerivation rec {
  pname = "wazuh-agent";
  inherit version;

  src = fetchFromGitHub {
    owner = "wazuh";
    repo = "wazuh";
    rev = "v${version}";
    sha256 = "sha256-p9ZuG//4Et7tTGhDfvHFVmpSK253r8OXBdV9+8RrREE="; # nix-prefetch-git https://github.com/wazuh/wazuh.git v4.14.1
  };

  enableParallelBuilding = true;
  dontConfigure = true;
  dontFixup = true;

  hardeningDisable = [
    "zerocallusedregs"
  ];

  nativeBuildInputs = [
    autoconf
    automake
    clang
    cmake
    curl
    expat
    nlohmann_json
    perl
    pkg-config
    policycoreutils
    python311
    zlib
  ];

  buildInputs = [
    curl
    elfutils
    libbfd
    libbpf
    libcap
    libelf
    libtool
    llvm
    openssl
  ];

  makeFlags = [
    "-C src"
    "TARGET=agent"
    "INSTALLDIR=$out"
    "-j 8"
  ];

  patches = [
    ./01-makefile-patch.patch
    ./02-libbpf-bootstrap.patch
  ];

  unpackPhase = ''
    runHook preUnpack

    cp -rf --no-preserve=all "$src"/* .

    mkdir -p src/external
    ${lib.strings.concatMapStringsSep "\n" (
      dep: "tar -xzf ${dep} -C src/external"
    ) external_dependencies}

    mkdir -p src/external/libbpf-bootstrap/src
    cp --no-preserve=all -rf ${libbpf_bootstrap_deps.bootstrap}/* src/external/libbpf-bootstrap
    cp ${libbpf_bootstrap_deps.modern_bpf_c} src/external/libbpf-bootstrap/src/modern.bpf.c

    cp --no-preserve=all -rf ${wazuh-http-request}/* src/shared_modules/http-request/

    runHook postUnpack
  '';

  prePatch = ''
    substituteInPlace src/init/wazuh-server.sh \
      --replace-fail "cd ''${LOCAL}" ""

    substituteInPlace src/external/audit-userspace/autogen.sh \
      --replace-warn "cp INSTALL.tmp INSTALL" ""

    substituteInPlace src/external/openssl/config \
      --replace-warn "/usr/bin/env" "env"

    substituteInPlace src/init/inst-functions.sh \
      --replace-warn "WAZUH_GROUP='wazuh'" "WAZUH_GROUP='nixbld'" \
      --replace-warn "WAZUH_USER='wazuh'" "WAZUH_USER='nixbld'"

    substituteInPlace src/external/libbpf-bootstrap/CMakeLists.txt \
      --replace-fail "/usr/bin/clang" "${clang}/bin/clang"

    cat << EOF > "etc/preloaded-vars.conf"
    USER_LANGUAGE="en"
    USER_NO_STOP="y"
    USER_INSTALL_TYPE="agent"
    USER_DIR="$out"
    USER_DELETE_DIR="n"
    USER_ENABLE_ACTIVE_RESPONSE="y"
    USER_ENABLE_SYSCHECK="n"
    USER_ENABLE_ROOTCHECK="y"
    USER_AGENT_SERVER_IP=127.0.0.1
    USER_CA_STORE="n"
    EOF
  '';

  postPatch = ''
    # Comment out conflicting BPF skeleton function pointers that clash with system libbpf
    sed -i 's/^void (\*bpf_object__destroy_skeleton)/\/\/ &/' src/syscheckd/src/ebpf/include/bpf_helpers.h
    sed -i 's/^int (\*bpf_object__open_skeleton)/\/\/ &/' src/syscheckd/src/ebpf/include/bpf_helpers.h
    sed -i 's/^int (\*bpf_object__load_skeleton)/\/\/ &/' src/syscheckd/src/ebpf/include/bpf_helpers.h
    sed -i 's/^int (\*bpf_object__attach_skeleton)/\/\/ &/' src/syscheckd/src/ebpf/include/bpf_helpers.h
    sed -i 's/^void (\*bpf_object__detach_skeleton)/\/\/ &/' src/syscheckd/src/ebpf/include/bpf_helpers.h

    # Disable testtool build to avoid linking issues with snap support
    if [ -f src/data_provider/CMakeLists.txt ]; then
      sed -i 's/add_subdirectory(testtool)/# add_subdirectory(testtool) # Disabled for NixOS/' src/data_provider/CMakeLists.txt
    fi

    # Disable eBPF syscheck module to avoid bpftool build race condition
    # The bpftool ExternalProject doesn't complete before skeleton generation
    if [ -f src/syscheckd/CMakeLists.txt ]; then
      sed -i 's/add_subdirectory(src\/ebpf)/# add_subdirectory(src\/ebpf) # Disabled eBPF for NixOS/' src/syscheckd/CMakeLists.txt
    fi

    # Fix CMake CURL detection in http-request module
    if [ -f src/shared_modules/http-request/CMakeLists.txt ]; then
      # Add find_package for CURL before trying to use it
      sed -i '/add_library(urlrequest/a\
find_package(CURL REQUIRED)\
if(CURL_FOUND)\
  include_directories(''${CURL_INCLUDE_DIRS})\
endif()' src/shared_modules/http-request/CMakeLists.txt

      # Replace CURL::libcurl with ''${CURL_LIBRARIES}
      sed -i 's/CURL::libcurl/''${CURL_LIBRARIES}/g' src/shared_modules/http-request/CMakeLists.txt
    fi

    # Fix lambda signature mismatch in packageLinuxParserSnap.cpp
    # For NixOS, we don't need snap package support, so just stub it out
    if [ -f src/data_provider/src/packages/packageLinuxParserSnap.cpp ]; then
      # Replace with a minimal stub
      cat > src/data_provider/src/packages/packageLinuxParserSnap.cpp << 'EOF'
#include <functional>
#include <nlohmann/json.hpp>

// Stub implementation - snap packages not supported on NixOS
extern void getSnapInfo(std::function<void(nlohmann::json&)> callback)
{
    nlohmann::json empty = nlohmann::json::array();
    if (callback) {
        callback(empty);
    }
}
EOF
    fi

    # Also patch the header file to ensure the declaration matches
    if [ -f src/data_provider/src/packages/packageLinuxDataRetriever.h ]; then
      # Comment out or replace the snap function call to avoid linking issues
      sed -i 's/getSnapInfo(callback);/\/\/ getSnapInfo(callback); \/\/ Disabled for NixOS/' src/data_provider/src/packages/packageLinuxDataRetriever.h
    fi
  '';

  preBuild = ''
    # Set up CMake to find curl properly
    export CMAKE_PREFIX_PATH="${curl.dev}:$CMAKE_PREFIX_PATH"
    export PKG_CONFIG_PATH="${curl.dev}/lib/pkgconfig:$PKG_CONFIG_PATH"

    # Create ar wrapper to handle long command lines
    # The OpenSSL Makefile expects AR to be at /build/.build-tools/ar-wrapper.sh
    # We need to ensure it's available at both the actual build root and /build

    # Use NIX_BUILD_TOP which Nix sets to the build directory (usually /build)
    BUILD_ROOT="''${NIX_BUILD_TOP:-/build}"

    # Ensure we can create the wrapper in the expected location
    # If /build doesn't exist or isn't writable, use the actual build directory
    if [ ! -d "/build" ] || [ ! -w "/build" ]; then
        # If /build isn't available, use current directory as build root
        BUILD_ROOT="$(pwd)"
        if [ -d "src" ]; then
            # We're in the root of the source
            BUILD_ROOT="$(pwd)"
        elif [ -d "../src" ]; then
            # We're one level deep
            BUILD_ROOT="$(cd .. && pwd)"
        fi
    else
        # /build exists and is writable, ensure ar-wrapper is there too
        BUILD_ROOT="/build"
    fi

    # Create the .build-tools directory
    mkdir -p "$BUILD_ROOT/.build-tools"
    AR_WRAPPER="$BUILD_ROOT/.build-tools/ar-wrapper.sh"

    # If we're not using /build, also create a symlink at /build if possible
    if [ "$BUILD_ROOT" != "/build" ] && [ -w "/" ]; then
        # Try to create /build as a symlink to our actual build root
        if [ ! -e "/build" ]; then
            ln -sf "$BUILD_ROOT" /build 2>/dev/null || true
        fi
    fi

    # Also ensure the wrapper is available at the canonical /build location if different
    if [ "$BUILD_ROOT" != "/build" ] && [ -d "/build" ] && [ -w "/build" ]; then
        mkdir -p /build/.build-tools
    fi

    cat > "$AR_WRAPPER" << ARWRAPPER
        #!${stdenv.shell}
        # Wrapper for ar that handles long command lines by using file lists
        
        # Find ar binary - use explicit path from Nix
        REAL_AR="${stdenv.cc.bintools}/bin/ar"
        
        # Verify ar exists and is executable
        if [ ! -f "''$REAL_AR" ] || [ ! -x "''$REAL_AR" ]; then
            # Fallback: try to find ar in PATH
            REAL_AR=''$(command -v ar 2>/dev/null || true)
            if [ -z "''$REAL_AR" ] || [ ! -x "''$REAL_AR" ]; then
                echo "Error: ar binary not found" >&2
                exit 1
            fi
        fi

        # Initialize variables
        OBJ_COUNT=0
        OBJ_FILES=""
        ARCHIVE=""
        ARGS=""

        # Parse arguments
        for arg in "''$@"; do
            case "''$arg" in
                *.o)
                    if [ -z "''$OBJ_FILES" ]; then
                        OBJ_FILES="''$arg"
                    else
                        OBJ_FILES="''$OBJ_FILES
    ''$arg"
                    fi
                    # Increment count safely
                    OBJ_COUNT=''$((OBJ_COUNT + 1))
                    ;;
                *.a)
                    ARCHIVE="''$arg"
                    ;;
                *)
                    if [ -z "''$ARGS" ]; then
                        ARGS="''$arg"
                    else
                        ARGS="''$ARGS ''$arg"
                    fi
                    ;;
            esac
        done

        # Ensure OBJ_COUNT is numeric (default to 0 if empty or unset)
        if [ -z "''$OBJ_COUNT" ]; then
            OBJ_COUNT=0
        fi

        # Always use file list if we have object files (safer for long command lines)
        if [ "''$OBJ_COUNT" -gt 0 ] && [ -n "''$ARCHIVE" ]; then
            TMPFILE=''$(mktemp)
            trap "rm -f ''$TMPFILE" EXIT
            echo "''$OBJ_FILES" > "''$TMPFILE"
            if [ -n "''$ARGS" ]; then
                exec "''$REAL_AR" ''$ARGS "''$ARCHIVE" "@''$TMPFILE"
            else
                exec "''$REAL_AR" "''$ARCHIVE" "@''$TMPFILE"
            fi
        else
            exec "''$REAL_AR" "''$@"
        fi
        ARWRAPPER
    chmod +x "$AR_WRAPPER"

    # If we created the wrapper at a non-standard location, also copy it to /build
    if [ "$BUILD_ROOT" != "/build" ] && [ -d "/build" ] && [ -w "/build/.build-tools" ]; then
        cp "$AR_WRAPPER" /build/.build-tools/ar-wrapper.sh
        chmod +x /build/.build-tools/ar-wrapper.sh
        echo "Copied ar-wrapper to /build/.build-tools/" >&2
    fi

    # Verify wrapper exists
    if [ ! -f "$AR_WRAPPER" ] || [ ! -x "$AR_WRAPPER" ]; then
        echo "Error: Failed to create ar wrapper at $AR_WRAPPER" >&2
        echo "Build root: $BUILD_ROOT" >&2
        exit 1
    fi

    # Set AR to use the wrapper - OpenSSL might expect it at /build
    if [ -x "/build/.build-tools/ar-wrapper.sh" ]; then
        export AR="/build/.build-tools/ar-wrapper.sh"
        export PATH="/build/.build-tools:$BUILD_ROOT/.build-tools:''$PATH"
    else
        export AR="$AR_WRAPPER"
        export PATH="$BUILD_ROOT/.build-tools:''$PATH"
    fi

    # Debug output
    echo "AR wrapper created at: $AR_WRAPPER" >&2
    echo "AR variable set to: $AR" >&2
    echo "Build root: $BUILD_ROOT" >&2
    echo "Testing AR wrapper..." >&2
    "$AR" --version >&2 || true

    make -C src TARGET=agent settings
    # Build OpenSSL deps sequentially to avoid command line length issues with ar
    make -C src TARGET=agent INSTALLDIR=$out deps -j 1
  '';

  buildPhase = ''
    # Ensure AR wrapper is available for the main build
    # Use the same logic as preBuild to find the wrapper
    BUILD_ROOT="''${NIX_BUILD_TOP:-/build}"

    # Check if wrapper exists at /build first (OpenSSL expects it there)
    if [ -x "/build/.build-tools/ar-wrapper.sh" ]; then
        export AR="/build/.build-tools/ar-wrapper.sh"
        export PATH="/build/.build-tools:''$PATH"
    elif [ -x "$BUILD_ROOT/.build-tools/ar-wrapper.sh" ]; then
        export AR="$BUILD_ROOT/.build-tools/ar-wrapper.sh"
        export PATH="$BUILD_ROOT/.build-tools:''$PATH"
    else
        # Try to find it in current directory structure
        if [ -x ".build-tools/ar-wrapper.sh" ]; then
            export AR="$(pwd)/.build-tools/ar-wrapper.sh"
            export PATH="$(pwd)/.build-tools:''$PATH"
        else
            echo "Warning: ar-wrapper.sh not found, build may fail" >&2
        fi
    fi

    echo "buildPhase: AR is set to: $AR" >&2

    # Run the main build
    make ''$makeFlags ''$makeFlagsArray
  '';

  installPhase = ''
    mkdir -p $out/{bin,etc/shared,queue,var,wodles,logs,lib,tmp,agentless,active-response}

    substituteInPlace install.sh \
      --replace-warn "Xroot" "Xnixbld"
    chmod u+x install.sh

    INSTALLDIR=$out USER_DIR=$out ./install.sh binary-install

    substituteInPlace $out/bin/wazuh-control \
      --replace-fail "cd ''${LOCAL}" "#"

    chmod u+x $out/bin/* $out/active-response/bin/*

    ${removeReferencesTo}/bin/remove-references-to \
      -t ${libgcc.out} \
      $out/lib/*

    ${patchelf}/bin/patchelf --add-rpath ${systemd}/lib $out/bin/wazuh-logcollector
    rm -rf $out/src
  '';

  meta = {
    description = "Wazuh agent for NixOS";
    homepage = "https://wazuh.com";
  };
}
