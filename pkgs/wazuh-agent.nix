{
  autoconf,
  automake,
  clang,
  cmake,
  curl,
  elfutils,
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
  openssl,
  patchelf,
  perl,
  pkg-config,
  policycoreutils,
  python312,
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
    perl
    pkg-config
    policycoreutils
    python312
    zlib
  ];

  buildInputs = [
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
  '';

  preBuild = ''
    make -C src TARGET=agent settings
    # Build OpenSSL deps sequentially to avoid command line length issues with ar
    make -C src TARGET=agent INSTALLDIR=$out deps -j 1
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
