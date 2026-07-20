// Kin / Spaces OS core components — vanilla-TS port of the design system's
// React primitives. Each factory returns a real DOM node with the same inline
// styles, sizes, and interaction states (hover lifts, focus rings, the
// segmented-control thumb) as the JSX originals.

import { applyStyle, h, type Style } from "./dom";
import { icon } from "./icon";

let keyframesInstalled = false;
/** Inject the few @keyframes the components animate (idempotent). */
export function ensureKeyframes(): void {
  if (keyframesInstalled) return;
  keyframesInstalled = true;
  const style = document.createElement("style");
  style.textContent =
    "@keyframes kin-arlo-pulse{0%{box-shadow:0 0 0 0 rgba(149,55,255,0.45)}70%{box-shadow:0 0 0 26px rgba(149,55,255,0)}100%{box-shadow:0 0 0 0 rgba(149,55,255,0)}}";
  document.head.appendChild(style);
}

// ---------------------------------------------------------------- Button

type BtnSize = "sm" | "md" | "lg";
type Intent =
  | "primary"
  | "secondary"
  | "outline"
  | "ghost"
  | "destructive"
  | "warm";

const BTN_SIZES: Record<
  BtnSize,
  { height: number; padding: string; font: string; gap: number; icon: number }
> = {
  sm: { height: 32, padding: "0 14px", font: "var(--fs-xs)", gap: 6, icon: 15 },
  md: { height: 40, padding: "0 18px", font: "var(--fs-sm)", gap: 8, icon: 17 },
  lg: { height: 48, padding: "0 24px", font: "var(--fs-md)", gap: 9, icon: 19 },
};

function intentStyle(intent: Intent): Style {
  switch (intent) {
    case "secondary":
      return { background: "var(--ink-100)", color: "var(--ink-900)" };
    case "outline":
      return {
        background: "transparent",
        color: "var(--ink-900)",
        boxShadow: "inset 0 0 0 1px var(--border-default)",
      };
    case "ghost":
      return { background: "transparent", color: "var(--ink-700)" };
    case "destructive":
      return { background: "var(--clan-error-500)", color: "#fff" };
    case "warm":
      return { background: "var(--grad-warm)", color: "#fff" };
    default:
      return { background: "var(--ink-900)", color: "#fff" };
  }
}

export function Button(opts: {
  label: string;
  intent?: Intent;
  size?: BtnSize;
  iconLeft?: string;
  iconRight?: string;
  disabled?: boolean;
  fullWidth?: boolean;
  onClick?: () => void;
  style?: Style;
}): HTMLButtonElement {
  const s = BTN_SIZES[opts.size ?? "md"];
  const btn = h(
    "button",
    {
      type: "button",
      onClick: opts.disabled ? undefined : opts.onClick,
      style: {
        display: opts.fullWidth ? "flex" : "inline-flex",
        width: opts.fullWidth ? "100%" : undefined,
        alignItems: "center",
        justifyContent: "center",
        gap: s.gap,
        height: s.height,
        padding: s.padding,
        fontFamily: "var(--font-ui)",
        fontSize: s.font,
        fontWeight: "var(--fw-semibold)",
        letterSpacing: "var(--ls-normal)",
        lineHeight: "1",
        whiteSpace: "nowrap",
        border: "none",
        borderRadius: "var(--radius-pill)",
        cursor: opts.disabled ? "not-allowed" : "pointer",
        opacity: opts.disabled ? 0.4 : 1,
        transition:
          "transform var(--dur-fast) var(--ease-out), filter var(--dur-fast) var(--ease-out), background var(--dur-fast) var(--ease-out)",
        ...intentStyle(opts.intent ?? "primary"),
        ...opts.style,
      },
    },
    opts.iconLeft
      ? icon(opts.iconLeft, { size: s.icon, strokeWidth: 2 })
      : null,
    opts.label,
    opts.iconRight
      ? icon(opts.iconRight, { size: s.icon, strokeWidth: 2 })
      : null,
  );
  if (!opts.disabled) {
    const press = (v: string) => () => (btn.style.transform = v);
    btn.addEventListener("mousedown", press("scale(0.97)"));
    btn.addEventListener("mouseup", press("scale(1)"));
    btn.addEventListener("mouseleave", press("scale(1)"));
  }
  return btn;
}

// ---------------------------------------------------------------- IconButton

