# Hot mode

`nixnas.store.location = "hot"` puts the main system's `/nix` on an operator-managed encrypted
device or pool instead of on the USB appliance store.

| Property | Contract |
|---|---|
| Main boot | Initrd blocks until the operator supplies the passphrase locally/IPMI or through strict TPM-gated initrd SSH |
| TPM | May protect the SSH host identity; it is not a data-unlock path for the hot store |
| Dead hot pool | The main cannot boot |
| Recovery | A separate, fleet-generic `nixrescue` boot role supplied by the consumer |
| Delivery | `nixdeploy` authenticates the exact rescue release and invokes the consumer's reconciler |
| Secure Boot | The unlocked host signs locally with its authorized db key; enrollment remains supervised |

Nixnas no longer has `nixnas.rescue.*`, `nixnas-rescue-maintain`, a per-host rescue configuration,
or `nixnas-install-hot`. The old mechanism coupled a host-specific NixOS store, TPM data unlock,
rescue construction, slot mutation, UKI signing, and scheduling inside the appliance. Those are
separate responsibilities now:

- `nixrescue` owns one portable recovery system and its runtime contract;
- `nixboot` owns UKI construction, Secure Boot integration, and the TPM-gated SSH credential;
- `nixdeploy` owns authenticated delivery and reconciliation;
- the private composition owns device class, media layout, keys, and policy.

The physical provisioning ceremony remains deliberately outside activation: resolve an exact
device, back it up, create the declared ESP/slots/vault shape, enroll the operator Secure Boot
hierarchy, then perform supervised main and rescue boots. No NixOS activation should partition,
format, enroll firmware keys, or invent a rescue identity.
