"""secp256k1 / BIP340 schnorr for the Nostr key.

Nostr uses secp256k1, so this is a separate key branch from the ed25519
identity/rendezvous keys, derived from the same seed.
"""

from __future__ import annotations

from coincurve import PrivateKey, PublicKeyXOnly

from .crypto import hkdf_sha256

INFO_NOSTR = b"nostr-rendezvous-v1"
_AUX_ZERO = bytes(32)  # zero aux-rand -> deterministic BIP340 signatures


def nostr_secret(seed: bytes) -> bytes:
    return hkdf_sha256(seed, INFO_NOSTR)


def xonly_pubkey(secret: bytes) -> bytes:
    return PrivateKey(secret).public_key_xonly.format()


def schnorr_sign(secret: bytes, msg32: bytes) -> bytes:
    return PrivateKey(secret).sign_schnorr(msg32, _AUX_ZERO)


def schnorr_verify(pubkey_xonly: bytes, msg32: bytes, sig: bytes) -> bool:
    try:
        return PublicKeyXOnly(pubkey_xonly).verify(sig, msg32)
    except Exception:  # noqa: BLE001 -- malformed key/sig is just invalid
        return False
