// Spaces OS — Files app UI kit (vanilla-TS port of FilesApp.jsx).
//
// A Finder-style file browser: left rail, search/create top bar, and
// sectioned tiles (Recents / Shared / Favourites) with grid|list views.
// Type in search to filter live; toggle grid↔list. Composes the ported
// design-system primitives from ../lib.

import { h, setChildren } from "../lib/dom";
import { icon } from "../lib/icon";
import {
  Button,
  FileTile,
  Input,
  SegmentedControl,
  SidebarItem,
} from "../lib/components";

type Kind = "doc" | "image" | "audio" | "archive" | "folder";
interface FileItem {
  name: string;
  meta: string;
  kind: Kind;
}

const RECENTS: FileItem[] = [
  { name: "Project Ideas.md", meta: "Just now", kind: "doc" },
  { name: "Backcountry.PDF", meta: "Yesterday", kind: "doc" },
  { name: "Furano photos", meta: "Folder · Photos", kind: "folder" },
  { name: "Application form", meta: "Added 10 days ago", kind: "doc" },
  { name: "Dog posse", meta: "Added 10 days ago", kind: "image" },
  { name: "Numazu Club", meta: "Added 2 weeks ago", kind: "image" },
];
const SHARED: FileItem[] = [
  { name: "Create_Space_N", meta: "Mov · Thursday", kind: "doc" },
  { name: "Founders Grotesk", meta: "Folder · Fonts", kind: "folder" },
  { name: "Publico Banner", meta: "Folder · Fonts", kind: "folder" },
  { name: "Widgets_flow.mov", meta: "Thursday", kind: "doc" },
  { name: "Identity Guidelines", meta: "Sep 12", kind: "doc" },
  { name: "River render", meta: "Sep 10", kind: "image" },
];
const FAVES: FileItem[] = [
  { name: "Car research", meta: "Folder · Personal", kind: "folder" },
  { name: "Rough cut 02", meta: "MP3 · Aug 2", kind: "audio" },
  { name: "Sharp Sans", meta: "Folder · Fonts", kind: "folder" },
  { name: "Floor plan", meta: "PDF · Aug 6", kind: "doc" },
  { name: "Doc archive", meta: "ZIP · Aug 3", kind: "archive" },
  { name: "Alterations", meta: "PDF · Sep 3", kind: "doc" },
];

type View = "grid" | "list";
const state: { view: View; q: string } = { view: "grid", q: "" };

function Rail(): HTMLElement {
  let selected = "overview";
  let tab = "files";
  const nav: [string, string, string][] = [
    ["overview", "home", "Overview"],
    ["recents", "clock", "Recents"],
    ["clan", "users", "Clan"],
    ["fav", "star", "Favourites"],
    ["all", "folder", "All files"],
  ];
  const faveFolders: [string, string][] = [
    ["Car research", "folder"],
    ["Rough Soundtrack 02", "audio"],
    ["Sharp Sans", "folder"],
    ["Apartment floor plan", "doc"],
    ["Doc archive", "doc"],
  ];

  const navRows: HTMLElement[] = [];
  const tabButtons: HTMLButtonElement[] = [];
  const navBox = h("div", {
    style: { display: "flex", flexDirection: "column", gap: 2 },
  });

  const renderNav = () => {
    setChildren(
      navBox,
      nav.map(([id, ic, label]) =>
        SidebarItem({
          icon: ic,
          label,
          selected: selected === id,
          onClick: () => {
            selected = id;
            renderNav();
          },
        }),
      ),
    );
  };

  const tabBar = h(
    "div",
    { style: { display: "flex", gap: 22, padding: "0 8px", marginBottom: 22 } },
    ...["files", "apps"].map((id) => {
      const label = id === "files" ? "Files" : "Apps";
      const btn = h(
        "button",
        {
          onClick: () => {
            tab = id;
            tabButtons.forEach((b, i) => {
              const on = ["files", "apps"][i] === tab;
              b.style.color = on ? "var(--ink-900)" : "var(--ink-400)";
              b.style.borderBottom = on
                ? "2px solid var(--ink-900)"
                : "2px solid transparent";
            });
          },
          style: {
            border: "none",
            background: "transparent",
            padding: "0 0 8px",
            cursor: "pointer",
            fontFamily: "var(--font-ui)",
            fontSize: 18,
            fontWeight: 600,
            color: id === tab ? "var(--ink-900)" : "var(--ink-400)",
            borderBottom:
              id === tab ? "2px solid var(--ink-900)" : "2px solid transparent",
          },
        },
        label,
      );
      tabButtons.push(btn);
      return btn;
    }),
  );

  renderNav();
  navRows.push(navBox);

  return h(
    "aside",
    {
      style: {
        width: 248,
        flex: "0 0 auto",
        padding: "22px 16px",
        display: "flex",
        flexDirection: "column",
        height: "100%",
        boxSizing: "border-box",
        background: "var(--clan-secondary-50)",
      },
    },
    tabBar,
    navBox,
    h(
      "div",
      {
        style: {
          marginTop: 22,
          padding: "0 12px 8px",
          fontSize: 11,
          fontWeight: 700,
          letterSpacing: "0.04em",
          textTransform: "uppercase",
          color: "var(--ink-400)",
        },
      },
      "Favourites",
    ),
    h(
      "div",
      { style: { display: "flex", flexDirection: "column", gap: 1 } },
      ...faveFolders.map(([label, kind]) =>
        h(
          "div",
          {
            style: {
              display: "flex",
              alignItems: "center",
              gap: 10,
              height: 32,
              padding: "0 12px",
              borderRadius: "var(--radius-sm)",
              cursor: "pointer",
            },
          },
          icon(kind === "folder" ? "folder" : "file", {
            size: 17,
            color:
              kind === "folder"
                ? "var(--clan-secondary-400)"
                : "var(--ink-400)",
          }),
          h(
            "span",
            {
              style: {
                fontFamily: "var(--font-ui)",
                fontSize: 13,
                color: "var(--ink-700)",
                overflow: "hidden",
                textOverflow: "ellipsis",
                whiteSpace: "nowrap",
              },
            },
            label,
          ),
        ),
      ),
    ),
    h(
      "div",
      {
        style: {
          marginTop: "auto",
          display: "flex",
          alignItems: "center",
          gap: 10,
          padding: "0 12px",
          height: 40,
          color: "var(--ink-500)",
        },
      },
      icon("trash", { size: 18 }),
      h(
        "span",
        { style: { fontFamily: "var(--font-ui)", fontSize: 13 } },
        "Bin",
      ),
    ),
  );
}

