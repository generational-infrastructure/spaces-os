#!/usr/bin/env bash
# Orchestrates the Proton-Bridge cert proof against integration-proton's OWN
# generated configs. Invoked by ./default.nix with $STUB -> ./stub.py, $GEN ->
# ./gen.py, integration_proton importable via $PYTHONPATH, and
# himalaya/msmtp/openssl/python3 on PATH. Runs in a writable cwd ($TMPDIR in the
# nix sandbox, which gives each derivation its own loopback, so the fixed ports
# never collide).
set -uo pipefail
D="$PWD"
rc=0
note() { echo "=== $* ==="; }
pass() { echo "PASS: $*"; }
fail() {
  echo "FAIL: $*"
  rc=1
}

# ---------- Bridge serving cert at the module's own cert path ----------
# integration-proton derives the cert path from $SPACES_PROTON_BRIDGE_STATE
# (<state>/config/protonmail/bridge-v3/cert.pem). Mint the Bridge-style cert
# there so the generated config pins the freshly minted cert via the module's
# real seam — no path is hand-fed to the integration.
STATE="$D/state"
BRIDGE_DIR="$STATE/config/protonmail/bridge-v3"
mkdir -p "$BRIDGE_DIR"
CERT="$BRIDGE_DIR/cert.pem"
KEY="$BRIDGE_DIR/key.pem"

# Bridge-style server cert: self-signed with Basic Constraints CA:TRUE — exactly
# the shape rustls rejects as CaUsedAsEndEntity — plus a loopback SAN.
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$KEY" -out "$CERT" \
  -days 1 -subj "/CN=Proton Mail Bridge" \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "subjectAltName=IP:127.0.0.1,DNS:localhost" >/dev/null 2>&1

# An unrelated CA:TRUE cert for the msmtp negative control.
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$D/other.key" -out "$D/other.pem" \
  -days 1 -subj "/CN=Other" \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "subjectAltName=IP:127.0.0.1,DNS:localhost" >/dev/null 2>&1

if openssl x509 -in "$CERT" -text -noout | grep -q "CA:TRUE"; then
  pass "serving cert carries Basic Constraints CA:TRUE (mimics Proton Bridge)"
else
  fail "could not produce a CA:TRUE cert"
fi

# ---------- Generate the configs with the REAL integration code ----------
# The cert path rides $SPACES_PROTON_BRIDGE_STATE; with no authcmd on PATH yet
# the generated configs keep the bare `integration-proton-authcmd test`.
note "generate himalaya.toml + msmtprc via integration_proton._build_config"
SPACES_PROTON_BRIDGE_STATE="$STATE" python3 "$GEN"

# ---------- Generated-config asserts: the pins come from the integration ----------
note "generated config: integration pins backend.encryption.cert + tls_trust_file"
if grep -q "^backend\.encryption\.cert = \"$CERT\"\$" himalaya.toml; then
  pass "generated himalaya config pins backend.encryption.cert at the Bridge cert"
else
  fail "generated himalaya config missing the cert pin: $(grep -i 'encryption.cert' himalaya.toml || true)"
fi
if grep -q "^tls_trust_file $CERT\$" msmtprc; then
  pass "generated msmtprc carries tls_trust_file at the Bridge cert"
else
  fail "generated msmtprc missing tls_trust_file: $(grep -i trust msmtprc || true)"
fi

# ---------- Bridge password seam: shadow authcmd on PATH ----------
# Both configs call `integration-proton-authcmd <profile>` (himalaya auth.cmd +
# msmtp passwordeval). In production that console script prints the sealed-store
# bridge_password; here $AUTHCMD_STUB (a printf stub with a valid /nix/store
# shebang) supplies one without the store. Symlink it under the exact name so a
# bare PATH lookup resolves it.
mkdir -p "$D/bin"
ln -sf "$AUTHCMD_STUB" "$D/bin/integration-proton-authcmd"
export PATH="$D/bin:$PATH"

# ---------- Port seam ----------
# The module has NO port seam: IMAP_PORT=1143 / SMTP_PORT=1025 are hardcoded
# constants (Bridge always listens there, so they are constants, not config).
# The sandbox retargets the stub to high ports and seds the single generated
# port line in each per-scenario config copy; everything else is verbatim.
start_stub() {
  local kind="$1" port="$2" out="$3"
  python3 "$STUB" "$kind" "$CERT" "$KEY" "$port" >"$out" 2>&1 &
  echo $!
  for _ in $(seq 1 50); do
    grep -q "_LISTEN" "$out" 2>/dev/null && return 0
    sleep 0.1
  done
}

