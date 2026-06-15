<p align="center">
  <img src="https://gist.kenji.rsvp/kenji/735596d953134ee0a55136b95d5aaba7/raw/e7cd790a84979ea626e241071c49c4c0834e2f59/spaces-hero.png" alt="SpacesOS" width="820" />
</p>

<h1 align="center">SpacesOS</h1>

<p align="center">
  <strong>A complete operating system with your own AI agent at its heart —
  self-hosted, sovereign, and built for you.</strong>
</p>

---

Most people live across a collection of digital products. SpacesOS brings
them together — a digital environment where your services, data, tools, and
AI work as one system. Your own AI agent runs on hardware you control, works
with data you own, and stays with you across all your devices.

**Not another app. A place of your own.**

It belongs to **you**: no account to sign up for, no company reading your
conversations, nothing leaving your machines unless you send it. The model
runs locally, so it works offline and answers to no one but you.

And the agent isn't a chat box bolted on the side — it's woven through the
system. One shortcut summons it over whatever you're doing, and it can reach
into your real life — your calendar, your mail, your messages, your files —
but only ever acts when you say so.

Start a task on your laptop, walk away, and pick it up on your phone. The
same conversation. The same agent. Still running.

## What it feels like

<table>
  <tr>
    <td width="33%" valign="top"><img src="https://gist.githubusercontent.com/pinpox/a4d21df750d805007f948158ac3709f0/raw/pwa-chats.png" alt="All your chats, across every machine" /></td>
    <td width="33%" valign="top"><img src="https://gist.githubusercontent.com/pinpox/a4d21df750d805007f948158ac3709f0/raw/pwa-conversation.png" alt="A conversation with a shell-command confirmation" /></td>
    <td width="33%" valign="top"><img src="https://gist.githubusercontent.com/pinpox/a4d21df750d805007f948158ac3709f0/raw/pwa-machines.png" alt="The machines your agents run on" /></td>
  </tr>
  <tr>
    <td align="center"><sub><strong>Every chat in one place.</strong> Conversations from all your machines, with live status — <em>working</em>, <em>offline</em>, or <em>needs you</em>.</sub></td>
    <td align="center"><sub><strong>You hold the keys.</strong> The agent proposes; nothing touches your system until you tap <em>Allow</em>.</sub></td>
    <td align="center"><sub><strong>Your machines, your models.</strong> See where each agent runs and which local model it's using.</sub></td>
  </tr>
</table>

> The phone view is a Progressive Web App — add it to your home screen and
> it behaves like a native app. On the desktop, the very same agent lives
> in a panel that slides in over your work with **Super + A**.

## What you can do with it

**Just ask.** Summon the panel, type (or speak) a request, and the agent
takes it from there.

- 📅 **Calendar & contacts** — "What's on for Thursday?" · "Add lunch with
  Sam at 1pm" — over your own CalDAV / CardDAV (Nextcloud, Fastmail,
  Radicale, iCloud…).
- ✉️ **Email** — read, search, summarise and draft over plain IMAP/SMTP,
  or your Gmail and Google Calendar.
- 💬 **Signal** — catch up on messages and reply. Messages to other people
  only leave once you tap **Send** in the panel.
- 🗺️ **Maps & places** — find what's nearby and get directions, with your
  current location available when you allow it.
- 📚 **Knowledge** — quick, sourced answers from Wikipedia and Wikidata.
- 🔔 **Your desktop** — glance back over recent notifications, ask what you
  missed.
- 🖥️ **Real work** — it's a genuine coding agent underneath, so it can read
  and edit files and run commands — every shell command gated behind a
  one-tap confirmation.

New capabilities ("skills") snap in over time. Setting one up is a guided
popup you fill in directly — **your usernames and credentials never travel
through the chat.**

## Highlights

- **Yours, and private by default.** The model runs locally via
  [llama-swap](https://github.com/mostlygeek/llama-swap) on your own GPU.
  No account, no telemetry, works on a plane. Want a frontier model for a
  hard question? Add an [OpenRouter](https://openrouter.ai) key and switch
  models mid-conversation — your call, per chat.

- **Always there, never in the way.** The panel is anchored to the screen
  edge and stays out of alt-tab. **Super + A** to summon, again to dismiss.

- **Fire-and-forget agents.** Hit **Super + /**, type a task, press Enter —
  the agent runs in the background and pings you when it's done. Pick the
  conversation back up whenever you like.

- **One conversation, every device.** Kick something off on your desktop;
  follow along — or take over — from your phone on the same home network.
  Long jobs keep running on an always-on machine while your laptop sleeps.

- **Talk to it.** **Super + S** starts voice-to-text; transcription happens
  locally and lands straight in the chat.

- **It remembers.** An optional long-term memory quietly recalls durable
  facts across chats. One toggle turns it off for a sensitive conversation;
  one button wipes it entirely.

- **You stay in control.** Shell commands ask first. Outgoing messages ask
  first. Secrets go through a private popup, never the chat. The agent is
  capable on purpose — and fenced in on purpose.

## Built on solid ground

SpacesOS is assembled with [Nix](https://nixos.org) on top of
[NixOS](https://nixos.org), which is where its calmness comes from:

- **Declarative** — the whole system, agent and all, is described in one
  configuration. What you read is what runs.
- **Reliable** — upgrades are atomic, and every previous version is still in
  the boot menu. If something misbehaves, you roll back in one reboot.
- **Reproducible** — the same configuration produces the same machine, today
  or next year, on your laptop or the server in the closet.

## Try it yourself

> Coming to the talk? It's already running on the machines in the room — go
> play. This section is for taking it home.

SpacesOS is a [Nix](https://nixos.org) flake. Add it to your NixOS
configuration and pick a module:

```nix
inputs.spaces.url = "github:generational-infrastructure/spaces-os";

# …then, in your system's modules:
modules = [ spaces.nixosModules.spaces ];    # the whole desktop
# — or just the agent + panel, on the desktop you already run:
modules = [ spaces.nixosModules.pi-chat ];
```

Starting from scratch? Grab a bootable installer image from the
[latest release](https://github.com/generational-infrastructure/spaces-os/releases/latest),
write it to a USB stick, and boot.

> **Tip:** point your config at the
> [numtide binary cache](https://cache.numtide.com) first so the heavy bits
> download instead of building from source.

Everyday shortcuts:

| Shortcut | Does |
|---|---|
| **Super + A** | Toggle the chat panel |
| **Super + /** | Launch a background agent |
| **Super + S** | Voice-to-text |
| **Super + L** | Lock the screen |

The full list lives in [docs/keybindings.md](docs/keybindings.md).

## Going further

- **An always-on agent** — run an executor on a home server so long tasks
  survive your laptop sleeping, reachable from every device on your
  network. The design is written up in
  [docs/remote-pi-design.md](docs/remote-pi-design.md).

## For the curious & the contributors

- **How it's wired** —
  [Quickshell](https://quickshell.org) (the panel surface) ·
  [pi](https://github.com/mariozechner/pi-mono) (the coding agent) ·
  [llama-swap](https://github.com/mostlygeek/llama-swap) (local models) ·
  a small TypeScript daemon that keeps sessions alive and a web/PWA client.
- **Hacking on it** — start with [AGENTS.md](AGENTS.md) for the development
  workflow, the test layout, and how to drive the throwaway VMs.
- **The design notes** — [docs/](docs/) holds the architecture and status
  write-ups.

## License

See [LICENSE](LICENSE).
