// Spaces OS — Arlo home UI kit (vanilla-TS port of ArloHome.jsx).
//
// A "Space" desktop: the OS top bar (Clan/Space switcher, nav, live Clan
// presence, quick settings + clock), a centred conversation with Arlo, the
// orb + tagline, suggested prompts, and the ask bar. Send a message (Enter or
// Send) and Arlo replies with context-aware canned text.
//
// Arlo's render and the Clan portraits are bespoke clay assets in the Figma
// file; here the design system's own fallbacks stand in (the iridescent orb
// and tinted-initial avatars). Drop real images in design/assets/ and pass a
// `src` to ArloOrb / Avatar for full fidelity.

import { h } from "../lib/dom";
import { icon } from "../lib/icon";
import {
  ArloOrb,
  Avatar,
  Badge,
  Button,
  IconButton,
  Input,
} from "../lib/components";

const KIN_MARK = "/design/assets/logos/kin-mark-black.svg";

interface Clan {
  n: string;
  s: "online" | "busy" | "offline";
}
const CLAN: Clan[] = [
  { n: "Saori", s: "online" },
  { n: "Matt", s: "online" },
  { n: "Fiona", s: "busy" },
  { n: "Christa", s: "offline" },
];

const SUGGESTIONS = [
  "Summarise today’s Clan activity",
  "Build me a currency converter",
  "Find the Furano photos",
  "Start a call with Saori",
];

const REPLIES = {
  default:
    "On it. Everything I do runs locally on your own hardware — nothing leaves this Space unless you say so.",
  build:
    "Sure. I’ll spin up a small converter app right here in your Space. Want it private to you, or shared with the Clan?",
  find: "Found a folder “Furano photos” in Shared — 23 images, added 10 days ago. Want me to open it?",
  call: "Calling Saori now. I’ll drop a join link into the Clan shelf so others can hop in.",
};

function replyFor(t: string): string {
  const s = t.toLowerCase();
  if (s.includes("build") || s.includes("converter") || s.includes("app"))
    return REPLIES.build;
  if (s.includes("find") || s.includes("photo")) return REPLIES.find;
  if (s.includes("call") || s.includes("saori")) return REPLIES.call;
  return REPLIES.default;
}

function TopBar(): HTMLElement {
  return h(
    "header",
    {
      style: {
        display: "flex",
        alignItems: "center",
        gap: 16,
        height: 52,
        padding: "0 16px",
        flex: "0 0 auto",
        background: "rgba(255,255,255,0.7)",
        backdropFilter: "blur(16px)",
        borderBottom: "1px solid var(--ink-100)",
      },
    },
    h(
      "div",
      {
        style: {
          display: "flex",
          alignItems: "center",
          gap: 10,
          padding: "6px 10px",
          borderRadius: "var(--radius-pill)",
          background: "var(--ink-100)",
        },
      },
      h("img", { src: KIN_MARK, alt: "", style: { width: 18, height: 18 } }),
      h(
        "span",
        {
          style: {
            fontFamily: "var(--font-ui)",
            fontSize: 14,
            fontWeight: 600,
            color: "var(--ink-900)",
          },
        },
        "Your Clan",
      ),
      icon("chevron-down", { size: 15, color: "var(--ink-400)" }),
    ),
    h(
      "nav",
      { style: { display: "flex", gap: 4 } },
      ...["Home", "Recents", "Help"].map((l, i) =>
        h(
          "span",
          {
            style: {
              fontFamily: "var(--font-ui)",
              fontSize: 14,
              fontWeight: i === 0 ? 600 : 500,
              color: i === 0 ? "var(--ink-900)" : "var(--ink-400)",
              padding: "6px 12px",
              cursor: "pointer",
            },
          },
          l,
        ),
      ),
    ),
    h("div", { style: { flex: "1" } }),
    h(
      "div",
      { style: { display: "flex", alignItems: "center", marginRight: 6 } },
      ...CLAN.map((c, i) =>
        h(
          "span",
          {
            style: {
              marginLeft: i ? -8 : 0,
              position: "relative",
              zIndex: CLAN.length - i,
            },
          },
          Avatar({ name: c.n, size: 28, status: c.s }),
        ),
      ),
    ),
    h(
      "div",
      {
        style: {
          display: "flex",
          alignItems: "center",
          gap: 2,
          color: "var(--ink-500)",
        },
      },
      IconButton({ icon: "wifi", label: "Network", size: "sm" }),
      IconButton({ icon: "bluetooth", label: "Bluetooth", size: "sm" }),
      h(
        "span",
        {
          style: {
            fontFamily: "var(--font-mono)",
            fontSize: 12,
            color: "var(--ink-500)",
            padding: "0 6px",
          },
        },
        "14:07",
      ),
      IconButton({ icon: "settings", label: "Quick settings", size: "sm" }),
    ),
  );
}

