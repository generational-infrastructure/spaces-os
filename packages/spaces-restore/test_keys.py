from spaces_restore import crypto


def test_ssh_authorized_key_has_ed25519_prefix_and_comment(seed):
    pub = crypto.identity_key(seed).verify_key.encode()
    line = crypto.ssh_authorized_key(pub, "spaces-restore")
    # Every ed25519 OpenSSH key starts with this fixed base64 prefix.
    assert line.startswith("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI")
    assert line.endswith(" spaces-restore")


def test_ssh_authorized_key_without_comment_has_two_fields(seed):
    pub = crypto.identity_key(seed).verify_key.encode()
    assert len(crypto.ssh_authorized_key(pub).split()) == 2


def test_age_recipient_and_identity_format_and_deterministic(seed):
    recipient = crypto.age_recipient(seed)
    identity = crypto.age_identity(seed)
    assert recipient.startswith("age1")
    assert identity.startswith("AGE-SECRET-KEY-1")
    assert crypto.age_recipient(seed) == recipient  # deterministic
    assert crypto.age_identity(seed) == identity


def test_age_recipient_matches_bech32_of_curve_pubkey(seed):
    # cross-check the bech32 path against a known ssh-to-age recipient length
    # (age recipients are 62 chars: "age1" + 58 bech32 chars for 32 bytes).
    assert len(crypto.age_recipient(seed)) == 62
