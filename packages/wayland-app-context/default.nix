{ pkgs, ... }:
pkgs.stdenv.mkDerivation {
  pname = "wayland-app-context";
  version = "0.1.0";
  src = ./.;

  nativeBuildInputs = [
    pkgs.wayland-scanner
    pkgs.pkg-config
  ];

  buildInputs = [
    pkgs.wayland
    pkgs.wayland-protocols
  ];

  buildPhase = ''
    runHook preBuild
    proto=${pkgs.wayland-protocols}/share/wayland-protocols/staging/security-context/security-context-v1.xml
    wayland-scanner client-header "$proto" security-context-v1-client-protocol.h
    wayland-scanner private-code  "$proto" security-context-v1-protocol.c
    $CC -O2 -Wall -Wextra -pedantic \
      wayland-app-context.c security-context-v1-protocol.c \
      $(pkg-config --cflags --libs wayland-client) \
      -o wayland-app-context
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm755 wayland-app-context $out/bin/wayland-app-context
    runHook postInstall
  '';

  meta.mainProgram = "wayland-app-context";
}
