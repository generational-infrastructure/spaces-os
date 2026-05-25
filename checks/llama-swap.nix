# NixOS VM test for the llama-swap module.
#
# Verifies that llama-swap starts, loads models from the Nix store,
# and responds to OpenAI-compatible API requests with expected output.
#
# Extends the module's default models with SmolLM-135M for fast testing.
# Tests both qwen2.5:0.5b (default) and smollm completions.
#
# x86_64-linux only: pkgs.testers.nixosTest requires a builder with
# the `kvm` + `nixos-test` features, which the aarch64 CI worker does
# not currently advertise. On other systems we ship a trivial stub so
# `nix flake check` stays green.
{ pkgs, inputs, ... }:

if pkgs.stdenv.hostPlatform.system != "x86_64-linux" then
  pkgs.runCommand "llama-swap-x86_64-only" { } "mkdir -p $out"
else

  let
    inherit (pkgs) lib;

    smollm-gguf = pkgs.fetchurl {
      url = "https://huggingface.co/QuantFactory/SmolLM-135M-GGUF/resolve/main/SmolLM-135M.Q2_K.gguf";
      hash = "sha256-DX46drPNJILNba21xfY2tyE0/yPWgOhz43gJdeSYKh4=";
    };

    port = 8012;
  in
  pkgs.testers.nixosTest {
    name = "llama-swap";

    nodes.machine =
      { config, ... }:
      let
        llama-server = lib.getExe' config.services.llama-swap.llama-server-package "llama-server";
      in
      {
        imports = [ inputs.self.nixosModules.llama-swap ];

        services.llama-swap = {
          enable = true;
          # Extend default models with a small test model
          settings.models."smollm" = {
            cmd = "${llama-server} -m ${smollm-gguf} --port \${PORT} --no-webui";
          };
        };

        # No DHCP — faster boot
        networking.dhcpcd.enable = false;

        virtualisation = {
          memorySize = 8192;
          cores = 4;
        };
      };

    testScript = ''
      import json

      machine.wait_for_unit("llama-swap.service")
      machine.wait_for_open_port(${toString port})

      # Verify both default and test models are listed
      result = machine.succeed("curl -sf http://127.0.0.1:${toString port}/v1/models")
      models = json.loads(result)
      model_ids = [m["id"] for m in models["data"]]
      assert "qwen2.5:0.5b" in model_ids, f"qwen2.5:0.5b not in {model_ids}"
      assert "smollm" in model_ids, f"smollm not in {model_ids}"

      # Query smollm — fast, deterministic
      result = machine.succeed(
        "curl -sf --max-time 120 http://127.0.0.1:${toString port}/v1/completions "
        + "-H 'Content-Type: application/json' "
        + "-d '{\"model\": \"smollm\", \"prompt\": \"The sky is\", \"max_tokens\": 10, \"temperature\": 0, \"seed\": 42}'"
      )
      response = json.loads(result)
      assert "choices" in response, f"No choices in smollm response: {response}"
      text = response["choices"][0]["text"]
      assert "blue" in text.lower(), f"Expected 'blue' in smollm output, got: {text}"

      # Query qwen2.5:0.5b — the default production model
      result = machine.succeed(
        "curl -sf --max-time 600 http://127.0.0.1:${toString port}/v1/completions "
        + "-H 'Content-Type: application/json' "
        + "-d '{\"model\": \"qwen2.5:0.5b\", \"prompt\": \"The sky is\", \"max_tokens\": 5, \"temperature\": 0, \"seed\": 42}'"
      )
      response = json.loads(result)
      assert "choices" in response, f"No choices in gemma4 response: {response}"
      text = response["choices"][0]["text"]
      assert len(text) > 0, f"Empty text from gemma4: {response}"
    '';
  }
