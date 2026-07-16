import nacl.utils
import pytest
from nacl.exceptions import CryptoError
from spaces_restore import crypto
from spaces_restore.manifest import Manifest

# The canonical all-zero-entropy 24-word BIP39 phrase (256-bit seed of \x00*32).
ZERO_MNEMONIC = (
    "abandon abandon abandon abandon abandon abandon abandon abandon "
    "abandon abandon abandon abandon abandon abandon abandon abandon "
    "abandon abandon abandon abandon abandon abandon abandon art"
)


def test_master_seed_is_32_zero_bytes_and_deterministic():
    seed = crypto.master_seed(ZERO_MNEMONIC)
    assert seed == b"\x00" * 32
    assert crypto.master_seed(ZERO_MNEMONIC) == seed


def test_master_seed_tolerates_whitespace():
    assert (
        crypto.master_seed("  " + ZERO_MNEMONIC.replace(" ", "  ") + "\n")
        == b"\x00" * 32
    )


def test_master_seed_rejects_bad_checksum():
    with pytest.raises(ValueError, match="mnemonic"):
        crypto.master_seed("abandon " * 23 + "abandon")


def test_master_seed_requires_24_words():
    twelve_word = "abandon " * 11 + "about"  # valid 12-word phrase, but only 128-bit
    with pytest.raises(ValueError, match="24-word"):
        crypto.master_seed(twelve_word)


def test_rendezvous_key_unlinkable_to_identity():
    seed = crypto.master_seed(ZERO_MNEMONIC)
    identity = crypto.identity_key(seed).verify_key.encode()
    rendezvous = crypto.rendezvous_key(seed).verify_key.encode()
    assert identity != rendezvous


def test_derivations_are_deterministic():
    seed = crypto.master_seed(ZERO_MNEMONIC)
    assert crypto.manifest_key(seed) == crypto.manifest_key(seed)
    assert crypto.rendezvous_key(seed).encode() == crypto.rendezvous_key(seed).encode()


def test_hkdf_matches_rfc5869_a1_vector():
    ikm = bytes.fromhex("0b" * 22)
    salt = bytes.fromhex("000102030405060708090a0b0c")
    info = bytes.fromhex("f0f1f2f3f4f5f6f7f8f9")
    okm = crypto.hkdf_sha256(ikm, info, length=42, salt=salt)
    assert okm.hex() == (
        "3cb25f25faacd57a90434f64d0362f2a"
        "2d2d0a90cf1a5a4c5db02d56ecc4c5bf"
        "34007208d5b887185865"
    )


def test_seal_open_roundtrip():
    key = crypto.manifest_key(crypto.master_seed(ZERO_MNEMONIC))
    manifest = Manifest(config="borg:c").to_json()
    assert crypto.open_value(key, crypto.seal(key, manifest)) == manifest


def test_padding_hides_plaintext_length():
    key = crypto.manifest_key(crypto.master_seed(ZERO_MNEMONIC))
    nonce = b"\x01" * 24
    short = crypto.seal(key, b'{"a":1}', nonce=nonce)
    longer = crypto.seal(key, b'{"a":1,"padded":"aaaaaaaaaaaaaaaaaaaa"}', nonce=nonce)
    assert len(short) == len(longer)


def test_tampered_ciphertext_is_rejected():
    key = crypto.manifest_key(crypto.master_seed(ZERO_MNEMONIC))
    blob = bytearray(crypto.seal(key, b'{"a":1}'))
    blob[-1] ^= 0x01
    with pytest.raises(CryptoError):
        crypto.open_value(key, bytes(blob))


def test_wrong_key_cannot_open():
    key = crypto.manifest_key(crypto.master_seed(ZERO_MNEMONIC))
    blob = crypto.seal(key, b'{"a":1}')
    with pytest.raises(CryptoError):
        crypto.open_value(nacl.utils.random(32), blob)


def test_bep44_sign_verify_roundtrip():
    seed = crypto.master_seed(ZERO_MNEMONIC)
    rv = crypto.rendezvous_key(seed)
    value = crypto.seal(crypto.manifest_key(seed), b'{"a":1}')
    sig = crypto.sign_record(rv, 7, value)
    assert crypto.verify_record(rv.verify_key.encode(), 7, value, sig) is True


def test_bep44_verify_fails_on_rolled_back_seq():
    seed = crypto.master_seed(ZERO_MNEMONIC)
    rv = crypto.rendezvous_key(seed)
    value = crypto.seal(crypto.manifest_key(seed), b'{"a":1}')
    sig = crypto.sign_record(rv, 7, value)
    assert crypto.verify_record(rv.verify_key.encode(), 8, value, sig) is False


def test_bep44_verify_fails_on_tampered_value():
    seed = crypto.master_seed(ZERO_MNEMONIC)
    rv = crypto.rendezvous_key(seed)
    value = crypto.seal(crypto.manifest_key(seed), b'{"a":1}')
    sig = crypto.sign_record(rv, 7, value)
    assert crypto.verify_record(rv.verify_key.encode(), 7, value + b"x", sig) is False
