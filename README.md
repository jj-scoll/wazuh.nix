# wazuh.nix

A Nix flake that packages the [Wazuh](https://wazuh.com) agent and exposes it as
a NixOS module, so agent installation, configuration, and enrollment are
declarative and reproducible instead of shell-script driven.

Currently tracks **Wazuh 5.0** (`wazuh-agent` 5.0.0-beta2).

> Maintained fork of [`V3ntus/wazuh.nix`](https://github.com/V3ntus/wazuh.nix),
> which is now archived. This fork carries the work forward — it is 55+ commits
> ahead of upstream and updated for the Wazuh 5.0 line (including the eBPF-based
> file-integrity monitoring path and the v5 installer changes).

## What's here

- **`packages.wazuh-agent`** — the Wazuh agent built from source, with the eBPF
  FIM (`syscheckd`) components and the external-dependency prefetch pinned for
  reproducible builds.
- **`overlays.wazuh`** — overlay that adds `wazuh-agent` to your package set.
- **`nixosModules.wazuh-agent`** — a NixOS module that configures the agent,
  writes `ossec.conf`/`internal_options.conf`, and handles first-boot
  enrollment against a manager.

## Usage

Add the flake as an input:

```nix
{
  inputs.wazuh.url = "github:jj-scoll/wazuh.nix";
}
```

Enable the agent on a host:

```nix
{
  imports = [ wazuh.nixosModules.wazuh-agent ];

  services.wazuh-agent = {
    enable = true;
    manager = {
      host = "wazuh-manager.example.com";
      port = 1514;
    };
    # Optional: separate enrollment endpoint (defaults to the manager above)
    registration = {
      host = "wazuh-manager.example.com";
      port = 1515;
    };
    # Extra <ossec_config> XML appended verbatim
    extraConfig = "";
  };
}
```

On first boot the module runs `agent-auth` against the registration endpoint and
records success with a `.agent-registered` sentinel, so enrollment happens once
and is idempotent across rebuilds.

### Module options

| Option | Purpose |
| --- | --- |
| `enable` | Turn the agent on. |
| `manager.host` / `manager.port` | Manager the agent reports to (default port 1514). |
| `registration.host` / `registration.port` | Enrollment endpoint (defaults to the manager; default port 1515). |
| `agentAuthPassword` | Optional shared password for `agent-auth` enrollment. |
| `config` | Full `ossec.conf` override. |
| `extraConfig` | Extra `<ossec_config>` XML appended to the generated config. |
| `path` | Install prefix for agent state. |

## Building

```sh
nix build .#wazuh-agent
```

## Maintaining / bumping Wazuh

Dependency prefetch and version bumps are scripted under
`pkgs/dependencies/` (`upgrade-wazuh.py`, `prefetch-external-dependencies.sh`).
Run those to refresh the pinned external dependencies when moving to a new
Wazuh tag.

## Scope

Agent-only today. Server/manager and indexer modules are not packaged yet;
they're the intended direction for the fork.

## License

Inherits upstream licensing; the Wazuh agent itself is GPLv2.