const IB_SIZE: Record<BtnSize, number> = { sm: 28, md: 34, lg: 40 };
const IB_ICON: Record<BtnSize, number> = { sm: 16, md: 18, lg: 20 };

export function IconButton(opts: {
  icon: string;
  label?: string;
  size?: BtnSize;
  variant?: "ghost" | "filled";
  active?: boolean;
  onClick?: () => void;
  style?: Style;
}): HTMLButtonElement {
  const size = opts.size ?? "md";
  const dim = IB_SIZE[size];
  const filled = opts.variant === "filled" || opts.active;
  const btn = h(
    "button",
    {
      type: "button",
      "aria-label": opts.label,
      title: opts.label,
      onClick: opts.onClick,
      style: {
        display: "inline-flex",
        alignItems: "center",
        justifyContent: "center",
        width: dim,
        height: dim,
        padding: 0,
        color: opts.active ? "var(--ink-900)" : "var(--ink-500)",
        background: filled ? "var(--ink-100)" : "transparent",
        border: "none",
        borderRadius: "var(--radius-md)",
        cursor: "pointer",
        transition:
          "background var(--dur-fast) var(--ease-out), color var(--dur-fast) var(--ease-out)",
        ...opts.style,
      },
    },
    icon(opts.icon, { size: IB_ICON[size] }),
  );
  if (!filled) {
    btn.addEventListener(
      "mouseenter",
      () => (btn.style.background = "var(--ink-100)"),
    );
    btn.addEventListener(
      "mouseleave",
      () => (btn.style.background = "transparent"),
    );
  }
  return btn;
}

// ---------------------------------------------------------------- Input

export function Input(opts: {
  value?: string;
  placeholder?: string;
  iconLeft?: string;
  size?: BtnSize;
  onInput?: (value: string) => void;
  onKeyDown?: (e: KeyboardEvent) => void;
}): { el: HTMLElement; input: HTMLInputElement } {
  const height = opts.size === "lg" ? 48 : opts.size === "sm" ? 34 : 40;
  const input = h("input", {
    type: "text",
    value: opts.value ?? "",
    placeholder: opts.placeholder,
    style: {
      flex: "1",
      minWidth: 0,
      border: "none",
      outline: "none",
      background: "transparent",
      fontFamily: "var(--font-ui)",
      fontSize: "var(--fs-sm)",
      color: "var(--ink-900)",
    },
  });
  const wrap = h(
    "div",
    {
      style: {
        display: "flex",
        alignItems: "center",
        gap: 8,
        height,
        padding: opts.iconLeft ? "0 14px 0 12px" : "0 14px",
        background: "var(--ink-100)",
        borderRadius: "var(--radius-md)",
        boxShadow: "inset 0 0 0 1px transparent",
        transition:
          "background var(--dur-fast) var(--ease-out), box-shadow var(--dur-fast) var(--ease-out)",
      },
    },
    opts.iconLeft
      ? icon(opts.iconLeft, { size: 18, color: "var(--ink-400)" })
      : null,
    input,
  );
  const focus = (on: boolean) => {
    wrap.style.background = on ? "#fff" : "var(--ink-100)";
    wrap.style.boxShadow = on
      ? "0 0 0 2px color-mix(in srgb, var(--focus-ring) 35%, transparent), inset 0 0 0 1px var(--focus-ring)"
      : "inset 0 0 0 1px transparent";
  };
  input.addEventListener("focus", () => focus(true));
  input.addEventListener("blur", () => focus(false));
  if (opts.onInput)
    input.addEventListener("input", () => opts.onInput!(input.value));
  if (opts.onKeyDown)
    input.addEventListener("keydown", (e) =>
      opts.onKeyDown!(e as KeyboardEvent),
    );
  return { el: wrap, input };
}

// ---------------------------------------------------------------- SegmentedControl

