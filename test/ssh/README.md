# Demo SSH keypair — THROWAWAY, test VM only

Two throwaway ed25519 keys, committed on purpose — exactly like the demo LUKS passphrase
`nixnas-demo`. The demo host is a zero-secrets, public reference build.

- `demo_key` / `.pub` — the **client** key that logs into the demo image (initrd
  remote-unlock + the running sshd); its public half is in `nixnas.admin.authorizedKeys`.
- The initrd sshd **host** key is deliberately absent from this repository. It is generated
  after a successful boot and stored only as a TPM-gated encrypted credential on the ESP.

**Never use this key on real hardware.** A real host lists the operator's own public keys
in `nixnas.admin.authorizedKeys` (private overlay) and its private key never enters this
repo.
