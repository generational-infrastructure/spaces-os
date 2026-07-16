from spaces_restore import crypto


def test_generated_mnemonic_is_valid_and_24_words():
    words = crypto.generate_mnemonic()
    assert len(words.split()) == 24
    # round-trips through master_seed (checksum valid, 32-byte seed)
    assert len(crypto.master_seed(words)) == 32


def test_generated_mnemonics_are_random():
    assert crypto.generate_mnemonic() != crypto.generate_mnemonic()