export function SegmentedControl(opts: {
  options: { value: string; label?: string; icon?: string }[];
  value: string;
  onChange?: (value: string) => void;
  size?: "sm" | "md";
}): HTMLElement {
  const height = opts.size === "sm" ? 30 : 36;
  const pad = 3;
  const count = opts.options.length || 1;
  let current = opts.value;

  const thumb = h("span", {
    "aria-hidden": "true",
    style: {
      position: "absolute",
      top: pad,
      left: pad,
      bottom: pad,
      width: `calc((100% - ${pad * 2}px) / ${count})`,
      background: "#fff",
      borderRadius: "var(--radius-pill)",
      boxShadow: "0 1px 3px rgba(0,0,0,0.12)",
      transition: "transform var(--dur-base) var(--ease-soft)",
    },
  });

  const buttons: HTMLButtonElement[] = [];
  const moveThumb = () => {
    const idx = Math.max(
      0,
      opts.options.findIndex((o) => o.value === current),
    );
    thumb.style.transform = `translateX(${idx * 100}%)`;
    opts.options.forEach((o, i) => {
      buttons[i].style.color =
        o.value === current ? "var(--ink-900)" : "var(--ink-500)";
    });
  };

  opts.options.forEach((o) => {
    const btn = h(
      "button",
      {
        type: "button",
        onClick: () => {
          current = o.value;
          moveThumb();
          opts.onChange?.(o.value);
        },
        style: {
          position: "relative",
          zIndex: 1,
          display: "inline-flex",
          alignItems: "center",
          justifyContent: "center",
          gap: 6,
          minWidth: o.icon && !o.label ? height - pad * 2 : 56,
          padding: "0 14px",
          border: "none",
          background: "transparent",
          cursor: "pointer",
          fontFamily: "var(--font-ui)",
          fontSize: "var(--fs-sm)",
          fontWeight: "var(--fw-semibold)",
          color: o.value === current ? "var(--ink-900)" : "var(--ink-500)",
          transition: "color var(--dur-fast) var(--ease-out)",
        },
      },
      o.icon ? icon(o.icon, { size: 17 }) : null,
      o.label ?? null,
    );
    buttons.push(btn);
  });

  const root = h(
    "div",
    {
      style: {
        position: "relative",
        display: "inline-flex",
        height,
        padding: pad,
        background: "var(--ink-100)",
        borderRadius: "var(--radius-pill)",
      },
    },
    thumb,
    ...buttons,
  );
  // Defer initial thumb placement until the node has a measured width.
  requestAnimationFrame(moveThumb);
  return root;
}

// ---------------------------------------------------------------- Badge

type Tone = "neutral" | "sky" | "success" | "magenta" | "ink" | "glass";
const TONES: Record<Tone, Style> = {
  neutral: { background: "var(--ink-100)", color: "var(--ink-700)" },
  sky: { background: "var(--kin-sky)", color: "var(--clan-primary-800)" },
  success: {
    background: "color-mix(in srgb, var(--clan-success-500) 16%, #fff)",
    color: "var(--clan-success-600)",
  },
  magenta: { background: "#f9eaf4", color: "var(--clan-error-600)" },
  ink: { background: "var(--ink-900)", color: "#fff" },
  glass: {
    background: "rgba(255,255,255,0.72)",
    color: "var(--ink-700)",
    backdropFilter: "blur(8px)",
  },
};

export function Badge(opts: {
  label: string;
  tone?: Tone;
  dot?: boolean;
  size?: "sm" | "md";
  style?: Style;
}): HTMLElement {
  const small = opts.size === "sm";
  return h(
    "span",
    {
      style: {
        display: "inline-flex",
        alignItems: "center",
        gap: 6,
        height: small ? 20 : 24,
        padding: small ? "0 8px" : "0 10px",
        fontFamily: "var(--font-ui)",
        fontSize: small ? "var(--fs-2xs)" : "var(--fs-xs)",
        fontWeight: "var(--fw-semibold)",
        lineHeight: "1",
        whiteSpace: "nowrap",
        borderRadius: "var(--radius-pill)",
        ...TONES[opts.tone ?? "neutral"],
        ...opts.style,
      },
    },
    opts.dot
      ? h("span", {
          style: {
            width: 6,
            height: 6,
            borderRadius: "50%",
            background: "currentColor",
            flex: "0 0 auto",
          },
        })
      : null,
    opts.label,
  );
}

// ---------------------------------------------------------------- Avatar

const AV_SIZE: Record<string, number> = {
  xs: 24,
  sm: 32,
  md: 40,
  lg: 48,
  xl: 64,
};

