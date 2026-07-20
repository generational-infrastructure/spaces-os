import pytest
from spaces_restore import crypto

# The canonical all-zero-entropy 24-word BIP39 phrase (256-bit seed of \x00*32).
ZERO_MNEMONIC = ("abandon " * 23 + "art").strip()


@pytest.fixture
def seed() -> bytes:
    return crypto.master_seed(ZERO_MNEMONIC)
