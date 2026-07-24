# nixnas — build-time enforcement: no silent state loss.
#
# systemd's `StateDirectory=` is already the signal a service uses to say "I keep
# durable state at /var/lib/<name>" — no per-app knowledge needed here, just read it
# back off every declared service. For each one, require an EXPLICIT answer to "does
# this survive a reboot?":
#
#   (a) a `fileSystems."/var/lib/<name>"` entry already exists — nixnas doesn't care
#       WHICH tier put it there: its own Tier-1 `persist.overlayClients` bind mounts
#       and the operator's own Tier-2/Tier-3 persistence are both just ordinary
#       `fileSystems` entries from here;
#   (b) OR the service is listed in `nixnas.persist.explicitlyEphemeral` — a
#       deliberate, first-class "losing this every reboot is fine", never a default.
#
# Neither present ⇒ a NixOS assertion failure naming the exact service and directory.
# nixos-rebuild switch/build simply refuses to produce a system until the operator
# makes the choice — no alerting, no runtime scan, just a hard eval-time gate.
{ config, lib, ... }:
let
  cfg = config.nixnas;

  # A service's StateDirectory can be a single "name", a "name1 name2" space-separated
  # string (systemd's own multi-value shorthand), or a Nix list of either — normalize
  # every shape down to a flat list of bare directory names (each relative to /var/lib).
  stateDirNames =
    raw:
    let
      asList = if raw == null then [ ] else lib.toList raw;
      words = lib.concatMap (lib.splitString " ") asList;
    in
    lib.filter (n: n != "") words;

  servicesWithState = lib.filterAttrs
    (_name: svc: stateDirNames (svc.serviceConfig.StateDirectory or null) != [ ])
    config.systemd.services;

  # Flatten to one (serviceName, dir) pair per declared directory — a single service can
  # declare more than one StateDirectory, and persisting one says nothing about the rest.
  stateDirEntries = lib.flatten (
    lib.mapAttrsToList
      (serviceName: svc: map (dir: { inherit serviceName dir; }) (stateDirNames (svc.serviceConfig.StateDirectory or null)))
      servicesWithState
  );

  isPersisted = dir: lib.hasAttr "/var/lib/${dir}" config.fileSystems;
  isAcknowledgedEphemeral = serviceName: lib.elem serviceName cfg.persist.explicitlyEphemeral;

  unaddressed = lib.filter
    (e: !(isPersisted e.dir) && !(isAcknowledgedEphemeral e.serviceName))
    stateDirEntries;

  assertionFor = e: {
    assertion = false;
    message = ''
      nixnas: `${e.serviceName}.service` declares StateDirectory "${e.dir}" (wants durable
      state at /var/lib/${e.dir}), but nothing accounts for it: no `fileSystems."/var/lib/${e.dir}"`
      entry exists (from nixnas.persist.overlayClients or your own persistence), and
      "${e.serviceName}" is not in `nixnas.persist.explicitlyEphemeral`.

      Make an explicit choice — this is a deliberate gate, not a bug:
        * state must survive a reboot → persist /var/lib/${e.dir} (add "${e.serviceName}" to
          nixnas.persist.overlayClients if it's a Tier-1 mesh/overlay identity client, or add
          your own fileSystems bind mount for it);
        * losing it every reboot is fine (cache/scratch/self-regenerating) → add
          "${e.serviceName}" to nixnas.persist.explicitlyEphemeral.
    '';
  };
in
{
  config = lib.mkIf cfg.enable {
    assertions = map assertionFor unaddressed;
  };
}
