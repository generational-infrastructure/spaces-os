# Render the himalaya TOML + msmtprc for a fake Proton profile by calling the
# REAL integration server's config builder — the point of this check is to pin
# the integration's OWN config generation (cert pin, tls_trust_file, ports,
# authcmd wiring) against himalaya/msmtp upgrades, not to re-hand-write configs.
#
# The cert path is driven purely through the module's own seam
# ($SPACES_PROTON_BRIDGE_STATE, set by the caller); nothing here overrides it.
# With no `integration-proton-authcmd` on PATH the generated configs keep the
# bare console-script name, exactly as the integration ships them.
#
# Writes ./himalaya.toml and ./msmtprc into the current working directory.
import os
import shutil

import integration_proton as ip

scratch = {}
cfg, err = ip._build_config("test", {"email": "u@localhost", ip._SCRATCH: scratch})
if err is not None:
    raise SystemExit(f"unexpected _build_config error: {err}")

with open("himalaya.toml", "w", encoding="utf-8") as f:
    f.write(cfg)

# _build_config materialized the msmtprc (0600) in a private tempdir it recorded
# in the scratch dict; copy it out next to the himalaya config for the check.
shutil.copyfile(os.path.join(scratch["dir"], "msmtprc"), "msmtprc")
print("GENERATED himalaya.toml + msmtprc", flush=True)
