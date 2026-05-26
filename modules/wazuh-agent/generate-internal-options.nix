# TODO make this use a proper xml serialization function and manipulate values as nix attributes.
{ cfg, ... }:
let
  upstreamConfig = builtins.readFile (
    builtins.fetchurl {
      url = "https://raw.githubusercontent.com/wazuh/wazuh/refs/tags/v${cfg.package.version}/etc/internal_options.conf"; # nix-prefetch-url https://raw.githubusercontent.com/wazuh/wazuh/refs/tags/v5.0.0-beta2/etc/internal_options.conf --type sha256 | xargs nix hash convert --from nix32 --to sri --hash-algo sha256
      sha256 = "sha256-Bk/S8LXDle41d9ettcF5lynjDVsXKN/+PF5uMhi1z3A=";
    }
  );

  substitutes = {
    # Increase rlimit_nofile for wazuh_modules from default 8192 to 524288
    "wazuh_modules.rlimit_nofile=8192" = "wazuh_modules.rlimit_nofile=524288";
  };
in
builtins.replaceStrings (builtins.attrNames substitutes) (builtins.attrValues substitutes)
  upstreamConfig
