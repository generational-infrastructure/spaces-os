import { expect, test } from "bun:test";
import { mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { ConfirmRequest } from "./mcp-server";
import { runConfirm } from "./confirm";

const req: ConfirmRequest = {
  integration: "signal",
  tool: "send",
  toolName: "signal_send",
  args: { to: "bob" },
};

const write = (token: string) => [
  "sh",
  "-c",
  `printf %s ${token} > "$SPACES_CONFIRM_VERDICT_FILE"`,
];

test("returns the verdict the command writes to the verdict file", async () => {
  expect(await runConfirm(write("once"), req)).toBe("once");
  expect(await runConfirm(write("session"), req)).toBe("session");
  expect(await runConfirm(write("deny"), req)).toBe("deny");
});

test("tolerates surrounding whitespace/newlines in the verdict", async () => {
  expect(
    await runConfirm(
      ["sh", "-c", `printf '  session\\n' > "$SPACES_CONFIRM_VERDICT_FILE"`],
      req,
    ),
  ).toBe("session");
});

test("passes the request JSON to the command via SPACES_CONFIRM_REQUEST", async () => {
  const copy = join(mkdtempSync(join(tmpdir(), "confirm-")), "reqcopy.json");
  await runConfirm(
    [
      "sh",
      "-c",
      `printf %s "$SPACES_CONFIRM_REQUEST" > ${copy}; printf once > "$SPACES_CONFIRM_VERDICT_FILE"`,
    ],
    req,
  );
  expect(JSON.parse(readFileSync(copy, "utf8"))).toEqual(req);
});

test("fails closed to deny when the command writes an unknown token", async () => {
  expect(await runConfirm(write("maybe"), req)).toBe("deny");
});

test("fails closed to deny when the command writes nothing", async () => {
  expect(await runConfirm(["sh", "-c", "true"], req)).toBe("deny");
});

test("fails closed to deny on a non-zero exit even if a verdict was written", async () => {
  expect(
    await runConfirm(
      ["sh", "-c", `printf once > "$SPACES_CONFIRM_VERDICT_FILE"; exit 3`],
      req,
    ),
  ).toBe("deny");
});

test("fails closed to deny when no confirm command is configured", async () => {
  expect(await runConfirm([], req)).toBe("deny");
});

test("fails closed to deny when the command exceeds the timeout", async () => {
  expect(
    await runConfirm(
      ["sh", "-c", `sleep 5; printf once > "$SPACES_CONFIRM_VERDICT_FILE"`],
      req,
      { timeoutMs: 200 },
    ),
  ).toBe("deny");
});