function Message(from: "arlo" | "me", text: string): HTMLElement {
  const arlo = from === "arlo";
  return h(
    "div",
    {
      style: {
        display: "flex",
        gap: 12,
        justifyContent: arlo ? "flex-start" : "flex-end",
        marginBottom: 18,
      },
    },
    arlo
      ? h(
          "div",
          { style: { flex: "0 0 auto", marginTop: 2 } },
          ArloOrb({ size: 36 }),
        )
      : null,
    h(
      "div",
      {
        style: {
          maxWidth: 520,
          padding: "14px 18px",
          borderRadius: 18,
          fontFamily: "var(--font-ui)",
          fontSize: 15,
          lineHeight: "1.5",
          background: arlo ? "var(--ink-100)" : "var(--ink-900)",
          color: arlo ? "var(--ink-900)" : "#fff",
          borderTopLeftRadius: arlo ? 6 : 18,
          borderTopRightRadius: arlo ? 18 : 6,
        },
      },
      text,
    ),
  );
}

function ArloHome(): HTMLElement {
  const scroll = h("div", {
    style: { flex: "1", overflowY: "auto", padding: "40px 24px 12px" },
  });
  const thread = h("div", {
    style: { display: "flex", flexDirection: "column" },
  });

  const conversation = h(
    "div",
    { style: { maxWidth: 760, margin: "0 auto" } },
    h(
      "div",
      {
        style: {
          display: "flex",
          flexDirection: "column",
          alignItems: "center",
          textAlign: "center",
          marginBottom: 36,
        },
      },
      ArloOrb({ size: "xl", pulse: true }),
      Badge({
        label: "Arlo · local agent",
        tone: "glass",
        style: { marginTop: -12, boxShadow: "var(--ring-hairline)" },
      }),
      h(
        "h1",
        {
          style: {
            fontFamily: "var(--font-display)",
            fontSize: 34,
            fontWeight: 700,
            letterSpacing: "-0.02em",
            color: "var(--ink-900)",
            margin: "18px 0 0",
          },
        },
        "A new ",
        h(
          "span",
          {
            style: {
              fontFamily: "var(--font-serif)",
              fontStyle: "italic",
              fontWeight: 400,
              color: "var(--kin-sage)",
            },
          },
          "kinder",
        ),
        " computer",
      ),
    ),
    thread,
  );
  scroll.appendChild(conversation);

  thread.appendChild(
    Message(
      "arlo",
      "Good afternoon. I’m Arlo — your agent for this Space. What shall we make today?",
    ),
  );

  const ask = Input({
    iconLeft: "sparkle",
    placeholder: "Ask Arlo anything…",
    size: "lg",
  });

  const send = (override?: string) => {
    const text = (override ?? ask.input.value).trim();
    if (!text) return;
    thread.appendChild(Message("me", text));
    ask.input.value = "";
    scroll.scrollTop = scroll.scrollHeight;
    setTimeout(() => {
      thread.appendChild(Message("arlo", replyFor(text)));
      scroll.scrollTop = scroll.scrollHeight;
    }, 420);
  };
  ask.input.addEventListener("keydown", (e) => {
    if ((e as KeyboardEvent).key === "Enter") send();
  });

  const suggestions = h(
    "div",
    { style: { display: "flex", gap: 8, marginBottom: 12, flexWrap: "wrap" } },
    ...SUGGESTIONS.map((s) =>
      h(
        "button",
        {
          onClick: () => send(s),
          style: {
            border: "none",
            cursor: "pointer",
            padding: "8px 14px",
            borderRadius: "var(--radius-pill)",
            background: "#fff",
            boxShadow: "var(--ring-hairline)",
            fontFamily: "var(--font-ui)",
            fontSize: 13,
            color: "var(--ink-700)",
          },
        },
        s,
      ),
    ),
  );

  const dock = h(
    "div",
    { style: { flex: "0 0 auto", padding: "8px 24px 22px" } },
    h(
      "div",
      { style: { maxWidth: 760, margin: "0 auto" } },
      suggestions,
      h(
        "div",
        { style: { display: "flex", gap: 10, alignItems: "center" } },
        h("div", { style: { flex: "1" } }, ask.el),
        IconButton({
          icon: "phone",
          label: "Voice",
          variant: "filled",
          size: "lg",
        }),
        Button({
          label: "Send",
          intent: "primary",
          size: "lg",
          iconRight: "arrow-up-right",
          onClick: () => send(),
        }),
      ),
      h(
        "div",
        {
          style: {
            display: "flex",
            alignItems: "center",
            justifyContent: "center",
            gap: 8,
            marginTop: 14,
            color: "var(--ink-400)",
          },
        },
        icon("lock", { size: 14 }),
        h(
          "span",
          { style: { fontFamily: "var(--font-ui)", fontSize: 12 } },
          "Runs locally on hardware you own. Your data stays in this Space.",
        ),
      ),
    ),
  );

  return h(
    "div",
    {
      style: {
        height: "100vh",
        display: "flex",
        flexDirection: "column",
        background:
          "linear-gradient(180deg,#fff 0%,var(--clan-secondary-50) 100%)",
      },
    },
    TopBar(),
    scroll,
    dock,
  );
}

document.getElementById("root")!.appendChild(ArloHome());