export function Avatar(opts: {
  src?: string;
  name?: string;
  size?: number | keyof typeof AV_SIZE;
  status?: "online" | "busy" | "offline";
  ring?: boolean;
  style?: Style;
}): HTMLElement {
  const dim =
    typeof opts.size === "number" ? opts.size : AV_SIZE[opts.size ?? "md"];
  const name = opts.name ?? "";
  const initial = (name.trim()[0] || "?").toUpperCase();
  const dot = Math.max(8, Math.round(dim * 0.26));
  const inner = h(
    "span",
    {
      style: {
        display: "flex",
        alignItems: "center",
        justifyContent: "center",
        width: "100%",
        height: "100%",
        borderRadius: "50%",
        overflow: "hidden",
        background: opts.src ? "var(--ink-100)" : "var(--clan-secondary-300)",
        color: "#fff",
        fontFamily: "var(--font-ui)",
        fontWeight: "var(--fw-semibold)",
        fontSize: dim * 0.4,
        boxShadow: opts.ring
          ? "0 0 0 2px #fff, 0 0 0 4px var(--clan-info-500)"
          : "var(--ring-hairline)",
      },
    },
    opts.src
      ? h("img", {
          src: opts.src,
          alt: name,
          style: { width: "100%", height: "100%", objectFit: "cover" },
        })
      : initial,
  );
  return h(
    "span",
    {
      style: {
        position: "relative",
        display: "inline-block",
        width: dim,
        height: dim,
        flex: "0 0 auto",
        ...opts.style,
      },
    },
    inner,
    opts.status
      ? h("span", {
          style: {
            position: "absolute",
            right: -1,
            bottom: -1,
            width: dot,
            height: dot,
            borderRadius: "50%",
            background:
              opts.status === "online"
                ? "var(--clan-success-500)"
                : opts.status === "busy"
                  ? "var(--clan-error-500)"
                  : "var(--ink-400)",
            boxShadow: "0 0 0 2px #fff",
          },
        })
      : null,
  );
}

// ---------------------------------------------------------------- ArloOrb

const ORB_SIZE: Record<string, number> = { sm: 28, md: 40, lg: 56, xl: 96 };

export function ArloOrb(opts: {
  src?: string;
  size?: number | keyof typeof ORB_SIZE;
  pulse?: boolean;
  style?: Style;
}): HTMLElement {
  const dim =
    typeof opts.size === "number" ? opts.size : ORB_SIZE[opts.size ?? "md"];
  const root = h(
    "span",
    {
      style: {
        position: "relative",
        display: "inline-flex",
        alignItems: "center",
        justifyContent: "center",
        width: dim,
        height: dim,
        borderRadius: "50%",
        flex: "0 0 auto",
        background: opts.src ? "var(--ink-50)" : "var(--grad-arlo)",
        boxShadow: opts.src
          ? "var(--ring-hairline)"
          : "0 2px 10px rgba(149,55,255,0.35)",
        overflow: "hidden",
        ...opts.style,
      },
    },
    opts.src
      ? h("img", {
          src: opts.src,
          alt: "Arlo",
          style: { width: "86%", height: "86%", objectFit: "contain" },
        })
      : h("span", {
          style: {
            width: dim * 0.32,
            height: dim * 0.32,
            borderRadius: "50%",
            background:
              "radial-gradient(circle at 38% 34%, #fff 0%, #bfeaff 38%, #ff9fd0 78%)",
            boxShadow: `0 0 0 ${Math.max(2, dim * 0.06)}px rgba(255,255,255,0.35)`,
          },
        }),
  );
  if (opts.pulse) {
    ensureKeyframes();
    root.appendChild(
      h("span", {
        style: {
          position: "absolute",
          inset: 0,
          borderRadius: "50%",
          animation: "kin-arlo-pulse 1.8s var(--ease-out) infinite",
        },
      }),
    );
  }
  return root;
}

// ---------------------------------------------------------------- SidebarItem

