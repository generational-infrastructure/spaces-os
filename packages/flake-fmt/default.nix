# `nix fmt` wrapper that caches the flake's formatter.
{ pkgs, ... }:
pkgs.rustPlatform.buildRustPackage {
  pname = "flake-fmt";
  version = "1.0.0-unstable-2026-07-09";

  src = pkgs.fetchFromGitHub {
    owner = "Mic92";
    repo = "flake-fmt";
    rev = "f46dd93676214f5756c8dcf9ece2584fd7f23f50";
    hash = "sha256-zpyrja8s+hmANNpoKb6ffm3HZWjgNCa8OVXtJFCYm5o=";
  };
  cargoHash = "sha256-4B/cReUkeFlep4tc/G6z0PnTlWAOPq4EbTwI8YMwDUE=";

  nativeBuildInputs = [ pkgs.makeWrapper ];

  # buildRustPackage installs binaries but skips cdylibs; the trace shim is
  # loaded at runtime by flake-fmt, so install it and point the wrapper at it.
  postInstall = ''
    install -Dm0644 \
      target/${pkgs.stdenv.hostPlatform.rust.cargoShortTarget}/release/libflake_fmt_trace.so \
      $out/lib/libflake_fmt_trace.so
  '';
  postFixup = ''
    wrapProgram $out/bin/flake-fmt \
      --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.nix ]} \
      --set-default FLAKE_FMT_TRACE_LIB $out/lib/libflake_fmt_trace.so
  '';

  meta = {
    description = "Smart formatter wrapper for Nix flakes with sound caching";
    homepage = "https://github.com/Mic92/flake-fmt";
    license = pkgs.lib.licenses.mit;
    mainProgram = "flake-fmt";
  };
}
