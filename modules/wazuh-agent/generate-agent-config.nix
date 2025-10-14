# TODO make this use a proper xml serialization function and manipulate values as nix attributes.
{ cfg, ... }:
{
  ossecConfig =
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

        # Add extraConfig
        "</ossec_config>" = "</ossec_config>\n${cfg.extraConfig}";
      };
    in
    builtins.replaceStrings (builtins.attrNames substitutes) (builtins.attrValues substitutes)
      upstreamConfig;

  internalOptions =
    let
      upstreamInternalOptions = builtins.readFile (
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
      upstreamInternalOptions;
}
