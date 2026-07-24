# nixnas — matrix variant: a StateDirectory nested SEVERAL levels under a bind-mounted
# ancestor, not under its own exact fileSystems entry.
#
# Regression guard for a real incident (2026-07-24): a Tier-2 bind mount at
# fileSystems."/var/lib/acme" physically covers everything nested under it — that's how
# bind mounts work — but persist-enforce.nix's isPersisted used to do an EXACT string
# match against config.fileSystems keys only. Three real services declared StateDirectory
# as nested sub-paths under acme/ (e.g. "acme/.lego/accounts/<hash>", four levels deep),
# so "/var/lib/acme/.lego/accounts/<hash>" != "/var/lib/acme" as a string and the build-time
# gate fired an assertion failure against state that was, in fact, already persisted.
#
# `demo-persist-nested` below is a synthetic StateDirectory-bearing service with no
# relationship to any real workload — the point is purely the PATH SHAPE: the bind mount
# sits at /var/lib/matrix-bind, the declared StateDirectory is two path components deeper
# ("matrix-bind/nested/deeper"), so only ANCESTOR-walking (not a same-level or one-hop
# check) resolves it. It is deliberately NOT in persist.explicitlyEphemeral: if
# persist-enforce.nix ever regresses back to exact-match-only, this variant's eval fails
# with exactly the assertion this incident hit, the same way the real one did.
{ ... }:
{
  fileSystems."/var/lib/matrix-bind" = {
    device = "/matrix-bind-src"; # placeholder — eval-only variant, never boots
    fsType = "none";
    options = [ "bind" ];
  };

  systemd.services.demo-persist-nested = {
    description = "Regression probe: StateDirectory nested under a bind-mounted ancestor";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "/bin/true"; # never actually runs — eval-only variant, no build/boot
      # Two path components below the /var/lib/matrix-bind bind mount above — never an
      # exact fileSystems key of its own.
      StateDirectory = "matrix-bind/nested/deeper";
    };
  };
}
