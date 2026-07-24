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
#       `fileSystems` entries from here; OR any ANCESTOR of that path is itself a bind
#       mount — a bind mount's target is just an ordinary directory tree on whatever
#       backs its source, so anything nested under it is persisted right along with it
#       (the same reason `/var/lib/docker` needs no per-container `fileSystems` entry);
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

  # Every ancestor directory of `path`, from its immediate parent up to "/" — NOT
  # including `path` itself (the exact-match case in `isPersisted` below covers that).
  # Walked by path COMPONENT, not by raw string prefix: a naive `lib.hasPrefix "/var/lib/acme"`
  # would also match an unrelated "/var/lib/acme-other" sibling, which shares no filesystem
  # with it at all. e.g. for "/var/lib/acme/.lego/accounts/xyz" this returns
  #   [ "/var/lib/acme/.lego/accounts" "/var/lib/acme/.lego" "/var/lib/acme" "/var/lib" "/var" "/" ]
  ancestorsOf =
    path:
    let
      parts = lib.filter (p: p != "") (lib.splitString "/" path);
      depth = lib.length parts;
    in
    map
      (n: "/" + lib.concatStringsSep "/" (lib.take n parts))
      (lib.reverseList (lib.range 0 (depth - 1)));

  # A `fileSystems` entry counts as a bind mount the same way NixOS itself recognizes one:
  # `fsType = "none"` with `"bind"` among its mount options (`solidBind`-style helpers, and
  # the manual binds in examples/host.nix, both produce exactly this shape).
  isBindMountAt = path:
    let fs = config.fileSystems.${path} or null;
    in fs != null && (fs.fsType or null) == "none" && lib.elem "bind" (fs.options or [ ]);

  # Persisted if EITHER the exact /var/lib/<dir> path has ANY fileSystems entry (unchanged
  # from before — the tier that mounted it doesn't matter), OR one of its ancestors is a bind
  # mount: everything nested under a bind-mounted directory rides on the same backing storage
  # as the mount itself, generically, at any nesting depth, for any parent so bound — this is
  # exactly how bind mounts work, not a corbet-server/acme special case.
  isPersisted = dir:
    let path = "/var/lib/${dir}";
    in lib.hasAttr path config.fileSystems || lib.any isBindMountAt (ancestorsOf path);
  isAcknowledgedEphemeral = serviceName: lib.elem serviceName cfg.persist.explicitlyEphemeral;

  unaddressed = lib.filter
    (e: !(isPersisted e.dir) && !(isAcknowledgedEphemeral e.serviceName))
    stateDirEntries;

  assertionFor = e: {
    assertion = false;
    message = ''
      nixnas: `${e.serviceName}.service` declares StateDirectory "${e.dir}" (wants durable
      state at /var/lib/${e.dir}), but nothing accounts for it: no `fileSystems."/var/lib/${e.dir}"`
      entry exists (from nixnas.persist.overlayClients or your own persistence), no ANCESTOR
      of /var/lib/${e.dir} is a bind mount covering it either, and "${e.serviceName}" is not
      in `nixnas.persist.explicitlyEphemeral`.

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
