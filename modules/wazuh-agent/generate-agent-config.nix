# TODO make this use a proper xml serialization function and manipulate values as nix attributes.
{ cfg, ... }:
let
  upstreamConfig = builtins.readFile (
    builtins.fetchurl {
      url = "https://raw.githubusercontent.com/wazuh/wazuh/refs/tags/v${cfg.package.version}/etc/ossec-agent.conf";
      sha256 = "sha256-a1+VatIAsfC+0SQhY1cFdNfEt+BNdnRUC40pK6o4kyI=";
    }
  );

  substitutes = {
    "<address>IP</address>" =
      "<address>${cfg.manager.host}</address><port>${builtins.toString cfg.manager.port}</port>";
    # Replace syslog with journald
    # TODO: could we just add the journald log collector to the extraConfig section?
    "<log_format>syslog</log_format>" = "<log_format>journald</log_format>";
    "<location>/var/log/syslog</location>" = "<location>journald</location>";

    # Add wazuh_modules section for wazuh-modulesd and extraConfig
    "</ossec_config>" =
      "  <wazuh_modules>\n    <rlimit_nofile>524288</rlimit_nofile>\n  </wazuh_modules>\n</ossec_config>\n${cfg.extraConfig}";
  };
in
builtins.replaceStrings (builtins.attrNames substitutes) (builtins.attrValues substitutes)
  upstreamConfig
