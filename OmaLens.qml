import QtQuick
import QtQuick.Effects
import QtQuick.Shapes
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons

// omaLens — a live magnifying glass that floats beside the pointer.
//
// The lens is a small click-through layer surface: it takes no keyboard or
// mouse input, so every Hyprland binding and every click keeps working while
// it's open. It shows a live screencopy of the monitor under the pointer,
// magnified around the pointer.
//
// Placement: the lens rides on a ring around the pointer, parked on one of the
// four diagonals (below-right by default). A round lens only has to clear the
// round patch it shows, so it sits closer than a square one. Near a screen edge it turns around
// the ring to the diagonal that fits. Moving along the ring (rather than
// straight across) keeps it clear of the area it's magnifying the whole time,
// so it never magnifies itself. A small tail on the rim points at the pointer.
//
// Pointer position comes from bin/omalens-cursor (polls Hyprland's `cursorpos`).
//
// Control it over IPC (see bin/omalens):
//   omarchy-shell omalens zoomIn | zoomOut | bigger | smaller | shape | smooth
//   omarchy-shell omalens settings      (the settings window, LensSettings.qml)
//
// Summon payload (all optional): {"zoom": 3, "size": "large", "shape": "square",
// "smooth": true, "offset": 40}. A payload lasts until the lens closes and is never saved.
// Otherwise, changes made from the settings window or the IPC verbs are saved to
// ~/.config/omarchy/jgarza.omalens/settings.json.
Item {
  id: root

  // ── Injected by the Omarchy shell loader ─────────────────────────────────
  property var shell: null
  property var manifest: null
  property string omarchyPath: ""
  readonly property string pluginId: String((manifest && manifest.id) || "jgarza.omalens")

  // ── Lens settings ────────────────────────────────────────────────────────
  readonly property real minZoom: 1.25
  readonly property real maxZoom: 24
  // Extra space (px) between the magnified area and the lens. At 0 the rim
  // touches the magnified area; any closer and the lens would magnify itself.
  readonly property int minOffset: 0
  readonly property int maxOffset: 100
  // Three lens sizes; `sizeIndex` picks one.
  readonly property var sizes: [
    { id: "small",  label: "Small",  px: 300 },
    { id: "medium", label: "Medium", px: 600 },
    { id: "large",  label: "Large",  px: 900 }
  ]

  property real zoom: 2.5
  property int sizeIndex: 1
  readonly property int size: sizes[sizeIndex].px
  property bool round: true
  property bool smoothPixels: false
  property real offset: 18

  // Displayed (animated) versions of the settings.
  property real dz: zoom
  property real ds: size
  property real roundness: round ? 1 : 0
  property real doff: offset
  // Springs throughout: they settle softly and, unlike timed curves, keep
  // their velocity when retargeted mid-flight, so nothing ever snaps.
  Behavior on dz { SpringAnimation { spring: 5; damping: 0.45; epsilon: 0.001 } }
  Behavior on ds { SpringAnimation { spring: 5; damping: 0.45; epsilon: 0.25 } }
  Behavior on roundness { SpringAnimation { spring: 4; damping: 0.5; epsilon: 0.002 } }
  Behavior on doff { SpringAnimation { spring: 5; damping: 0.45; epsilon: 0.25 } }

  // ── State ────────────────────────────────────────────────────────────────
  property bool active: false      // open (or opening)
  property bool closing: false     // playing the close animation
  property bool havePos: false
  property real gx: 0              // pointer, global logical coords
  property real gy: 0

  // 0 → 1 as the lens appears; back to 0 as it goes. Both take 330 ms with no
  // bounce: appearing eases out, leaving eases in and out. Both start from the
  // current value, so reversing mid-way is smooth.
  property real shown: 0
  readonly property real shownC: Math.max(0, Math.min(1, shown))

  NumberAnimation {
    id: openAnim
    target: root; property: "shown"; to: 1
    duration: 330; easing.type: Easing.OutCubic
  }
  NumberAnimation {
    id: closeAnim
    target: root; property: "shown"; to: 0
    duration: 330; easing.type: Easing.InOutCubic
  }
  function animateIn() { closeAnim.stop(); openAnim.start(); }
  function animateOut() { openAnim.stop(); closeAnim.start(); }

  // The glass "lifts off" the screen: magnification ramps up to the zoom as
  // it appears and relaxes as it goes. It starts from the lowest zoom whose
  // sampled square still clears the lens (half-width ds / 2z ≤ gap), so the
  // lens never captures itself mid-animation.
  readonly property real minLiveZoom: Math.max(1, ds / (2 * gap))
  readonly property real liveZoom: minLiveZoom + (dz - minLiveZoom) * shownC

  readonly property var targetScreen: {
    var screens = Quickshell.screens;
    for (var i = 0; i < screens.length; i++) {
      var s = screens[i];
      if (gx >= s.x && gx < s.x + s.width && gy >= s.y && gy < s.y + s.height) return s;
    }
    return screens.length > 0 ? screens[0] : null;
  }
  readonly property real screenW: targetScreen ? targetScreen.width : 0
  readonly property real screenH: targetScreen ? targetScreen.height : 0
  // Pointer relative to the monitor it's on.
  readonly property real cx: targetScreen ? gx - targetScreen.x : gx
  readonly property real cy: targetScreen ? gy - targetScreen.y : gy

  // ── Placement on the ring ───────────────────────────────────────────────
  // `gap` is the space between the pointer and the nearest edge of the lens:
  // the half-width of the patch the lens shows (ds / 2dz, centred on the
  // pointer) plus the user's `offset`.
  //
  // A round lens shows a round patch, so two circles only need their centres
  // gap + ds/2 apart, at any angle. A square lens shows a square patch, which
  // needs that much along one axis (a square ring: farther on the diagonals).
  // In between shapes, the two radii are blended.
  readonly property real gap: ds / (2 * dz) + doff
  readonly property real roundC: Math.max(0, Math.min(1, roundness))
  function ringRadiusAt(deg) {
    var a = deg * Math.PI / 180;
    var circle = gap + ds / 2;
    var square = circle / Math.max(Math.abs(Math.cos(a)), Math.abs(Math.sin(a)), 0.0001);
    return square + (circle - square) * roundC;
  }
  readonly property real ringRadius: ringRadiusAt(angle)
  // Parked on a diagonal: pointer → lens centre, per axis.
  readonly property real reach: ringRadiusAt(45) * Math.SQRT1_2
  readonly property real edgeMargin: 8
  readonly property real edgeHysteresis: 48

  property int quadX: 1            // +1 right of the pointer, −1 left
  property int quadY: 1            // +1 below, −1 above
  property real angleTarget: 45
  property bool animateMoves: false
  property real angle: 45          // degrees, 0 = right, 90 = below
  Behavior on angle {
    enabled: root.animateMoves
    SpringAnimation { spring: 3; damping: 0.4; epsilon: 0.05 }
  }

  readonly property real lensX: {
    var x = cx + ringRadius * Math.cos(angle * Math.PI / 180) - ds / 2;
    return Math.max(0, Math.min(screenW - ds, x));
  }
  readonly property real lensY: {
    var y = cy + ringRadius * Math.sin(angle * Math.PI / 180) - ds / 2;
    return Math.max(0, Math.min(screenH - ds, y));
  }

  // Pick the diagonal. Prefer below-right; switch sides when the lens would
  // run off an edge, and only come back once there's comfortable room again
  // (the hysteresis stops it flapping along an edge).
  function updateQuadrant() {
    if (!havePos || !targetScreen) return;
    var far = reach + ds / 2;      // pointer → far edge of the lens, per axis
    var m = edgeMargin, h = edgeHysteresis;

    var qx = quadX;
    var fitsR = cx + far <= screenW - m, fitsL = cx - far >= m;
    if (qx > 0) { if (!fitsR && fitsL) qx = -1; }
    else if (!fitsL || cx + far <= screenW - m - h) qx = 1;

    var qy = quadY;
    var fitsD = cy + far <= screenH - m, fitsU = cy - far >= m;
    if (qy > 0) { if (!fitsD && fitsU) qy = -1; }
    else if (!fitsU || cy + far <= screenH - m - h) qy = 1;

    if (qx === quadX && qy === quadY && animateMoves) return;
    quadX = qx;
    quadY = qy;

    // Turn the short way round the ring.
    var target = Math.atan2(qy, qx) * 180 / Math.PI;
    var diff = ((target - angleTarget) % 360 + 540) % 360 - 180;
    angleTarget = angleTarget + diff;
    angle = angleTarget;
  }
  onCxChanged: updateQuadrant()
  onCyChanged: updateQuadrant()
  onDsChanged: updateQuadrant()
  onDzChanged: updateQuadrant()
  onDoffChanged: updateQuadrant()
  onRoundCChanged: updateQuadrant()

  // ── Settings ────────────────────────────────────────────────────────────
  function clampZoom(z) { return Math.max(minZoom, Math.min(maxZoom, z)); }
  function clampOffset(o) { return Math.round(Math.max(minOffset, Math.min(maxOffset, o))); }

  function zoomLabel(z) { return z.toFixed(z < 10 ? 2 : 1).replace(/\.?0+$/, "") + "×"; }
  function setZoom(z) {
    root.zoom = clampZoom(z);
    flash(zoomLabel(root.zoom));
  }
  function setSizeIndex(i) {
    root.sizeIndex = Math.max(0, Math.min(sizes.length - 1, i));
    flash(sizes[root.sizeIndex].label);
  }
  // "small" / "medium" / "large"; returns -1 for anything else.
  function sizeIndexOf(name) {
    for (var i = 0; i < sizes.length; i++) if (sizes[i].id === String(name).toLowerCase()) return i;
    return -1;
  }

  // Hint pill: the text stays put while it fades out.
  property string hint: ""
  property bool hintOn: false
  function flash(t) { root.hint = t; root.hintOn = true; hintTimer.restart(); }
  Timer { id: hintTimer; interval: 900; onTriggered: root.hintOn = false }

  function applySettings(p) {
    if (!p || typeof p !== "object") return;
    if (isFinite(p.zoom)) root.zoom = clampZoom(Number(p.zoom));
    if (p.size !== undefined && sizeIndexOf(p.size) >= 0) root.sizeIndex = sizeIndexOf(p.size);
    if (p.shape === "square") root.round = false;
    else if (p.shape === "circle") root.round = true;
    if (typeof p.smooth === "boolean") root.smoothPixels = p.smooth;
    if (isFinite(p.offset)) root.offset = clampOffset(Number(p.offset));
  }
  // A summon payload is a one-off: it changes the lens until it closes, and
  // is never saved. While one is in effect (`overridden`), hotkey changes are
  // also left unsaved; closing the lens puts the saved settings back.
  function applyPayload(payloadJson) {
    var p = {};
    try { p = JSON.parse(String(payloadJson || "{}")) || {}; } catch (e) {}
    root.restoreSaved();
    if (typeof p !== "object" || Object.keys(p).length === 0) return;
    root.overridden = true;
    root.restoring = true;
    applySettings(p);
    root.restoring = false;
  }
  function restoreSaved() {
    if (!root.overridden) return;
    root.overridden = false;
    root.restoring = true;
    applySettings(root.saved);
    root.restoring = false;
  }

  // ── Saved settings ──────────────────────────────────────────────────────
  readonly property var defaults: ({ zoom: 2.5, size: "medium", shape: "circle", smooth: false, offset: 18 })
  // What's in settings.json. The settings window shows and edits this.
  property var saved: defaults
  property bool overridden: false
  property bool restoring: false   // applying saved/payload values: don't save
  property bool loaded: false      // the file has been read; until then, never write it
  readonly property string configDir: Quickshell.env("HOME") + "/.config/omarchy/" + pluginId

  function currentSettings() {
    return { zoom: root.zoom, size: root.sizes[root.sizeIndex].id,
             shape: root.round ? "circle" : "square", smooth: root.smoothPixels,
             offset: root.offset };
  }
  // Set one saved setting (from the settings window) and show it on the lens.
  function setSaved(key, value) {
    var next = Object.assign({}, root.saved);
    next[key] = key === "zoom" ? clampZoom(value) : key === "offset" ? clampOffset(value) : value;
    root.saved = next;
    root.restoring = true;
    var one = {};
    one[key] = next[key];
    applySettings(one);
    root.restoring = false;
    if (root.loaded) saveTimer.restart();
  }
  function resetSettings() {
    for (var k in root.defaults) setSaved(k, root.defaults[k]);
  }

  Component.onCompleted: Quickshell.execDetached(["mkdir", "-p", root.configDir])

  FileView {
    id: settingsFile
    path: root.configDir + "/settings.json"
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onLoaded: {
      var p = {};
      try { p = JSON.parse(String(text() || "{}")) || {}; } catch (e) {}
      root.restoring = true;
      root.applySettings(p);
      root.restoring = false;
      root.saved = root.currentSettings();
      root.loaded = true;
    }
    onLoadFailed: root.loaded = true
  }
  Timer {
    id: saveTimer
    interval: 400
    onTriggered: settingsFile.setText(JSON.stringify(root.saved, null, 2) + "\n")
  }
  // Hotkey / IPC changes to the lens are saved, unless a payload is in effect.
  function saveSettings() {
    if (!root.loaded || root.restoring || root.overridden) return;
    root.saved = root.currentSettings();
    saveTimer.restart();
  }
  onZoomChanged: saveSettings()
  onSizeIndexChanged: saveSettings()
  onRoundChanged: saveSettings()
  onSmoothPixelsChanged: saveSettings()
  onOffsetChanged: saveSettings()

  LensSettings { id: settingsWindow; lens: root }

  // ── Pointer tracking ────────────────────────────────────────────────────
  // bin/omalens-cursor polls Hyprland's `cursorpos` and prints "X Y" on
  // every change; it runs only while the lens is up.
  function binPath(name) { return Qt.resolvedUrl("bin/" + name).toString().replace(/^file:\/\//, ""); }

  Process {
    id: cursorProc
    command: [root.binPath("omalens-cursor")]
    running: root.active || root.closing
    stdout: SplitParser {
      onRead: function (line) {
        var m = String(line).trim().split(/\s+/);
        if (m.length < 2) return;
        root.gx = Number(m[0]);
        root.gy = Number(m[1]);
        if (!root.havePos) {
          // First fix: place the lens without animating, then pop it in.
          root.havePos = true;
          root.animateMoves = false;
          root.updateQuadrant();
          root.animateMoves = true;
          if (root.active) root.animateIn();
        }
      }
    }
  }

  // ── Lifecycle verbs (overlay contract) ──────────────────────────────────
  // The shell reads `opened` for toggling and calls close() to hide us; our
  // own close paths go through shell.hide() so its bookkeeping stays in step.
  readonly property bool opened: active

  function open(payloadJson) {
    applyPayload(payloadJson);
    closeTimer.stop();
    root.closing = false;
    root.active = true;
    if (root.havePos) root.animateIn();
  }
  function close() {
    if (!root.active) return;
    root.active = false;
    root.closing = true;
    root.animateOut();
    closeTimer.restart();
  }
  function finishClose() {
    root.closing = false;
    root.restoreSaved();
    root.havePos = false;
    root.animateMoves = false;
  }
  function dismiss() {
    if (root.shell && typeof root.shell.hide === "function") root.shell.hide(root.pluginId);
    else root.close();
  }
  function toggle() {
    if (root.active) root.dismiss();
    else root.open("{}");
  }
  function summon(payloadJson) { root.open(payloadJson || "{}"); }
  function hide() { root.dismiss(); }

  Timer { id: closeTimer; interval: 340; onTriggered: root.finishClose() }

  IpcHandler {
    target: "omalens"
    function toggle(): string { root.toggle(); return root.active ? "on" : "off" }
    function close(): string { root.dismiss(); return "off" }
    function zoomIn(): string { root.setZoom(root.zoom * 1.25); return String(root.zoom) }
    function zoomOut(): string { root.setZoom(root.zoom / 1.25); return String(root.zoom) }
    function bigger(): string { root.setSizeIndex(root.sizeIndex + 1); return root.sizes[root.sizeIndex].id }
    function smaller(): string { root.setSizeIndex(root.sizeIndex - 1); return root.sizes[root.sizeIndex].id }
    function cycleSize(): string {
      root.setSizeIndex((root.sizeIndex + 1) % root.sizes.length);
      return root.sizes[root.sizeIndex].id
    }
    function setSize(name: string): string {
      var i = root.sizeIndexOf(name);
      if (i < 0) return "unknown size: " + name;
      root.setSizeIndex(i);
      return root.sizes[i].id
    }
    function shape(): string {
      root.round = !root.round;
      root.flash(root.round ? "circle" : "square");
      return root.round ? "circle" : "square"
    }
    function settings(): string {
      settingsWindow.toggle();
      return settingsWindow.opened ? "open" : "closed"
    }
    function smooth(): string {
      root.smoothPixels = !root.smoothPixels;
      root.flash(root.smoothPixels ? "smooth" : "sharp");
      return root.smoothPixels ? "smooth" : "sharp"
    }
  }

  // ── The lens surface ────────────────────────────────────────────────────
  PanelWindow {
    id: panel

    // Room around the lens for its shadow to fall on.
    readonly property int pad: 32
    readonly property int winW: Math.ceil(root.ds) + 2 * pad
    readonly property int winH: Math.ceil(root.ds) + 2 * pad
    readonly property int winX: Math.round(Math.max(0, Math.min(root.screenW - winW, root.lensX - pad)))
    readonly property int winY: Math.round(Math.max(0, Math.min(root.screenH - winH, root.lensY - pad)))

    screen: root.targetScreen
    visible: (root.active || root.closing) && root.havePos
    anchors { top: true; left: true }
    margins { top: winY; left: winX }
    implicitWidth: winW
    implicitHeight: winH
    color: "transparent"

    WlrLayershell.namespace: "omarchy-omalens"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore
    // Empty input region: clicks and scrolls fall through to what's below.
    mask: Region {}

    Item {
      id: lens
      x: root.lensX - panel.winX
      y: root.lensY - panel.winY
      width: root.ds
      height: root.ds
      opacity: Math.min(1, root.shownC * 4)

      // Opening: an accent dot appears at the rim nearest the pointer, grows to
      // full size, then its stroke thins out to reveal the view. Closing runs
      // the same steps backwards. `grow` and `open` overlap a little.
      function phase(t, a, b) {
        var x = Math.max(0, Math.min(1, (t - a) / (b - a)));
        return x * x * (3 - 2 * x);
      }
      readonly property real grow: phase(root.shownC, 0, 0.6)
      readonly property real open: phase(root.shownC, 0.35, 1)
      readonly property real dotScale: Math.min(1, 14 / Math.max(1, width))

      // Roundness as drawn: a square lens is still a round dot until it opens.
      readonly property real rnd: Math.max(Math.max(0, Math.min(1, root.roundness)), 1 - open)
      readonly property real radius:
        Style.cornerRadius + (width / 2 - Style.cornerRadius) * rnd

      // Grow from the rim point nearest the pointer (where the tail sits), so
      // the lens never reaches into the area it's magnifying.
      transform: Scale {
        origin.x: lens.width / 2 + lens.rimDistance * Math.cos(lens.pointerAngle)
        origin.y: lens.height / 2 + lens.rimDistance * Math.sin(lens.pointerAngle)
        xScale: lens.dotScale + (1 - lens.dotScale) * lens.grow
        yScale: lens.dotScale + (1 - lens.dotScale) * lens.grow
      }

      // Shadow: deepens as the lens lifts.
      Rectangle {
        anchors.fill: parent
        radius: lens.radius
        color: Color.background
        layer.enabled: true
        layer.effect: MultiEffect {
          shadowEnabled: true
          shadowColor: "#000000"
          shadowOpacity: 0.45 * root.shownC
          shadowBlur: 0.5 + 0.4 * root.shownC
          blurMax: 32
          shadowVerticalOffset: 2 + 5 * root.shownC
        }
      }

      Rectangle {
        id: lensMask
        anchors.fill: parent
        radius: lens.radius
        visible: false
        layer.enabled: true
        layer.smooth: true
      }

      Item {
        anchors.fill: parent
        layer.enabled: true
        layer.smooth: true
        layer.effect: MultiEffect {
          maskEnabled: true
          maskSource: lensMask
          maskThresholdMin: 0.5
          maskSpreadAtMin: 1.0
          // Focus pull: the view sharpens as the lens settles.
          blurEnabled: true
          blurMax: 24
          // Without this, blur pads the output by blurMax and the mask gets
          // stretched over the padding, spilling the view past the rim.
          autoPaddingEnabled: false
          blur: 0.7 * (1 - root.shownC)
        }

        Rectangle { anchors.fill: parent; color: Color.background }

        ScreencopyView {
          captureSource: panel.visible ? root.targetScreen : null
          live: true
          paintCursor: true
          smooth: root.smoothPixels
          width: root.screenW * root.liveZoom
          height: root.screenH * root.liveZoom
          x: root.ds / 2 - root.cx * root.liveZoom
          y: root.ds / 2 - root.cy * root.liveZoom
        }
      }

      // Rim: accent ring. While opening it starts thick enough to fill the
      // lens (a solid dot) and thins down to 3 px.
      Rectangle {
        anchors.fill: parent
        radius: lens.radius
        color: "transparent"
        border.width: 3 + (width / 2 - 3) * (1 - lens.open)
        border.color: Color.accent
      }

      // Tail: a small triangle on the rim pointing at the real pointer. It sits
      // where the line from the lens centre to the pointer crosses the rim.
      readonly property real pointerAngle:
        Math.atan2(root.cy - (root.lensY + height / 2), root.cx - (root.lensX + width / 2))
      readonly property real rimDistance: {
        var c = Math.abs(Math.cos(pointerAngle)), s = Math.abs(Math.sin(pointerAngle));
        var square = (width / 2) / Math.max(c, s, 0.0001);
        var t = lens.rnd;
        return square + (width / 2 - square) * t;
      }
      // The tail is 14 px long; at smaller distances it shrinks to fit, so it
      // never pokes into the magnified area.
      Item {
        opacity: lens.open
        scale: Math.max(0, Math.min(1, root.doff / 14))
        x: lens.width / 2 + lens.rimDistance * Math.cos(lens.pointerAngle)
        y: lens.height / 2 + lens.rimDistance * Math.sin(lens.pointerAngle)
        rotation: lens.pointerAngle * 180 / Math.PI

        Shape {
          preferredRendererType: Shape.CurveRenderer
          antialiasing: true
          ShapePath {
            fillColor: Color.accent
            strokeWidth: -1
            // The base starts 3 px inside the rim so it joins the ring seamlessly.
            startX: -3; startY: -11
            PathLine { x: 14; y: 0 }
            PathLine { x: -3; y: 11 }
            PathLine { x: -3; y: -11 }
          }
        }
      }

      // Crosshair marking the pointer's spot.
      Rectangle {
        anchors.centerIn: parent
        width: 1; height: 13
        color: Color.accent
        opacity: 0.7 * lens.open
      }
      Rectangle {
        anchors.centerIn: parent
        width: 13; height: 1
        color: Color.accent
        opacity: 0.7 * lens.open
      }

      // Zoom / size readout.
      Rectangle {
        anchors {
          horizontalCenter: parent.horizontalCenter
          bottom: parent.bottom
          bottomMargin: 10 + parent.height * 0.08 * root.roundness
        }
        width: hintText.implicitWidth + 16
        height: hintText.implicitHeight + 8
        radius: height / 2
        color: Color.popups.background
        border.width: 1
        border.color: Color.popups.border
        opacity: root.hintOn ? 1 : 0
        scale: root.hintOn ? 1 : 0.94
        Behavior on opacity { NumberAnimation { duration: 160 } }
        Behavior on scale { SpringAnimation { spring: 6; damping: 0.5; epsilon: 0.002 } }

        Text {
          id: hintText
          anchors.centerIn: parent
          text: root.hint
          color: Color.popups.text
          font.pixelSize: 13
        }
      }
    }
  }
}
