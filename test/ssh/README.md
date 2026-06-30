# Demo SSH keypair — THROWAWAY, test VM only

Two throwaway ed25519 keys, committed on purpose — exactly like the demo LUKS passphrase
`nixnas-demo`. The demo host is a zero-secrets, public reference build.

- `demo_key` / `.pub` — the **client** key that logs into the demo image (initrd
  remote-unlock + the running sshd); its public half is in `nixnas.admin.authorizedKeys`.
- `demo_initrd_host_ed25519_key` / `.pub` — the initrd sshd's **host** key (the box's
  unlock identity); `boot.remoteUnlock.hostKeyPath` points at it.

**Never use this key on real hardware.** A real host lists the operator's own public keys
in `nixnas.admin.authorizedKeys` (private overlay) and its private key never enters this
repo.
