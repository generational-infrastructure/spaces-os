"""Crypto core: keys, sealing, and signing, all derived from one BIP39 mnemonic.

Pure functions, no network or filesystem. See the spec for the threat model:
docs/superpowers/specs/2026-07-14-mnemonic-restore-spec.md.
"""

from __future__ import annotations

import base64
import hashlib
import hmac

import bech32
import nacl.bindings as _sodium
from mnemonic import Mnemonic
from nacl.exceptions import BadSignatureError
from nacl.signing import SigningKey, VerifyKey
from nacl.utils import random as _random_bytes

# HKDF domain-separation labels; bump the -vN suffix to rotate a derived key.
INFO_RENDEZVOUS = b"spaces-restore-rendezvous-v1"
INFO_MANIFEST = b"spaces-restore-manifest-v1"

VALUE_MAGIC = b"sr1"
PAD_SIZE = 512
_NONCE_BYTES = _sodium.crypto_aead_xchacha20poly1305_ietf_NPUBBYTES  # 24
_SEED_BYTES = 32
_LEN_PREFIX = 2  # bytes of length prefix inside the padding

_MNEMONIC = Mnemonic("english")


def hkdf_sha256(ikm: bytes, info: bytes, length: int = 32, salt: bytes = b"") -> bytes:
    """RFC 5869 HKDF over SHA-256."""
    if not salt:
        salt = b"\x00" * hashlib.sha256().digest_size
    prk = hmac.new(salt, ikm, hashlib.sha256).digest()
    okm = b""
    block = b""
    counter = 1
    while len(okm) < length:
        block = hmac.new(prk, block + info + bytes([counter]), hashlib.sha256).digest()
        okm += block
        counter += 1
    return okm[:length]


def generate_mnemonic() -> str:
    return _MNEMONIC.generate(strength=_SEED_BYTES * 8)


def master_seed(words: str) -> bytes:
    """The 32-byte ed25519 seed a 24-word mnemonic encodes.

    The mnemonic is the seed's BIP39 entropy (melt-compatible), not PBKDF2. 24
    words are required for a full 256-bit seed.
    """
    words = " ".join(words.split())
    if not _MNEMONIC.check(words):
        msg = "invalid BIP39 mnemonic (unknown word or bad checksum)"
        raise ValueError(msg)
    seed = bytes(_MNEMONIC.to_entropy(words))
    if len(seed) != _SEED_BYTES:
        msg = f"need a 24-word mnemonic (256-bit seed); got a {len(seed) * 8}-bit one"
        raise ValueError(msg)
    return seed


def identity_key(seed: bytes) -> SigningKey:
    """The SSH / age identity keypair."""
    return SigningKey(seed)


def rendezvous_key(seed: bytes) -> SigningKey:
    """The record-signing keypair, derived separately so it's unlinkable to the identity."""
    return SigningKey(hkdf_sha256(seed, INFO_RENDEZVOUS))


def manifest_key(seed: bytes) -> bytes:
    """The AEAD key for the encrypted manifest."""
    return hkdf_sha256(seed, INFO_MANIFEST)


def _pad(pt: bytes, size: int = PAD_SIZE) -> bytes:
    if len(pt) + _LEN_PREFIX > size:
        msg = f"manifest too large to pad into {size} bytes"
        raise ValueError(msg)
    filler = b"\x00" * (size - _LEN_PREFIX - len(pt))
    return len(pt).to_bytes(_LEN_PREFIX, "big") + pt + filler


def _unpad(padded: bytes) -> bytes:
    n = int.from_bytes(padded[:_LEN_PREFIX], "big")
    if n > len(padded) - _LEN_PREFIX:
        msg = "corrupt padding length"
        raise ValueError(msg)
    return padded[_LEN_PREFIX : _LEN_PREFIX + n]


def seal(k_enc: bytes, manifest: bytes, nonce: bytes | None = None) -> bytes:
    """Pad-then-encrypt into a fixed-length blob so ciphertext length leaks nothing.

    Uses a fresh random 24-byte nonce; never reuse one across versions.
    """
    if nonce is None:
        nonce = _random_bytes(_NONCE_BYTES)
    if len(nonce) != _NONCE_BYTES:
        msg = f"nonce must be {_NONCE_BYTES} bytes"
        raise ValueError(msg)
    ct = _sodium.crypto_aead_xchacha20poly1305_ietf_encrypt(
        _pad(manifest), b"", nonce, k_enc
    )
    return VALUE_MAGIC + nonce + ct


def open_value(k_enc: bytes, value: bytes) -> bytes:
    """Inverse of seal(). Raises on tamper or wrong key."""
    magic = len(VALUE_MAGIC)
    if value[:magic] != VALUE_MAGIC:
        msg = "unrecognized value format (bad magic)"
        raise ValueError(msg)
    nonce = value[magic : magic + _NONCE_BYTES]
    ct = value[magic + _NONCE_BYTES :]
    padded = _sodium.crypto_aead_xchacha20poly1305_ietf_decrypt(ct, b"", nonce, k_enc)
    return _unpad(padded)


def _signable(seq: int, v: bytes) -> bytes:
    """Canonical signing input: bencode of seq and v."""
    return b"3:seqi" + str(seq).encode() + b"e1:v" + str(len(v)).encode() + b":" + v


def sign_record(rv_sk: SigningKey, seq: int, v: bytes) -> bytes:
    return rv_sk.sign(_signable(seq, v)).signature


def verify_record(rv_pub: bytes, seq: int, v: bytes, sig: bytes) -> bool:
    try:
        VerifyKey(rv_pub).verify(_signable(seq, v), sig)
    except BadSignatureError:
        return False
    return True


def _ssh_string(data: bytes) -> bytes:
    return len(data).to_bytes(4, "big") + data


def ssh_authorized_key(identity_pub: bytes, comment: str = "") -> str:
    """The identity key as an OpenSSH authorized_keys line (for the backup host)."""
    blob = _ssh_string(b"ssh-ed25519") + _ssh_string(identity_pub)
    line = "ssh-ed25519 " + base64.b64encode(blob).decode()
    return f"{line} {comment}" if comment else line


def _age_encode(hrp: str, x25519_key: bytes) -> str:
    # Bech32 over the ed25519->X25519 conversion, matching ssh-to-age.
    return bech32.bech32_encode(hrp, bech32.convertbits(x25519_key, 8, 5))


def age_recipient(seed: bytes) -> str:
    """The age recipient (age1…); `clan secrets users add recovery <this>`."""
    pub, _sk = _sodium.crypto_sign_seed_keypair(seed)
    return _age_encode("age", _sodium.crypto_sign_ed25519_pk_to_curve25519(pub))


def age_identity(seed: bytes) -> str:
    """The secret age key (AGE-SECRET-KEY-1…); `export SOPS_AGE_KEY=<this>` at restore."""
    _pub, sk64 = _sodium.crypto_sign_seed_keypair(seed)
    return _age_encode(
        "age-secret-key-", _sodium.crypto_sign_ed25519_sk_to_curve25519(sk64)
    ).upper()
