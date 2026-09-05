import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

PanelWindow {
    id: root

    anchors {
        top: true
        bottom: true
        left: true
        right: true
    }

    color: Qt.rgba(0.039, 0.039, 0.078, root.backdropOpacity)

    WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand

    property string wallpaperDir: ""
    property string changeCommand: ""
    property bool searchSubdirs: false
    property bool extraAnimations: true
    property real parallaxStrength: 1.0
    property int frameWidth: 70
    property int focusWidth: 540
    property real backdropOpacity: 0.87
    property string theme: "slant"
    property real perspectiveDepth: 0.45
    readonly property bool perspectiveTheme: theme === "perspective"
    property bool thumbnailCache: true
    property int thumbnailHeight: 256
    property int cacheSizeLimitMb: 64
    property bool viewInitialized: false
    property bool scanFinished: false
    property int currentIndex: 0

    function expandTilde(path) {
        if (!path) return ""
        return path.startsWith("~") ? Quickshell.env("HOME") + path.slice(1) : path
    }

    property string customConfigFile: expandTilde(Quickshell.env("YAWC_CONFIG"))

    readonly property string defaultConfigPath1: Quickshell.env("HOME") + "/.config/quickshell/yawc/config.yaml"
    readonly property string defaultConfigPath2: Quickshell.env("HOME") + "/.config/quickshell/yawc/config.yml"

    ListModel {
        id: wallpaperModel
    }

    function applyConfig(cfg) {
        if (cfg.wallpaper_dir !== undefined) wallpaperDir = expandTilde(cfg.wallpaper_dir)
        if (cfg.change_command !== undefined) changeCommand = cfg.change_command
        if (cfg.search_subdirs !== undefined) searchSubdirs = cfg.search_subdirs
        if (cfg.extra_animations !== undefined) extraAnimations = cfg.extra_animations
        if (cfg.parallax_strength !== undefined) parallaxStrength = cfg.parallax_strength
        if (cfg.frame_width !== undefined) frameWidth = cfg.frame_width
        if (cfg.focus_width !== undefined) focusWidth = cfg.focus_width
        if (cfg.backdrop_opacity !== undefined) backdropOpacity = cfg.backdrop_opacity
        if (cfg.theme !== undefined) theme = String(cfg.theme).toLowerCase()
        if (cfg.perspective_depth !== undefined) perspectiveDepth = cfg.perspective_depth
        if (cfg.thumbnail_cache !== undefined) thumbnailCache = cfg.thumbnail_cache
        if (cfg.thumbnail_height !== undefined) thumbnailHeight = cfg.thumbnail_height
        if (cfg.cache_size_limit_mb !== undefined) cacheSizeLimitMb = cfg.cache_size_limit_mb
    }

    Process {
        id: configLoader
        command: [
            "python3",
            "-c",
            "import sys, os, yaml, json\n" +
            "def load(p):\n" +
            "    if not p: return {}\n" +
            "    p = os.path.expanduser(p)\n" +
            "    if os.path.isfile(p):\n" +
            "        try:\n" +
            "            with open(p) as f:\n" +
            "                d = yaml.safe_load(f)\n" +
            "                return d if isinstance(d, dict) else {}\n" +
            "        except: pass\n" +
            "    return {}\n" +
            "base = load(sys.argv[1]) or load(sys.argv[2])\n" +
            "if len(sys.argv) > 3 and sys.argv[3]:\n" +
            "    base.update(load(sys.argv[3]))\n" +
            "print(json.dumps(base))",
            defaultConfigPath1,
            defaultConfigPath2,
            customConfigFile
        ]
        running: true
        stdout: SplitParser {
            splitMarker: ""
            onRead: function(data) {
                try {
                    root.applyConfig(JSON.parse(data))
                } catch(e) {}
                wallpaperScanner.running = true
            }
        }
    }

    function setupCarousel() {
        if (wallpaperModel.count === 0) return
        let targetPos = Math.floor(50000 / wallpaperModel.count) * wallpaperModel.count
        carousel.highlightMoveDuration = 0
        carousel.currentIndex = targetPos
        carousel.positionViewAtIndex(targetPos, ListView.Center)
        carousel.highlightMoveDuration = 220
    }

    // Parks the view at the animation's start so delegates decode before it plays.
    function beginEntry() {
        if (root.viewInitialized || wallpaperModel.count === 0) return
        root.viewInitialized = true

        if (!root.extraAnimations) {
            root.setupCarousel()
            entryReady = true
            entryComplete = true
            return
        }

        let targetPos = Math.floor(50000 / wallpaperModel.count) * wallpaperModel.count
        root.entryTarget = targetPos
        carousel.highlightMoveDuration = 0
        carousel.currentIndex = targetPos - 16
        carousel.positionViewAtIndex(carousel.currentIndex, ListView.Center)
        entryWarmup.start()
    }

    property int entryTarget: 0
    property bool entryReady: false
    property bool entryComplete: false
    property int decodedCount: 0

    // Upper bound on the wait, so a slow or failed decode can't stall startup.
    Timer {
        id: entryWarmup
        interval: 450
        repeat: false
        onTriggered: root.playEntry()
    }

    function notifyDecoded() {
        if (root.entryReady) return
        root.decodedCount++

        // Enough cards to fill the screen have painted, so the glide has something to show.
        let needed = Math.min(wallpaperModel.count,
                              Math.ceil(carousel.width / root.frameWidth))
        if (root.decodedCount >= needed) playEntry()
    }

    function playEntry() {
        if (root.entryReady) return
        root.entryReady = true
        entryWarmup.stop()

        carousel.highlightMoveDuration = 900
        carousel.currentIndex = root.entryTarget
        entrySettle.start()
    }

    // Hands control back to the short per-step duration once the entry glide ends, and
    // releases the full-resolution loads that were held back during startup.
    Timer {
        id: entrySettle
        interval: 900
        repeat: false
        onTriggered: {
            carousel.highlightMoveDuration = 220
            root.entryComplete = true
        }
    }

    readonly property string cacheDir: Quickshell.env("HOME") + "/.cache/yawc/thumbs"

    // path -> generated thumbnail file. Reassigned in batches so delegate bindings refresh.
    property var thumbMap: ({})
    property var pendingThumbs: ({})
    property string scanError: ""

    Timer {
        id: thumbFlush
        interval: 120
        repeat: false
        onTriggered: {
            root.thumbMap = Object.assign({}, root.thumbMap, root.pendingThumbs)
            root.pendingThumbs = ({})
        }
    }

    Process {
        id: wallpaperScanner
        running: false
        command: [
            "python3", "-c",
            "import sys, os, hashlib\n" +
            "root_dir, recurse, cache_dir, th, limit_mb = sys.argv[1], sys.argv[2] == '1', sys.argv[3], int(sys.argv[4]), float(sys.argv[5])\n" +
            "EXT = ('.jpg', '.jpeg', '.png', '.webp', '.jxl', '.bmp')\n" +
            "def emit(*a):\n" +
            "    sys.stdout.write('\\t'.join(a) + '\\n'); sys.stdout.flush()\n" +
            "if not os.path.isdir(root_dir):\n" +
            "    emit('ERR', 'notdir'); sys.exit(0)\n" +
            "files = []\n" +
            "def usable(p):\n" +
            "    return os.path.isfile(p) and os.access(p, os.R_OK)\n" +
            "try:\n" +
            "    if recurse:\n" +
            "        for dp, dns, fns in os.walk(root_dir):\n" +
            "            dns[:] = [d for d in dns if not d.startswith('.')]\n" +
            "            for f in sorted(fns):\n" +
            "                p = os.path.join(dp, f)\n" +
            "                if f.lower().endswith(EXT) and usable(p): files.append(p)\n" +
            "    else:\n" +
            "        for f in sorted(os.listdir(root_dir)):\n" +
            "            p = os.path.join(root_dir, f)\n" +
            "            if f.lower().endswith(EXT) and usable(p): files.append(p)\n" +
            "except PermissionError:\n" +
            "    emit('ERR', 'denied'); sys.exit(0)\n" +
            "def cachefile(p):\n" +
            "    if th <= 0: return ''\n" +
            "    try: st = os.stat(p)\n" +
            "    except OSError: return ''\n" +
            "    key = hashlib.sha1(('%s|%d|%d|%d' % (p, st.st_mtime_ns, st.st_size, th)).encode()).hexdigest()\n" +
            "    return os.path.join(cache_dir, key + '.jpg')\n" +
            "if th > 0:\n" +
            "    try: os.makedirs(cache_dir, exist_ok=True)\n" +
            "    except OSError: pass\n" +
            "pending = []\n" +
            "for p in files:\n" +
            "    c = cachefile(p)\n" +
            "    if c and os.path.exists(c):\n" +
            "        try: os.utime(c, None)\n" +
            "        except OSError: pass\n" +
            "        emit('LIST', p, c)\n" +
            "    else:\n" +
            "        emit('LIST', p, '')\n" +
            "        if c: pending.append((p, c))\n" +
            "emit('LISTED', str(len(files)))\n" +
            "if pending:\n" +
            "    try:\n" +
            "        from PIL import Image\n" +
            "    except ImportError:\n" +
            "        pending = []\n" +
            "for p, dst in pending:\n" +
            "    try:\n" +
            "        im = Image.open(p)\n" +
            "        try: im.draft('RGB', (max(1, im.width * th // max(1, im.height)), th))\n" +
            "        except Exception: pass\n" +
            "        im = im.convert('RGB')\n" +
            "        w = max(1, round(im.width * th / max(1, im.height)))\n" +
            "        im = im.resize((w, th), Image.LANCZOS)\n" +
            "        tmp = '%s.%d.tmp' % (dst, os.getpid())\n" +
            "        im.save(tmp, 'JPEG', quality=88, optimize=True)\n" +
            "        os.replace(tmp, dst)\n" +
            "        emit('THUMB', p, dst)\n" +
            "    except Exception:\n" +
            "        pass\n" +
            "try:\n" +
            "    ents = []\n" +
            "    for f in os.listdir(cache_dir):\n" +
            "        fp = os.path.join(cache_dir, f)\n" +
            "        if os.path.isfile(fp): ents.append((os.stat(fp).st_mtime, os.stat(fp).st_size, fp))\n" +
            "    total = sum(e[1] for e in ents)\n" +
            "    budget = limit_mb * 1024 * 1024\n" +
            "    for mt, sz, fp in sorted(ents):\n" +
            "        if total <= budget: break\n" +
            "        os.remove(fp); total -= sz\n" +
            "except Exception:\n" +
            "    pass\n" +
            "emit('END', '')",
            wallpaperDir,
            root.searchSubdirs ? "1" : "0",
            root.cacheDir,
            root.thumbnailCache ? String(root.thumbnailHeight) : "0",
            String(root.cacheSizeLimitMb)
        ]

        stdout: SplitParser {
            splitMarker: "\n"
            onRead: function(line) {
                if (line.length === 0) return
                let parts = line.split("\t")

                if (parts[0] === "LIST") {
                    wallpaperModel.append({ path: parts[1] })
                    if (parts.length > 2 && parts[2] !== "")
                        root.pendingThumbs[parts[1]] = parts[2]
                } else if (parts[0] === "LISTED") {
                    if (root.pendingThumbs !== undefined) {
                        root.thumbMap = Object.assign({}, root.thumbMap, root.pendingThumbs)
                        root.pendingThumbs = ({})
                    }
                    root.scanFinished = true
                    root.beginEntry()
                } else if (parts[0] === "THUMB") {
                    root.pendingThumbs[parts[1]] = parts[2]
                    thumbFlush.restart()
                } else if (parts[0] === "ERR") {
                    root.scanError = parts[1]
                    root.scanFinished = true
                    root.beginEntry()
                }
            }
        }

        onExited: {
            root.scanFinished = true
            root.beginEntry()
        }
    }

    Process {
        id: wallpaperSetter
        onExited: Qt.quit()
    }

    function applyWallpaper(path) {
        if (!path) return

        let quoted = "'" + path.replace(/'/g, "'\\''") + "'"
        let cmd = changeCommand

        if (cmd.indexOf("${WALLPAPER}") >= 0)
            cmd = cmd.replace("${WALLPAPER}", quoted)
        else
            cmd += " " + quoted

        wallpaperSetter.command = ["sh", "-c", cmd]
        wallpaperSetter.running = true
    }

    FocusScope {
        id: mainScope
        anchors.fill: parent
        focus: true

        Component.onCompleted: forceActiveFocus()

        Keys.onPressed: function(event) {
            switch(event.key) {
                case Qt.Key_Escape:
                    Qt.quit()
                    event.accepted = true
                    break
                case Qt.Key_Return:
                case Qt.Key_Space:
                    if (wallpaperModel.count > 0 && carousel.currentIndex >= 0) {
                        let realIdx = carousel.currentIndex % wallpaperModel.count
                        let item = wallpaperModel.get(realIdx)
                        if (item && item.path) root.applyWallpaper(item.path)
                    }
                    event.accepted = true
                    break
                case Qt.Key_Left:
                    carousel.decrementCurrentIndex()
                    event.accepted = true
                    break
                case Qt.Key_Right:
                    carousel.incrementCurrentIndex()
                    event.accepted = true
                    break
            }
        }

        WheelHandler {
            target: null
            acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad

            // High-resolution touchpads emit many small deltas per gesture; accumulate
            // to one step per notch instead of one step per event.
            property real acc: 0

            onWheel: function(event) {
                let d = event.angleDelta.y !== 0 ? event.angleDelta.y : -event.angleDelta.x
                if (d === 0) return

                acc += d
                while (acc <= -120) {
                    carousel.incrementCurrentIndex()
                    acc += 120
                }
                while (acc >= 120) {
                    carousel.decrementCurrentIndex()
                    acc -= 120
                }
            }
        }

        ListView {
            id: carousel
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width
            height: 650

            model: wallpaperModel.count > 0 ? 100000 : 0
            orientation: ListView.Horizontal
            spacing: 0
            reuseItems: true

            cacheBuffer: 1600

            readonly property int fullResWindow:
                Math.min(28, Math.ceil(width / root.frameWidth / 2) + 2)

            readonly property real shearPad: height * 0.25 + 90

            preferredHighlightBegin: width / 2 - root.focusWidth / 2
            preferredHighlightEnd: width / 2 - root.focusWidth / 2
            highlightRangeMode: ListView.StrictlyEnforceRange
            highlightMoveDuration: 220

            currentIndex: root.currentIndex
            onCurrentIndexChanged: root.currentIndex = currentIndex

            delegate: Item {
                id: delegateItem

                readonly property bool isCurrent: ListView.isCurrentItem

                readonly property string itemPath: {
                    if (wallpaperModel.count <= 0) return ""
                    let realIdx = index % wallpaperModel.count
                    if (realIdx < 0 || realIdx >= wallpaperModel.count) return ""
                    let data = wallpaperModel.get(realIdx)
                    return (data && data.path) ? data.path : ""
                }

                readonly property bool loadFullRes:
                    root.entryComplete && itemPath !== ""
                    && Math.abs(index - carousel.currentIndex) <= carousel.fullResWindow

                readonly property string thumbPath: {
                    if (itemPath === "") return ""
                    let t = root.thumbMap[itemPath]
                    return t ? t : itemPath
                }

                // True when thumbPath is a real cached thumbnail rather than the original.
                readonly property bool hasThumb:
                    itemPath !== "" && root.thumbMap[itemPath] !== undefined

                property real imageAspect: 1.6

                readonly property real viewX: delegateItem.x - carousel.contentX

                // 0 at the viewport's left edge, 1 at the right.
                readonly property real screenT: {
                    let vw = carousel.width
                    if (vw <= 0) return 0.5
                    return Math.max(0, Math.min(1, (viewX + delegateItem.width / 2) / vw))
                }

                readonly property real parallaxT:
                    Math.max(0, Math.min(1, 0.5 + (screenT - 0.5) * root.parallaxStrength))

                // 0 at the viewport centre, 1 at either edge.
                readonly property real depthT: Math.abs(screenT - 0.5) * 2

                // 1/(1+z) falloff, so distance reads nonlinearly like real depth.
                readonly property real depthScale:
                    root.perspectiveTheme ? 1 / (1 + depthT * root.perspectiveDepth) : 1

                width: isCurrent ? root.focusWidth : root.frameWidth
                height: carousel.height

                // Cards nearer the selection stack above their neighbours.
                z: root.perspectiveTheme
                    ? 1000 - Math.min(999, Math.abs(index - carousel.currentIndex))
                    : 0

                Behavior on width {
                    NumberAnimation {
                        duration: 320
                        easing.type: Easing.OutQuint
                    }
                }

                Item {
                    id: slantContainer
                    anchors.fill: parent

                    // Depth first, so the shear sees the shortened card and keeps its
                    // slant angle. Neither step touches x, so cards stay flush.
                    transform: [
                        Scale {
                            origin.y: slantContainer.height / 2
                            yScale: delegateItem.depthScale
                        },
                        Matrix4x4 {
                            matrix: Qt.matrix4x4(
                                1, -0.25, 0, 0.25 * (slantContainer.height / 2),
                                0, 1,     0, 0,
                                0, 0,     1, 0,
                                0, 0,     0, 1
                              )
                        }
                    ]

                    Rectangle {
                        anchors.fill: parent
                        color: "#181825"
                        clip: true
                        antialiasing: true

                        border.width: delegateItem.isCurrent ? 2 : 1
                        border.color: delegateItem.isCurrent ? "#cba6f7" : "#222233"

                        Behavior on border.width {
                            NumberAnimation { duration: 200 }
                        }

                        Item {
                            id: imageLayer
                            anchors.centerIn: parent
                            width: parent.width + carousel.shearPad
                            height: parent.height

                            transform: Matrix4x4 {
                                matrix: Qt.matrix4x4(
                                    1, 0.25, 0, -0.25 * (imageLayer.height / 2),
                                    0, 1,    0, 0,
                                    0, 0,    1, 0,
                                    0, 0,    0, 1
                                  )
                            }

                            // Tracks the card's on-screen height so photos keep their
                            // aspect instead of looking vertically squashed.
                            readonly property real coverWidth:
                                Math.max(width, height * delegateItem.imageAspect
                                                * delegateItem.depthScale)
                            readonly property real panX:
                                -(coverWidth - width) * delegateItem.parallaxT

                            Image {
                                id: thumb
                                x: imageLayer.panX
                                width: imageLayer.coverWidth
                                height: imageLayer.height
                                source: delegateItem.thumbPath !== "" ? "file://" + delegateItem.thumbPath : ""
                                sourceSize.height: root.thumbnailHeight
                                fillMode: Image.Stretch
                                // Cached thumbnails are small enough to decode inline during
                                // startup, guaranteeing they paint before the entry glide.
                                // Scrolling stays async so it can never block a frame.
                                asynchronous: !delegateItem.hasThumb || root.entryComplete
                                cache: true
                                smooth: true

                                onSourceChanged: delegateItem.imageAspect = 1.6
                                onStatusChanged: {
                                    if (status === Image.Ready) {
                                        if (implicitHeight > 0)
                                            delegateItem.imageAspect = implicitWidth / implicitHeight
                                        if (!root.entryReady) root.notifyDecoded()
                                    }
                                }
                            }

                            Image {
                                id: itemImage
                                x: imageLayer.panX
                                width: imageLayer.coverWidth
                                height: imageLayer.height
                                source: delegateItem.loadFullRes ? "file://" + delegateItem.itemPath : ""
                                sourceSize.height: carousel.height
                                fillMode: Image.Stretch
                                asynchronous: true
                                cache: true
                                smooth: true
                                antialiasing: true

                                opacity: status === Image.Ready ? 1 : 0
                                Behavior on opacity {
                                    NumberAnimation {
                                        duration: 260
                                        easing.type: Easing.OutCubic
                                    }
                                }
                            }
                        }

                        Rectangle {
                            anchors.fill: parent
                            color: "#0a0a0f"
                            // Perspective theme deepens the dim with distance instead of
                            // dimming every unselected card equally.
                            opacity: delegateItem.isCurrent
                                ? 0.0
                                : (root.perspectiveTheme
                                    ? 0.2 + 0.45 * delegateItem.depthT
                                    : 0.45)
                            Behavior on opacity {
                                NumberAnimation {
                                    duration: 320
                                    easing.type: Easing.OutQuint
                                }
                            }
                        }
                    }
                }

                MouseArea {
                    anchors.fill: parent
                    onClicked: {
                        mainScope.forceActiveFocus()
                        if (delegateItem.isCurrent) {
                            if (delegateItem.itemPath !== "") root.applyWallpaper(delegateItem.itemPath)
                        } else {
                            carousel.currentIndex = index
                        }
                    }
                }
            }
        }

        Text {
            anchors.centerIn: parent
            horizontalAlignment: Text.AlignHCenter
            visible: opacity > 0
            opacity: (root.scanFinished && wallpaperModel.count === 0) ? 1 : 0
            color: "#cdd6f4"
            font.pixelSize: 18
            lineHeight: 1.4

            text: {
                if (root.scanError === "notdir")
                    return root.wallpaperDir === ""
                        ? "No wallpaper_dir set.\nAdd one to your config.yml to get started."
                        : "Directory not found:\n" + root.wallpaperDir
                if (root.scanError === "denied")
                    return "Permission denied reading:\n" + root.wallpaperDir
                return "No images found in:\n" + root.wallpaperDir
            }

            Behavior on opacity {
                NumberAnimation { duration: 240 }
            }
        }
    }
}
