# TODO make this use a proper xml serialization function and manipulate values as nix attributes.
{ cfg, ... }:
let
  upstreamConfig = builtins.readFile (
    builtins.fetchurl {
      url = "https://raw.githubusercontent.com/wazuh/wazuh/refs/tags/v${cfg.package.version}/etc/internal_options.conf";
      sha256 = "0sp22rxyjnqwwb11j7yjb9p1knbi8hgnmvv4677s957qn8bl4hrg";
    }
  );

  substitutes = {
    # Increase rlimit_nofile for wazuh_modules from default 8192 to 524288
    "wazuh_modules.rlimit_nofile=8192" = "wazuh_modules.rlimit_nofile=524288";
  };
in
builtins.replaceStrings (builtins.attrNames substitutes) (builtins.attrValues substitutes)
  upstreamConfig
