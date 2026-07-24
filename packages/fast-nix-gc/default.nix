# Faster nix-collect-garbage / nix-store --optimise.
{ pkgs, ... }:
pkgs.rustPlatform.buildRustPackage {
  pname = "fast-nix-gc";
  version = "0.1.0-unstable-2026-07-23";

  src = pkgs.fetchFromGitHub {
    owner = "Mic92";
    repo = "fast-nix-gc";
    rev = "a5cd404ecb18f02ee4e2e596e12c7246ba815746";
    hash = "sha256-O5AwBmirtLacHe/BW1IBxJxnXz5wOQGT8G5yufyR57E=";
  };
  cargoHash = "sha256-WPXREVL3jm6npGfTGoX7SVblzo7rYOo+taTCelB9CGI=";

  nativeBuildInputs = [ pkgs.pkg-config ];
  buildInputs = [ pkgs.sqlite ];

  cargoBuildFlags = [
    "-p"
    "fast-nix-gc"
    "-p"
    "fast-nix-optimise"
  ];
  cargoTestFlags = [
    "-p"
    "fast-nix-gc"
    "-p"
    "fast-nix-common"
    "-p"
    "fast-nix-optimise"
  ];

  meta = {
    description = "Faster nix-collect-garbage and nix-store --optimise";
    homepage = "https://github.com/Mic92/fast-nix-gc";
    license = pkgs.lib.licenses.mit;
    mainProgram = "fast-nix-gc";
  };
}
