# nixnas architecture

Nixnas is the appliance payload and storage-runtime layer. Nixboot owns the boot chain;
nixrescue owns recovery; nixdeploy owns authenticated delivery and activation outcomes; the
consumer composition owns machines, media layout, keys, and policy.

| Owner | Responsibility |
|---|---|
| nixnas | Appliance configuration, USB-store geometry, impermanent runtime, post-boot data unlock |
| nixboot | Loader, UKIs, Secure Boot integration, bounded generations, TPM-gated initrd SSH identity |
| nixrescue | One fleet-generic recovery system, exact release bundle, slot resolver and reconciler |
| nixdeploy | Signed manifests, delivery, activation/rollback/health outcomes, exact boot-role hook |
| consumer | Device classes, disk identifiers, Secure Boot custody, rescue-medium layout and schedules |

The old per-host nixnas rescue, blank-root installer, TPM disk-unlock policy, and plaintext or
ephemeral initrd-SSH fallback have been removed.

## Boot and unlock contract

| Property | Contract |
|---|---|
| Firmware | UEFI Secure Boot enforcing the operator's PK/KEK/db; Setup Mode and enrollment are supervised |
| Executable boot path | Signed UKIs only; unsigned or foreign binaries must not run |
| Disk unlock | A human passphrase is mandatory on every boot; no TPM LUKS token or auto-unlock |
| Local class | Passphrase through the attached console |
| Server class | Passphrase through local/IPMI console or TPM-gated initrd SSH |
| TPM | Protects only a per-device SSH host identity, sealed to PCR 7 |
| TPM failure | Initrd SSH remains down; local/IPMI passphrase entry remains available |
| First boot | Local/IPMI only; a successful boot creates and seals the SSH credential for the next boot |
| Credential failure | No ephemeral or plaintext host key and no sshd restart loop |

The passphrase unlocks LUKS. If encrypted configuration material must be public, an age private
identity stored inside that LUKS volume decrypts the SOPS archive after unlock. This avoids using
the disk passphrase directly as a second ciphertext key and avoids publishing an offline password
oracle.

## Nixnas storage modes

| Mode | Root and `/nix` | Failure behavior |
|---|---|---|
| `usb` | tmpfs root; persistent LUKS/f2fs `/nix` on the appliance medium | Self-contained appliance; passphrase required |
| `hot` | ordinary persistent root and `/nix` on operator-managed encrypted storage | Main cannot boot if the hot store is absent; separate nixrescue is the recovery path |

All data members are passphrase-only. `nixnas-unlock` opens the declared members serially after
boot, imports declared ZFS pools, and raises `nixnas-storage.target`. Nixnas never creates,
formats, destroys, or TPM-enrolls operator data pools.

For `usb` mode, the tmpfs root keeps logs, temporary files, coredumps, and incidental writes away
from flash. `/nix` remains a real read-write store so Nix generations share paths and updates can
be staged. Machine identity and explicitly declared overlay-client state persist below
`/nix/persist`.

## Fleet rescue medium

The standard recovery medium is composed outside nixnas:

| Partition | Nominal size | Contents |
|---|---:|---|
| ESP | 512 MiB | Bootloader, signed rescue UKI history, encrypted per-device SSH credential |
| `nixrescue-a` | 1 GiB | Shared rescue squashfs slot |
| `nixrescue-b` | 1 GiB | Shared rescue squashfs slot |
| `nixrescue-c` | 1 GiB | Shared rescue squashfs slot |
| vault | remaining, target about 4 GiB | Encrypted recovery/operator material |

EliteBook, corbet-server, and future x86_64 machines consume the same exact nixrescue squashfs and
unsigned UKI. The image contains broad hardware support, not a hostname, machine identity, or
host-specific payload. Each successfully unlocked host signs that exact UKI locally with the
authorized db signer and reconciles its own medium.

The resolver accepts only a slot containing the exact `/nix/store/.../init` embedded in the UKI
command line. A pointer is preference, not authority. The reconciler protects current and previous
slots, writes an inactive slot, verifies content by readback and mount, signs and verifies the UKI,
then rotates ESP history with the current entry replaced last.

## Secure Boot key custody

| Material | Normal location/use |
|---|---|
| Public certificates, fingerprints, ciphertext | May be committed to a public GitHub repository |
| SOPS archive | Full PK/KEK/db hierarchy, encrypted only to operator age recipients |
| Age private identity | Inside passphrase-protected LUKS; never in the public repository |
| db private key | Exposed only under `/run` after unlock, for local UKI signing |
| PK and KEK private keys | Enrollment/recovery ceremony only; not exposed during normal boot |
| CI | May build unsigned artifacts and validate ciphertext; never receives signing keys |

Successful boots reconcile boot artifacts, but never repartition disks, change firmware variables,
enroll/reset keys, or weaken Secure Boot automatically. Firmware state is audited for drift and
physical enrollment remains an operator-supervised ceremony.

## Honest security boundary

Secure Boot can prevent an unsigned replacement boot chain from presenting a fake passphrase
prompt only while the firmware actually enforces the enrolled keys. A firmware administrator
password is still needed to stop a visitor from disabling Secure Boot or replacing the keys.
Malicious or compromised firmware, hardware implants, and firmware that silently replaces trust
state are outside what a passphrase and owner keys can completely solve.

Secure Boot also does not inherently revoke an older still-signed UKI. Deployment therefore keeps
bounded current/previous artifacts and verifies exact releases, but strong signed-version
anti-rollback would require another monotonic trust mechanism. TPM anti-rollback is deliberately
not used here because TPM's only authorized role is SSH-channel identity.

## Updates and recovery

Nixdeploy authenticates an exact manifest. After a healthy primary activation, and also when the
primary is already current, it invokes the consumer's boot-role reconciler with that exact verified
manifest artifact. A successful boot repeats reconciliation to repair safe drift.

Firmware enrollment, first physical boot, TPM credential creation, media provisioning, and physical
main/rescue boot tests remain supervised gates. No NixOS activation should guess a target disk or
perform those ceremonies.