function Section(title: string, items: FileItem[]): HTMLElement | null {
  const q = state.q.toLowerCase();
  const filtered = items.filter((f) => f.name.toLowerCase().includes(q));
  if (!filtered.length) return null;

  const body =
    state.view === "grid"
      ? h(
          "div",
          {
            style: {
              display: "grid",
              gridTemplateColumns: "repeat(6, 1fr)",
              gap: 20,
            },
          },
          ...filtered.map((f) =>
            FileTile({ name: f.name, meta: f.meta, kind: f.kind }),
          ),
        )
      : h(
          "div",
          { style: { display: "flex", flexDirection: "column" } },
          ...filtered.map((f, i) =>
            h(
              "div",
              {
                style: {
                  display: "flex",
                  alignItems: "center",
                  gap: 12,
                  padding: "10px 8px",
                  borderTop: i ? "1px solid var(--ink-100)" : "none",
                },
              },
              icon(f.kind === "folder" ? "folder" : "file", {
                size: 20,
                color:
                  f.kind === "folder"
                    ? "var(--clan-secondary-400)"
                    : "var(--ink-400)",
              }),
              h(
                "span",
                {
                  style: {
                    flex: "1",
                    fontFamily: "var(--font-ui)",
                    fontSize: 14,
                    fontWeight: 500,
                    color: "var(--ink-900)",
                  },
                },
                f.name,
              ),
              h(
                "span",
                {
                  style: {
                    fontFamily: "var(--font-ui)",
                    fontSize: 13,
                    color: "var(--ink-400)",
                  },
                },
                f.meta,
              ),
            ),
          ),
        );

  return h(
    "div",
    { style: { marginBottom: 38 } },
    h(
      "div",
      {
        style: {
          display: "flex",
          alignItems: "baseline",
          justifyContent: "space-between",
          marginBottom: 18,
        },
      },
      h(
        "h2",
        {
          style: {
            margin: 0,
            fontFamily: "var(--font-ui)",
            fontSize: 20,
            fontWeight: 600,
            color: "var(--ink-900)",
          },
        },
        title,
      ),
      h(
        "button",
        {
          style: {
            border: "none",
            background: "transparent",
            cursor: "pointer",
            fontFamily: "var(--font-ui)",
            fontSize: 13,
            color: "var(--ink-400)",
          },
        },
        "View all",
      ),
    ),
    body,
  );
}

function renderContent(container: HTMLElement): void {
  const sections = [
    Section("Recents", RECENTS),
    Section("Shared", SHARED),
    Section("Favourites", FAVES),
  ].filter((s): s is HTMLElement => s != null);
  setChildren(container, sections);
}

function FilesApp(): HTMLElement {
  const content = h("div", {
    style: { flex: "1", overflowY: "auto", padding: "12px 32px 40px" },
  });

  const search = Input({
    iconLeft: "search",
    placeholder: "Search all your files",
    size: "lg",
    onInput: (v) => {
      state.q = v;
      renderContent(content);
    },
  });

  const header = h(
    "header",
    {
      style: {
        display: "flex",
        alignItems: "center",
        gap: 16,
        padding: "20px 32px",
        flex: "0 0 auto",
      },
    },
    h("div", { style: { flex: "1", maxWidth: 1100 } }, search.el),
    Button({
      label: "Create",
      intent: "secondary",
      size: "lg",
      iconLeft: "plus",
    }),
    SegmentedControl({
      value: state.view,
      onChange: (v) => {
        state.view = v as View;
        renderContent(content);
      },
      options: [
        { value: "grid", icon: "grid" },
        { value: "list", icon: "list" },
      ],
    }),
  );

  renderContent(content);

  return h(
    "div",
    {
      style: {
        display: "flex",
        height: "100vh",
        background: "#fff",
        overflow: "hidden",
      },
    },
    Rail(),
    h(
      "main",
      {
        style: {
          flex: "1",
          minWidth: 0,
          display: "flex",
          flexDirection: "column",
        },
      },
      header,
      content,
    ),
  );
}

document.getElementById("root")!.appendChild(FilesApp());