export function SidebarItem(opts: {
  icon?: string;
  label: string;
  selected?: boolean;
  count?: number;
  onClick?: () => void;
}): HTMLButtonElement {
  const sel = !!opts.selected;
  const btn = h(
    "button",
    {
      type: "button",
      onClick: opts.onClick,
      style: {
        display: "flex",
        alignItems: "center",
        gap: 12,
        width: "100%",
        height: 40,
        padding: "0 12px",
        border: "none",
        cursor: "pointer",
        borderRadius: "var(--radius-md)",
        textAlign: "left",
        background: sel ? "var(--ink-100)" : "transparent",
        color: sel ? "var(--ink-900)" : "var(--ink-500)",
        fontFamily: "var(--font-ui)",
        fontSize: "var(--fs-sm)",
        fontWeight: sel ? "var(--fw-semibold)" : "var(--fw-medium)",
        transition:
          "background var(--dur-fast) var(--ease-out), color var(--dur-fast) var(--ease-out)",
      },
    },
    opts.icon
      ? icon(opts.icon, {
          size: 19,
          color: sel ? "var(--ink-900)" : "var(--ink-400)",
        })
      : null,
    h(
      "span",
      {
        style: {
          flex: "1",
          minWidth: 0,
          overflow: "hidden",
          textOverflow: "ellipsis",
          whiteSpace: "nowrap",
        },
      },
      opts.label,
    ),
    opts.count != null
      ? h(
          "span",
          {
            style: {
              fontSize: "var(--fs-xs)",
              fontWeight: "var(--fw-medium)",
              color: "var(--ink-400)",
            },
          },
          String(opts.count),
        )
      : null,
  );
  if (!sel) {
    btn.addEventListener(
      "mouseenter",
      () => (btn.style.background = "var(--ink-50)"),
    );
    btn.addEventListener(
      "mouseleave",
      () => (btn.style.background = "transparent"),
    );
  }
  return btn;
}

// ---------------------------------------------------------------- FileTile

type Kind = "doc" | "image" | "audio" | "archive" | "folder";
const KIND_TINT: Record<Kind, { bg: string; icon: string; color: string }> = {
  doc: { bg: "#eef1f4", icon: "file", color: "#7d8a99" },
  image: { bg: "#eef1f4", icon: "file", color: "#7d8a99" },
  audio: { bg: "#f1eef4", icon: "file", color: "#9483a8" },
  archive: { bg: "#f4f0ea", icon: "file", color: "#a89674" },
  folder: {
    bg: "color-mix(in srgb, var(--kin-sky) 45%, #fff)",
    icon: "folder",
    color: "var(--clan-primary-700)",
  },
};

export function FileTile(opts: {
  name: string;
  meta?: string;
  kind?: Kind;
  thumb?: string;
  selected?: boolean;
  onClick?: () => void;
}): HTMLElement {
  const k = KIND_TINT[opts.kind ?? "doc"];
  const preview = h(
    "div",
    {
      style: {
        aspectRatio: "1 / 1",
        borderRadius: "var(--radius-lg)",
        overflow: "hidden",
        background: opts.thumb
          ? `center / cover no-repeat url("${opts.thumb}")`
          : k.bg,
        display: "flex",
        alignItems: "center",
        justifyContent: "center",
        boxShadow: opts.selected
          ? "0 0 0 2px #fff, 0 0 0 4px var(--clan-info-500)"
          : "var(--ring-hairline)",
        transition:
          "box-shadow var(--dur-base) var(--ease-out), transform var(--dur-base) var(--ease-out)",
      },
    },
    opts.thumb
      ? null
      : icon(k.icon, { size: 44, strokeWidth: 1.4, color: k.color }),
  );
  const tile = h(
    "div",
    { style: { width: "100%", cursor: "pointer" }, onClick: opts.onClick },
    preview,
    h(
      "div",
      {
        style: { display: "flex", alignItems: "center", gap: 8, marginTop: 12 },
      },
      opts.kind === "folder"
        ? icon("folder", { size: 18, color: "var(--clan-secondary-400)" })
        : null,
      h(
        "div",
        { style: { minWidth: 0 } },
        h(
          "div",
          {
            style: {
              fontFamily: "var(--font-ui)",
              fontSize: "var(--fs-sm)",
              fontWeight: "var(--fw-semibold)",
              color: "var(--ink-900)",
              overflow: "hidden",
              textOverflow: "ellipsis",
              whiteSpace: "nowrap",
            },
          },
          opts.name,
        ),
        opts.meta
          ? h(
              "div",
              {
                style: {
                  fontFamily: "var(--font-ui)",
                  fontSize: "var(--fs-xs)",
                  color: "var(--ink-400)",
                  marginTop: 2,
                },
              },
              opts.meta,
            )
          : null,
      ),
    ),
  );
  if (!opts.selected) {
    tile.addEventListener("mouseenter", () => {
      preview.style.boxShadow = "var(--shadow-md)";
      preview.style.transform = "translateY(-2px)";
    });
    tile.addEventListener("mouseleave", () => {
      preview.style.boxShadow = "var(--ring-hairline)";
      preview.style.transform = "none";
    });
  }
  return tile;
}
