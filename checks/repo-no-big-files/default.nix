# Fails when media files (raster images, video, audio) or any file
# larger than 100 KiB lands in the repo tree. The flake source
# (inputs.self) only contains tracked, non-gitignored files, so this
# pins exactly what a clone ships.
#
# Media files are never acceptable regardless of size — binary blobs
# belong in a fetcher/LFS, not the tree. Oversized text files can be
# grandfathered via sizeAllowlist, but new entries should be rare and
# deliberate.
{ pkgs, inputs, ... }:
let
  # Paths (relative to the repo root) permitted to exceed the size cap.
  sizeAllowlist = [
    # grandfathered oversized text files — do not add binaries here
    "packages/voxtype-tuner/tests/test_app.py"
    "packages/voxtype-tuner/ui/app.slint"
  ];

  maxBytes = 102400; # 100 KiB

  mediaGlobs = [
    # raster images
    "*.png"
    "*.jpg"
    "*.jpeg"
    "*.gif"
    "*.webp"
    "*.bmp"
    "*.tif"
    "*.tiff"
    "*.ico"
    "*.icns"
    # video
    "*.mp4"
    "*.webm"
    "*.mov"
    "*.avi"
    "*.mkv"
    "*.m4v"
    # audio
    "*.mp3"
    "*.wav"
    "*.ogg"
    "*.oga"
    "*.opus"
    "*.flac"
    "*.m4a"
    "*.aac"
  ];

  mediaFindArgs = pkgs.lib.concatStringsSep " -o " (
    map (g: "-iname ${pkgs.lib.escapeShellArg g}") mediaGlobs
  );
in
pkgs.runCommand "repo-no-big-files-test"
  {
    allowlist = pkgs.lib.concatMapStrings (p: p + "\n") sizeAllowlist;
    passAsFile = [ "allowlist" ];
  }
  ''
    cd ${inputs.self}

    violations=$(
      {
        find . -type f \( ${mediaFindArgs} \) -printf 'media\t-\t%P\n'
        find . -type f -size +${toString maxBytes}c -printf 'size\t%s bytes\t%P\n'
      } | sort -u | while IFS=$'\t' read -r kind detail path; do
        if [ "$kind" = size ] && grep -qxF "$path" "$allowlistPath"; then
          continue
        fi
        printf '%s\t%s\t%s\n' "$kind" "$detail" "$path"
      done
    )

    if [ -n "$violations" ]; then
      echo "repo contains media files or files larger than ${toString maxBytes} bytes:"
      echo "$violations" | tr '\t' ' '
      echo
      echo "Remove them from the tree (fetch binaries at build time instead)."
      echo "A legitimately oversized text file can be added to sizeAllowlist"
      echo "in checks/repo-no-big-files/default.nix."
      exit 1
    fi

    # every allowlist entry must still exist — no stale grandfathering
    while IFS= read -r p; do
      [ -z "$p" ] && continue
      [ -f "$p" ] || { echo "stale sizeAllowlist entry (file gone): $p"; exit 1; }
    done < "$allowlistPath"

    echo "no media files; all files <= ${toString maxBytes} bytes (allowlist: ${toString (builtins.length sizeAllowlist)} entries)"
    touch "$out"
  ''
