import hashlib

from spaces_restore import crypto, secp


def test_nostr_secret_deterministic_and_distinct(seed):
    assert secp.nostr_secret(seed) == secp.nostr_secret(seed)
    # A separate branch: not the seed, not the manifest AEAD key.
    assert secp.nostr_secret(seed) != seed
    assert secp.nostr_secret(seed) != crypto.manifest_key(seed)


def test_xonly_pubkey_is_32_bytes(seed):
    assert len(secp.xonly_pubkey(secp.nostr_secret(seed))) == 32


def test_xonly_pubkey_matches_bip340_vector_0():
    # BIP340 test vector 0: secret 0x…03 -> this x-only pubkey.
    secret = bytes(31) + b"\x03"
    assert (
        secp.xonly_pubkey(secret).hex()
        == "f9308a019258c31049344f85f89d5229b531c845836f99b08601f113bce036f9"
    )


def test_schnorr_sign_verify_roundtrip(seed):
    secret = secp.nostr_secret(seed)
    msg = hashlib.sha256(b"rendezvous").digest()
    sig = secp.schnorr_sign(secret, msg)
    assert secp.schnorr_verify(secp.xonly_pubkey(secret), msg, sig) is True


def test_schnorr_verify_rejects_tampered_message(seed):
    secret = secp.nostr_secret(seed)
    sig = secp.schnorr_sign(secret, hashlib.sha256(b"a").digest())
    other = hashlib.sha256(b"b").digest()
    assert secp.schnorr_verify(secp.xonly_pubkey(secret), other, sig) is False


def test_schnorr_verify_rejects_wrong_key(seed):
    secret = secp.nostr_secret(seed)
    msg = hashlib.sha256(b"a").digest()
    sig = secp.schnorr_sign(secret, msg)
    wrong_key = secp.xonly_pubkey(bytes(31) + b"\x02")
    assert secp.schnorr_verify(wrong_key, msg, sig) is False
