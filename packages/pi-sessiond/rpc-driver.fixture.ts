// Stub `pi --mode rpc` child for the RpcDriver unit test.
//
// Speaks pi's JSON-line protocol on stdio so the test exercises the real
// transport without a model or network: it correlates command responses by
// id, streams events around a prompt, and drives one extension_ui round-trip.
function emit(obj: Record<string, unknown>): void {
  process.stdout.write(`${JSON.stringify(obj)}\n`);
}

function handle(cmd: Record<string, unknown>): void {
  const id = typeof cmd.id === "string" ? cmd.id : undefined;
  switch (cmd.type) {
    case "get_state":
      emit({
        type: "response",
        command: "get_state",
        id,
        success: true,
        data: {
          model: { provider: "local", id: "m1" },
          messageCount: 0,
          isStreaming: false,
        },
      });
      return;
    case "prompt":
      // Stream an event, ack the command, then either finish or park on a
      // side-channel request that the driver must round-trip.
      emit({ type: "agent_start" });
      emit({ type: "response", command: "prompt", id, success: true });
      if (cmd.message === "ask") {
        emit({
          type: "extension_ui_request",
          id: "ui-1",
          method: "confirm",
          title: "t",
          message: "m",
        });
        return;
      }
      emit({ type: "agent_end" });
      return;
    case "extension_ui_response":
      emit({ type: "confirmed", value: cmd.confirmed === true });
      emit({ type: "agent_end" });
      return;
    case "abort":
      emit({ type: "response", command: "abort", id, success: true });
      return;
  }
}

let buf = "";
process.stdin.on("data", (chunk: Buffer) => {
  buf += chunk.toString("utf8");
  let nl = buf.indexOf("\n");
  while (nl !== -1) {
    const line = buf.slice(0, nl);
    buf = buf.slice(nl + 1);
    if (line.length > 0) {
      try {
        handle(JSON.parse(line) as Record<string, unknown>);
      } catch {
        // ignore malformed lines, like the real protocol reader
      }
    }
    nl = buf.indexOf("\n");
  }
});