# ---------- IMAP: integration cert-pin (positive) ----------
note "IMAP positive: himalaya trusts the CA:TRUE cert via the integration's pin"
sed 's/^backend\.port = 1143$/backend.port = 14143/' himalaya.toml >h_pos.toml
pid=$(start_stub IMAP 14143 imap_pos.log)
himalaya -c h_pos.toml envelope list -a test >himala_pos.out 2>&1
wait "$pid" 2>/dev/null
if grep -q "IMAP_TLS_OK" imap_pos.log; then
  pass "himalaya completed TLS against the CA:TRUE cert (integration pin works)"
else
  fail "himalaya did NOT complete TLS (stub: $(cat imap_pos.log))"
fi
if grep -qi "CaUsedAsEndEntity\|invalid peer certificate" himala_pos.out; then
  fail "himalaya reported a cert error despite the pin: $(grep -i cert himala_pos.out | head -1)"
else
  pass "no CaUsedAsEndEntity / cert error from himalaya when pinned"
fi

# ---------- IMAP: pin stripped (negative control) ----------
note "IMAP negative: strip the integration's pin -> default verifier rejects CA:TRUE"
sed -e 's/^backend\.port = 1143$/backend.port = 14144/' -e '/^backend\.encryption\.cert/d' \
  himalaya.toml >h_neg.toml
pid=$(start_stub IMAP 14144 imap_neg.log)
himalaya -c h_neg.toml envelope list -a test >himala_neg.out 2>&1
wait "$pid" 2>/dev/null
if grep -qi "CaUsedAsEndEntity\|invalid peer certificate\|certificate" himala_neg.out; then
  pass "without the pin himalaya rejects the CA:TRUE cert (the hazard is real)"
else
  fail "expected a TLS rejection without pin, got: $(tail -3 himala_neg.out | tr '\n' ' ')"
fi

# ---------- SMTP: integration tls_trust_file (positive) ----------
note "SMTP positive: msmtp trusts the CA:TRUE cert via the integration's tls_trust_file"
sed 's/^port 1025$/port 11025/' msmtprc >m_pos.rc
pid=$(start_stub SMTP 11025 smtp_pos.log)
# No -f: the envelope-from must come from the generated msmtprc's own `from`
# line (a missing `from` is exit 78 EX_CONFIG before any TLS/SMTP happens).
printf 'From: u@localhost\r\nTo: a@localhost\r\nSubject: t\r\n\r\nhi\r\n' |
  msmtp -C m_pos.rc -a test -t >msmtp_pos.out 2>&1
wait "$pid" 2>/dev/null
# msmtp finished STARTTLS (server log) AND raised no certificate error (its
# dumb-stub AUTH/DATA failure is unrelated to TLS trust).
if grep -q "SMTP_TLS_OK" smtp_pos.log && ! grep -qi "certificate" msmtp_pos.out; then
  pass "msmtp trusted the CA:TRUE cert via tls_trust_file (no cert error)"
else
  fail "msmtp did NOT trust the cert (stub: $(cat smtp_pos.log); msmtp: $(tail -2 msmtp_pos.out | tr '\n' ' '))"
fi

# ---------- SMTP: wrong trust file (negative control) ----------
note "SMTP negative: point trust_file at an unrelated cert -> msmtp must reject"
sed -e 's/^port 1025$/port 11026/' -e "s|^tls_trust_file .*|tls_trust_file $D/other.pem|" \
  msmtprc >m_neg.rc
pid=$(start_stub SMTP 11026 smtp_neg.log)
printf 'From: u@localhost\r\nTo: a@localhost\r\nSubject: t\r\n\r\nhi\r\n' |
  msmtp -C m_neg.rc -a test -t >msmtp_neg.out 2>&1
kill "$pid" 2>/dev/null
wait "$pid" 2>/dev/null
if grep -qi "certificate verification failed\|not trusted\|could not send" msmtp_neg.out; then
  pass "msmtp rejected the mismatched cert (trust_file is enforced)"
else
  fail "msmtp did NOT reject a cert outside its trust_file: $(tail -2 msmtp_neg.out | tr '\n' ' ')"
fi

echo
echo "RESULT: $([ $rc -eq 0 ] && echo ALL-PASS || echo FAILURES)"
exit $rc
