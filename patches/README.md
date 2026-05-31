# Niri patches

## `niri-allow-software-rendering.patch`

Applied in test-support/. Lets niri render under llvmpipe in VM tests.

## `niri-per-permission-gating.patch.draft`

**Status: design draft — hunk headers need repair before this can be
applied.** The substance of every change is correct (verified against
the upstream `client_is_unrestricted` filter sites at niri commit-time);
only the unified-diff hunk arithmetic is off. Regenerating with `git
diff` against an edited working copy is the cleanest path.

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

### Verifying

When the patch lands and the patched niri is wired through
test-support, `checks/apps-coordinator-wayland.nix` should be extended
with:
- `probe-virtual-keyboard` app: `permissions.granted = [ "wayland" "wayland.virtual-keyboard" ]`. wayland-info should see `zwp_virtual_keyboard_manager_v1`.
- A sibling without that permission. wayland-info should NOT see it.

The existing `waylandSandbox = false` opt-out becomes obsolete and
voxtype-daemon can switch from it to a clean
`permissions.granted += [ "wayland.virtual-keyboard" ]`.
