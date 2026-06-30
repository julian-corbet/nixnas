#!/usr/bin/env bash
# test/remote-unlock-test.sh — prove the HEADLESS remote store unlock (initrd-SSH).
#
# Boots the image with NO serial passphrase (so it blocks in the initrd waiting for the
# store secret), forwards host :2222 -> guest :22, then over SSH (the committed demo client
# key) hands the passphrase to systemd's password agent IN THE INITRD. Success = the boot
# proceeds past the locked store to `login:` — i.e. the box was unlocked entirely over the
# network, with no console. This is the mandatory headless-unlock path (ARCHITECTURE §6).
#
# Usage: test/remote-unlock-test.sh <image.raw> [--pass nixnas-demo] [--timeout 175]
set -uo pipefail

IMG="${1:?usage: remote-unlock-test.sh <image.raw>}"; shift || true
PASS="nixnas-demo"; TMO=175; PORT=2222
while [ $# -gt 0 ]; do case "$1" in
  --pass) PASS="$2"; shift ;;
  --timeout) TMO="$2"; shift ;;
  --port) PORT="$2"; shift ;;
  *) echo "unknown arg: $1" >&2; exit 2 ;;
esac; shift; done

HERE="$(cd "$(dirname "$0")" && pwd)"
KEY="$HERE/ssh/demo_key"
LOG="$(mktemp /tmp/nixnas-ru.XXXXXX.log)"
SSH=(ssh -i "$KEY" -p "$PORT"
     -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
     -o GlobalKnownHostsFile=/dev/null -o LogLevel=ERROR
     -o ConnectTimeout=4 root@127.0.0.1)

echo ">> booting headless (serial -> $LOG), unlocking over SSH :$PORT"
# Background the VM; no --passphrase, so it waits for the secret. stdin from /dev/null.
timeout "$TMO" "$HERE/boot-vm.sh" "$IMG" --ssh "$PORT" < /dev/null > "$LOG" 2>&1 &
VM=$!
cleanup(){ kill "$VM" 2>/dev/null; pkill -P "$VM" 2>/dev/null; }
trap cleanup EXIT

# 1) wait for the initrd sshd to accept the demo key
echo ">> waiting for initrd-SSH …"
up=0
for _ in $(seq 1 60); do
  kill -0 "$VM" 2>/dev/null || { echo "!! VM exited early"; break; }
  if "${SSH[@]}" -o BatchMode=yes true 2>/dev/null; then up=1; break; fi
  sleep 2
done
if [ "$up" != 1 ]; then
  echo "!! initrd-SSH never came up. Tail of serial:"; tail -30 "$LOG"; exit 1
fi
echo ">> initrd-SSH up — authenticated with the demo key (NIC+sshd+hostkey+authzkeys OK)"
echo ">> initrd context:"; "${SSH[@]}" 'uname -r; echo "[ip]"; ip -o -4 addr 2>/dev/null | sed "s/^/  /"' 2>/dev/null || true

# 2) hand the passphrase to the password agent (a pty via -tt feeds the agent)
echo ">> handing the store passphrase to the initrd password agent …"
printf '%s\n' "$PASS" | "${SSH[@]}" -tt 'systemd-tty-ask-password-agent --query' 2>/dev/null || true

# 3) confirm the boot proceeded to a login prompt (store unlocked over the network)
echo ">> waiting for the unlocked system to reach login …"
ok=0
for _ in $(seq 1 40); do
  if grep -q 'demo login:' "$LOG"; then ok=1; break; fi
  kill -0 "$VM" 2>/dev/null || break
  sleep 2
done
echo "================ RESULT ================"
if [ "$ok" = 1 ]; then
  echo "PASS — store unlocked over SSH in the initrd; system reached login headless."
else
  echo "FAIL — no login prompt; the unlock hand-off did not complete. Serial tail:"
  tail -40 "$LOG"
fi
echo "(serial log: $LOG)"
[ "$ok" = 1 ]
