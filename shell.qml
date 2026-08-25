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

    color: "#dd0a0a14"

    WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand

    property string wallpaperDir: ""
    property string changeCommand: ""
    property bool searchSubdirs: false
    property bool extraAnimations: true
    property real parallaxStrength: 1.0
    property int frameWidth: 70
    property int focusWidth: 540
    property bool viewInitialized: false
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

        if (root.extraAnimations) {
            carousel.highlightMoveDuration = 0
            carousel.currentIndex = targetPos - 16
            carousel.positionViewAtIndex(carousel.currentIndex, ListView.Center)

            Qt.callLater(function() {
                carousel.highlightMoveDuration = 500
                carousel.currentIndex = targetPos
                Qt.callLater(function() {
                    carousel.highlightMoveDuration = 220
                })
            })
        } else {
            carousel.highlightMoveDuration = 0
            carousel.currentIndex = targetPos
            carousel.positionViewAtIndex(targetPos, ListView.Center)
            carousel.highlightMoveDuration = 220
        }
    }

    Process {
        id: wallpaperScanner
        running: false
        command: {
            let cmd = ["find", wallpaperDir]
            if (!root.searchSubdirs) {
                cmd.push("-maxdepth", "1")
            }
            cmd.push("-type", "f", "(",
                "-iname", "*.jpg", "-o",
                "-iname", "*.jpeg", "-o",
                "-iname", "*.png", "-o",
                "-iname", "*.webp", "-o",
                "-iname", "*.jxl", "-o",
                "-iname", "*.bmp", ")"
            )
            return cmd
        }

        stdout: SplitParser {
            splitMarker: "\n"
            onRead: function(path) {
                if (path.length > 0) {
                    wallpaperModel.append({ path: path })

                    if (!root.viewInitialized && wallpaperModel.count >= 4) {
                        root.viewInitialized = true
                        root.setupCarousel()
                    }
                }
            }
        }

        onExited: {
            if (!root.viewInitialized && wallpaperModel.count > 0) {
                root.viewInitialized = true
                root.setupCarousel()
            }
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
            target: carousel
            onWheel: function(event) {
                if (event.angleDelta.y < 0 || event.angleDelta.x > 0) {
                    carousel.incrementCurrentIndex()
                } else if (event.angleDelta.y > 0 || event.angleDelta.x < 0) {
                    carousel.decrementCurrentIndex()
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
                    itemPath !== "" && Math.abs(index - carousel.currentIndex) <= carousel.fullResWindow

                property real imageAspect: 1.6

                readonly property real parallaxT: {
                    let vw = carousel.width
                    if (vw <= 0) return 0.5
                    let center = delegateItem.x - carousel.contentX + delegateItem.width / 2
                    let t = center / vw
                    return Math.max(0, Math.min(1, 0.5 + (t - 0.5) * root.parallaxStrength))
                }

                width: isCurrent ? root.focusWidth : root.frameWidth
                height: carousel.height

                Behavior on width {
                    NumberAnimation {
                        duration: 250
                        easing.type: Easing.OutCubic
                    }
                }

                Item {
                    id: slantContainer
                    anchors.fill: parent

                    transform: Matrix4x4 {
                        matrix: Qt.matrix4x4(
                            1, -0.25, 0, 0.25 * (slantContainer.height / 2),
                            0, 1,     0, 0,
                            0, 0,     1, 0,
                            0, 0,     0, 1
                        )
                    }

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

                            readonly property real coverWidth:
                                Math.max(width, height * delegateItem.imageAspect)
                            readonly property real panX:
                                -(coverWidth - width) * delegateItem.parallaxT

                            Image {
                                id: thumb
                                x: imageLayer.panX
                                width: imageLayer.coverWidth
                                height: imageLayer.height
                                source: delegateItem.itemPath !== "" ? "file://" + delegateItem.itemPath : ""
                                sourceSize.height: 256
                                fillMode: Image.Stretch
                                asynchronous: true
                                cache: true
                                smooth: true

                                onSourceChanged: delegateItem.imageAspect = 1.6
                                onStatusChanged: {
                                    if (status === Image.Ready && implicitHeight > 0)
                                        delegateItem.imageAspect = implicitWidth / implicitHeight
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
                                    NumberAnimation { duration: 180 }
                                }
                            }
                        }

                        Rectangle {
                            anchors.fill: parent
                            color: "#0a0a0f"
                            opacity: delegateItem.isCurrent ? 0.0 : 0.45
                            Behavior on opacity {
                                NumberAnimation { duration: 250 }
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
    }
}
