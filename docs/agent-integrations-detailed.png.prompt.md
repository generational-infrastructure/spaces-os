# Prompt for the agent-integrations architecture chart

Generated 2026-07-02 via `google/gemini-3-pro-image-preview` (OpenRouter),
aspect ratio 16:9, size 1536x1024. The image itself lives in the HedgeDoc
pad <https://pad.lassul.us/spaces-os-integrations>, not this repo.
Regenerating is prompt roulette — arrow wiring took several
attempts; verify the TPM2 seal/unseal spokes and the Landlock-wall placement
against the description below before shipping a new render.

## subject

Detailed technical architecture diagram, flat vector infographic. TOP ROW,
three rounded rectangles left to right with clear gaps: LEFT "AGENT SANDBOX
(Landlock)" red tinted, containing box "pi runtime (model, tools, bash)";
MIDDLE "TRUSTED (user, unconfined)" green tinted, containing three stacked
boxes "Panel (GUI)", "Gateway (pi-sessiond)", "Broker (spaces-integrationd)";
RIGHT "INTEGRATION SANDBOX (Landlock)" orange tinted, containing box "MCP
server (mail, github, calendar)" and below it box "$CREDENTIALS_DIRECTORY
(plaintext, ramfs)". Across the top edge a dashed red arc goes from AGENT
SANDBOX over the trusted zone to INTEGRATION SANDBOX, broken in the middle by
a red X and a brick wall icon labeled "Landlock wall - no direct access".
BOTTOM: one wide blue tinted band labeled "systemd" spanning full width,
containing a LEFT-TO-RIGHT pipeline: box "systemd-creds encrypt (run by
broker)" then arrow labeled "write ciphertext" to cylinder "credstore (at
rest)" then arrow labeled "LoadCredentialEncrypted" to box
"systemd-creds.socket (root, decrypts)". BELOW the pipeline, centered, one
TPM chip icon labeled "TPM2" with exactly two connections: a line up-left to
the encrypt box labeled "seal", a line up-right to the socket box labeled
"unseal". Far left in the band: box "systemd --user manager" with arrow up to
INTEGRATION SANDBOX labeled "socket-activates via pi-landlock-exec". OTHER
ARROWS: double arrow "tool calls (rpc pipe)" between pi runtime and Gateway;
double arrow "approval" between Gateway and Panel; double arrow "MCP socket"
between Gateway and MCP server; small user icon above Panel with arrow down
labeled "enable / secrets"; arrow from Broker down to encrypt box labeled
"runs"; arrow from socket box up to "$CREDENTIALS_DIRECTORY" labeled
"plaintext at unit start". No other seal/unseal labels anywhere. All text
sharp, legible, correctly spelled.

## style

flat minimal vector infographic, white background, muted pastel colors, thin
dark outlines, sans-serif labels

## composition

landscape, three columns on top, full-width systemd band at bottom, TPM2
centered below the pipeline

## text

AGENT SANDBOX, TRUSTED, INTEGRATION SANDBOX, systemd, pi runtime, Panel,
Gateway, Broker, MCP server, systemd --user manager, systemd-creds encrypt,
credstore, systemd-creds.socket, TPM2, seal, unseal, Landlock wall - no
direct access, plaintext at unit start

## Known deviation in the shipped image

The "socket-activates via pi-landlock-exec" arrow points at the AGENT
sandbox instead of the INTEGRATION sandbox. Coincidentally still true (the
per-session pi runtime is also launched via systemd-run --user +
pi-landlock-exec), but not what the prompt asked for.
