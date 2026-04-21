# TODO make this use a proper xml serialization function and manipulate values as nix attributes.
{ cfg, ... }:
let
  upstreamConfig = builtins.readFile (
    builtins.fetchurl {
      url = "https://raw.githubusercontent.com/wazuh/wazuh/refs/tags/v${cfg.package.version}/etc/ossec-agent.conf"; # nix-prefetch-url https://raw.githubusercontent.com/wazuh/wazuh/refs/tags/v4.14.1/etc/ossec-agent.conf --type sha256 | xargs nix hash convert --from nix32 --to sri --hash-algo sha256
      sha256 = "sha256-a1+VatIAsfC+0SQhY1cFdNfEt+BNdnRUC40pK6o4kyI=";
    }
  );

  # Pass 1: Replace manager address and NixOS-incompatible log file paths.
  # On NixOS, /var/log/syslog, /var/log/messages, /var/log/auth.log don't exist —
  # everything goes through journald. But active-responses.log is a real file
  # that wazuh writes itself, so we keep it as-is with syslog format.
  #
  # Strategy: replace the active-responses block with a placeholder FIRST,
  # then do the bulk syslog→journald swap, then restore active-responses.
  pass1Substitutes = {
    "<address>IP</address>" =
      "<address>${cfg.manager.host}</address><port>${builtins.toString cfg.manager.port}</port>";
    "</ossec_config>" = "</ossec_config>\n${cfg.extraConfig}";

    # Protect active-responses.log from the journald conversion
    "<location>/var/ossec/logs/active-responses.log</location>" =
      "<location>__ACTIVE_RESPONSES_PLACEHOLDER__</location>";

    # Replace file-based log locations with journald
    "<log_format>syslog</log_format>" = "<log_format>journald</log_format>";
    "<location>/var/log/syslog</location>" = "<location>journald</location>";
    "<location>/var/log/messages</location>" = "<location>journald</location>";
    "<location>/var/log/auth.log</location>" = "<location>journald</location>";
  };

  afterPass1 = builtins.replaceStrings
    (builtins.attrNames pass1Substitutes)
    (builtins.attrValues pass1Substitutes)
    upstreamConfig;

  # Pass 2: Restore active-responses.log with correct syslog format
  pass2Substitutes = {
    "<log_format>journald</log_format>\n    <location>__ACTIVE_RESPONSES_PLACEHOLDER__</location>" =
      "<log_format>syslog</log_format>\n    <location>/var/ossec/logs/active-responses.log</location>";
    # Catch any remaining placeholder (different whitespace)
    "<location>__ACTIVE_RESPONSES_PLACEHOLDER__</location>" =
      "<location>/var/ossec/logs/active-responses.log</location>";
  };
in
builtins.replaceStrings
  (builtins.attrNames pass2Substitutes)
  (builtins.attrValues pass2Substitutes)
  afterPass1
