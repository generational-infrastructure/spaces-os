// Tiny DOM helper for the Spaces OS UI kits.
//
// The design system ships its primitives as React/JSX with inline style
// objects. These kits are a zero-dependency vanilla-TS translation (same
// ethos as packages/pi-web), so `h()` is a minimal hyperscript that takes
// the same camelCase style objects and writes them onto real DOM nodes.

export type Style = Record<string, string | number | undefined>;

type Props = {
  style?: Style;
  class?: string;
  // Event handlers: onClick, onInput, onKeyDown, … (camelCase after "on").
  [key: string]: unknown;
};

type Child = Node | string | number | null | undefined | false;

const SVG_NS = "http://www.w3.org/2000/svg";
// Properties that take a raw number with no `px` unit (mirrors React's set).
const UNITLESS = new Set([
  "opacity",
  "z-index",
  "font-weight",
  "flex",
  "flex-grow",
  "flex-shrink",
  "line-height",
  "order",
  "zoom",
]);

function kebab(key: string): string {
  return key.startsWith("--")
    ? key
    : key.replace(/[A-Z]/g, (m) => `-${m.toLowerCase()}`);
}

/** Apply a camelCase style object to a node, appending `px` to bare lengths. */
export function applyStyle(
  node: { style: CSSStyleDeclaration },
  style: Style,
): void {
  for (const [rawKey, value] of Object.entries(style)) {
    if (value == null) continue;
    const key = kebab(rawKey);
    const out =
      typeof value === "number" && !UNITLESS.has(key)
        ? `${value}px`
        : String(value);
    node.style.setProperty(key, out);
  }
}

export function h<K extends keyof HTMLElementTagNameMap>(
  tag: K,
  props?: Props | null,
  ...children: Child[]
): HTMLElementTagNameMap[K] {
  const node = document.createElement(tag);
  applyProps(node, props);
  appendAll(node, children);
  return node;
}

/** SVG-namespaced element factory (icons set their own children via innerHTML). */
export function svg(tag: string, props?: Props | null): SVGElement {
  const node = document.createElementNS(SVG_NS, tag);
  if (props) {
    for (const [key, value] of Object.entries(props)) {
      if (value == null) continue;
      if (key === "style")
        applyStyle(
          node as unknown as { style: CSSStyleDeclaration },
          value as Style,
        );
      else node.setAttribute(kebab(key), String(value));
    }
  }
  return node;
}

function applyProps(node: HTMLElement, props?: Props | null): void {
  if (!props) return;
  for (const [key, value] of Object.entries(props)) {
    if (value == null) continue;
    if (key === "style") applyStyle(node, value as Style);
    else if (key === "class") node.className = String(value);
    else if (key.startsWith("on") && typeof value === "function") {
      node.addEventListener(key.slice(2).toLowerCase(), value as EventListener);
    } else if (key === "value" && node instanceof HTMLInputElement) {
      node.value = String(value);
    } else {
      node.setAttribute(key, String(value));
    }
  }
}

function appendAll(node: Node, children: Child[]): void {
  for (const child of children) {
    if (child == null || child === false) continue;
    node.appendChild(
      typeof child === "string" || typeof child === "number"
        ? document.createTextNode(String(child))
        : child,
    );
  }
}

/** Replace a node's children in one shot. */
export function setChildren(node: Node, children: Child[]): void {
  while (node.firstChild) node.removeChild(node.firstChild);
  appendAll(node, children);
}
