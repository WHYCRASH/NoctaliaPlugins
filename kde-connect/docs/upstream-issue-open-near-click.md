# Draft upstream issue for noctalia-dev/noctalia

Title: **`open_near_click` never takes effect for plugin panels — Luau `togglePanel` side effects drop the click anchor**

Verified on `v5.0.0-beta2-48-g4529cd3d65e6`.

## Summary

A `[[panel]]` in a plugin manifest can declare `open_near_click = true` (parsed in
`src/scripting/plugin_manifest.cpp:350`, resolved with user overrides in
`src/scripting/plugin_panel_shell.cpp:129-137`), and `PanelManager` honours it for
attached panels when the open request carries an anchor
(`src/shell/panel/panel_manager.cpp:868-869`):

```cpp
const bool useAnchorForAttached =
    request.hasAnchorPosition && openNearClickEnabled(m_activePanel, m_activePanelId, m_config);
```

However, a Luau plugin can only open its panel via `noctalia.togglePanel(id)`, which
becomes a `ScriptSideEffectKind::TogglePanel` side effect
(`src/scripting/luau_host.cpp:1684`) dispatched through the global hook installed in
`src/app/application_services.cpp:468`:

```cpp
m_scriptApi.setTogglePanelHook([this](const std::string& panelId) { m_panelManager.togglePanel(panelId); });
```

That is the single-arg overload (`src/shell/panel/panel_manager.cpp:1325`), which
builds a `PanelOpenRequest` without `hasAnchorPosition`. The anchor-carrying
per-widget `PanelToggleCallback` that `bar.cpp` wires for every bar widget
(`src/shell/bar/bar.cpp:2156-2186`, using `lastPointerSx/Sy`) is only reachable via
the C++ `Widget::requestPanelToggle(...)` path used by built-in widgets (e.g.
`tray_widget.cpp:561`) — `PluginWidget` never routes its runtime's TogglePanel side
effects through it (`PluginWidget::handleScriptResult`,
`src/shell/bar/widgets/plugin_widget.cpp:612`, only applies UI patches).

Net effect: for plugin panels, `open_near_click` (manifest default and the injected
`<entry>_open_near_click` user setting, including the "Near trigger" control in
Settings → Plugins → Panels) is dead config — the panel always opens centered on the
bar, no matter where the plugin's widget is or where the user clicked.

## Suggested fix

In `PluginWidget`, intercept `TogglePanel` side effects from its own
`ScriptRuntime` (or install a per-runtime toggle hook instead of relying on the
global one) and forward them through the widget's `requestPanelToggle(...)` /
`PanelToggleCallback`, so the request carries `lastPointerSx/Sy` +
`hasAnchorPosition = true` like built-in widgets. The control-center
`PluginShortcut` (`src/shell/control_center/plugin_shortcut.cpp`) could get the same
treatment for tile-anchored opening.

## Reproduction

1. Install any Luau plugin with a `[[panel]]` declaring `placement = "attached"`,
   `position = "auto"`, `open_near_click = true`, and a bar widget whose `onClick`
   calls `noctalia.togglePanel("<author/plugin>:panel")`.
2. Place the widget near one end of the bar; click it.
3. The panel opens centered on the bar instead of near the widget; toggling the
   "Centered / Near trigger" setting changes nothing.
