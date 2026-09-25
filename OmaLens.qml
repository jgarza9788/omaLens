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
// four diagonals (below-right by default). Near a screen edge it turns around
// the ring to the diagonal that fits. Moving along the ring (rather than
// straight across) keeps it clear of the area it's magnifying the whole time,
// so it never magnifies itself. A small tail on the rim points at the pointer.
//
// Pointer position comes from bin/omalens-cursor (polls Hyprland's `cursorpos`).
//
// Control it over IPC (see bin/omalens):
//   omarchy-shell omalens zoomIn | zoomOut | bigger | smaller | shape | smooth
//
// Summon payload (all optional): {"zoom": 3, "size": "large", "shape": "square",
// "smooth": true}. Settings are remembered between summons.
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

  // Displayed (animated) versions of the settings.
  property real dz: zoom
  property real ds: size
  property real roundness: round ? 1 : 0
  // Springs throughout: they settle softly and, unlike timed curves, keep
  // their velocity when retargeted mid-flight, so nothing ever snaps.
  Behavior on dz { SpringAnimation { spring: 5; damping: 0.45; epsilon: 0.001 } }
  Behavior on ds { SpringAnimation { spring: 5; damping: 0.45; epsilon: 0.25 } }
  Behavior on roundness { SpringAnimation { spring: 4; damping: 0.5; epsilon: 0.002 } }

  // ── State ────────────────────────────────────────────────────────────────
  property bool active: false      // open (or opening)
  property bool closing: false     // playing the close animation
  property bool havePos: false
  property real gx: 0              // pointer, global logical coords
  property real gy: 0

  // 0 → 1 as the lens appears; back to 0 as it goes. Appearing is a soft
  // spring (≈ 350 ms, barely any overshoot); leaving is a quicker ease-in with
  // no bounce. Both start from the current value, so reversing mid-way is smooth.
  property real shown: 0
  readonly property real shownC: Math.max(0, Math.min(1, shown))

  SpringAnimation {
    id: openAnim
    target: root; property: "shown"; to: 1
    spring: 4.5; damping: 0.32; epsilon: 0.002
  }
  NumberAnimation {
    id: closeAnim
    target: root; property: "shown"; to: 0
    duration: 180; easing.type: Easing.InQuad
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
  // `gap` keeps the lens clear of the sampled square (ds / dz wide, centred
  // on the pointer). On a diagonal, the lens centre sits `reach` from the
  // pointer along each axis, so the ring radius is reach·√2.
  readonly property real gap: ds / (2 * dz) + 18
  readonly property real reach: gap + ds / 2
  readonly property real ringRadius: reach * Math.SQRT2
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
    var far = gap + ds;            // pointer → far edge of the lens, per axis
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

  // ── Settings ────────────────────────────────────────────────────────────
  function clampZoom(z) { return Math.max(minZoom, Math.min(maxZoom, z)); }

  function setZoom(z) {
    root.zoom = clampZoom(z);
    flash(root.zoom.toFixed(root.zoom < 10 ? 2 : 1).replace(/\.?0+$/, "") + "×");
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

  function applyPayload(payloadJson) {
    var p = {};
    try { p = JSON.parse(String(payloadJson || "{}")) || {}; } catch (e) {}
    if (isFinite(p.zoom)) root.zoom = clampZoom(Number(p.zoom));
    if (p.size !== undefined && sizeIndexOf(p.size) >= 0) root.sizeIndex = sizeIndexOf(p.size);
    if (p.shape === "square") root.round = false;
    else if (p.shape === "circle") root.round = true;
    if (typeof p.smooth === "boolean") root.smoothPixels = p.smooth;
  }

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
          root.animateIn();
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

  Timer { id: closeTimer; interval: 190; onTriggered: root.finishClose() }

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
    function smooth(): string {
      root.smoothPixels = !root.smoothPixels;
      root.flash(root.smoothPixels ? "smooth" : "sharp");
      return root.smoothPixels ? "smooth" : "sharp"
    }
  }

  // ── The lens surface ────────────────────────────────────────────────────
  PanelWindow {
    id: panel

    // Room around the lens for its shadow and the pop-in overshoot.
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
      opacity: Math.min(1, root.shownC * 1.4)

      readonly property real radius:
        Style.cornerRadius + (width / 2 - Style.cornerRadius) * Math.max(0, Math.min(1, root.roundness))

      // A small scale from the pointer's side — felt more than seen.
      transform: Scale {
        origin.x: root.cx - root.lensX
        origin.y: root.cy - root.lensY
        xScale: 0.9 + 0.1 * root.shown
        yScale: 0.9 + 0.1 * root.shown
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

      // Rim: accent ring.
      Rectangle {
        anchors.fill: parent
        radius: lens.radius
        color: "transparent"
        border.width: 3
        border.color: Color.accent
      }

      // Tail: a small triangle on the rim pointing at the real pointer. It sits
      // where the line from the lens centre to the pointer crosses the rim.
      readonly property real pointerAngle:
        Math.atan2(root.cy - (root.lensY + height / 2), root.cx - (root.lensX + width / 2))
      readonly property real rimDistance: {
        var c = Math.abs(Math.cos(pointerAngle)), s = Math.abs(Math.sin(pointerAngle));
        var square = (width / 2) / Math.max(c, s, 0.0001);
        var t = Math.max(0, Math.min(1, root.roundness));
        return square + (width / 2 - square) * t;
      }
      Item {
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
        opacity: 0.7
      }
      Rectangle {
        anchors.centerIn: parent
        width: 13; height: 1
        color: Color.accent
        opacity: 0.7
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
