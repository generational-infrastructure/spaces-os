# Niri patches

## `niri-allow-software-rendering.patch`

Applied in test-support/. Lets niri render under llvmpipe in VM tests.

## `niri-per-permission-gating.patch`

**Status: applies cleanly and compiles against niri 25.11** (verified
with `nix build` of `pkgs.niri` + this patch). Not yet wired into the
production niri package — activate it by overriding
`programs.niri.package` with a niri built from this patch (see
"Activating" below). Doing so rebuilds niri from source.

### What the patch does

Replaces niri's single binary `client_is_unrestricted` filter for
restricted Wayland protocols with per-permission gating keyed on
the app-id from the security-context-v1 handshake.

Granular permission names this patch wires:

| Permission | Protocol it controls |
|---|---|
| `wayland.layer-shell` | `zwlr_layer_shell_v1` |
| `wayland.session-lock` | `ext_session_lock_manager_v1` |
| `wayland.data-control` | `zwlr_data_control_manager_v1`, `ext_data_control_manager_v1` |
| `wayland.input-method` | `zwp_input_method_manager_v2` |
| `wayland.virtual-keyboard` | `zwp_virtual_keyboard_manager_v1` |
| `wayland.virtual-pointer` | `zwlr_virtual_pointer_manager_v1` |
| `wayland.foreign-toplevel-management` | `zwlr_foreign_toplevel_manager_v1`, `ext_foreign_toplevel_list_v1` |
| `wayland.ext-workspace` | `ext_workspace_manager_v1` |
| `wayland.output-management` | `zwlr_output_manager_v1` |
| `wayland.screen-capture` | `zwlr_screencopy_manager_v1` |

`wp_security_context_manager_v1` itself stays binary-gated — sandboxed
clients must never nest their own sandboxes.

### Map file format

Niri reads the map from `$NIRI_PERMISSION_MAP` at startup (default
`/etc/spaces/wayland-permissions.txt`):

```
# Lines: "<app-id> <permission>"; blanks and # comments ignored.
spaces.app.voxtype-daemon wayland.virtual-keyboard
spaces.app.screen-recorder wayland.screen-capture
spaces.app.bar wayland.layer-shell
```

The `lib/apps-launcher.nix` permission catalogue lists these names,
and `modules/nixos/apps.nix` generates the file from
`services.spaces.apps.<name>.permissions.granted` entries that match
`wayland.*` — both already done; the patched niri is the missing
consumer.

### Activating

Override the compositor package with a niri built from this patch, e.g.
in the niri module or a host config:

```nix
programs.niri.package = pkgs.niri.overrideAttrs (o: {
  patches = (o.patches or [ ]) ++ [ ../../patches/niri-per-permission-gating.patch ];
});
```

With no map entries the behaviour is identical to today's binary gating
(restricted clients are denied every `wayland.*` global); entries in the
map grant per-app, per-permission access. Wiring is opt-in because it
forces a niri source rebuild for the whole bundle.

### Verifying

When the patched niri is wired through test-support,
`checks/apps-coordinator-wayland.nix` should be extended with:
- `probe-virtual-keyboard` app: `permissions.granted = [ "wayland" "wayland.virtual-keyboard" ]`. wayland-info should see `zwp_virtual_keyboard_manager_v1`.
- A sibling without that permission. wayland-info should NOT see it.

The existing `waylandSandbox = false` opt-out becomes obsolete and
voxtype-daemon can switch from it to a clean
`permissions.granted += [ "wayland.virtual-keyboard" ]`.
