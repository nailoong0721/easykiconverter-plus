import QtQuick
import QtQuick.Controls
import QtQuick.Window
import QtTest
import "../../src/ui/qml/components"

TestCase {
    name: "WindowGeometry"

    ApplicationWindow {
        id: testWindow
        property int defaultWidth: 900
        property int defaultHeight: 680
        property var screenWorkAreas: []
        width: 900
        height: 680
        flags: Qt.Window | Qt.FramelessWindowHint
        visible: false
    }

    QtObject {
        id: config
        property var state: ({ x: 346, y: -146, width: 1920, height: 1040, maximized: false })
        function getWindowState() { return state }
        function setWindowState(value) { state = value }
    }

    WindowPersistenceManager {
        id: persistence
        window: testWindow
        configService: config
    }

    WindowStartupManager {
        id: startup
        window: testWindow
        configService: config
        persistenceManager: persistence
    }

    function init() {
        testWindow.hide()
        testWindow.screenWorkAreas = []
        testWindow.minimumWidth = 0
        testWindow.minimumHeight = 0
        config.state = { x: 346, y: -146, width: 1920, height: 1040, maximized: false }
        persistence.pendingNormalRestore = false
        persistence.stateTransitionInProgress = false
    }

    function cleanup() {
        testWindow.hide()
    }

    function test_restoredGeometry_data() {
        return [
            { tag: "upper-right", areas: [Qt.rect(0, 0, 1920, 1040)], saved: {x: 346, y: -146, width: 1920, height: 1040}, expected: [0, 0, 1920, 1040] },
            { tag: "oversized", areas: [Qt.rect(0, 0, 1280, 720)], saved: {x: 300, y: 200, width: 1920, height: 1080}, expected: [0, 0, 1280, 720] },
            { tag: "top-taskbar", areas: [Qt.rect(0, 40, 1920, 1040)], saved: {x: 0, y: 0, width: 900, height: 680}, expected: [0, 40, 900, 680] },
            { tag: "left-monitor", areas: [Qt.rect(0, 0, 1920, 1040), Qt.rect(-1920, -200, 1920, 1040)], saved: {x: -1800, y: -100, width: 900, height: 680}, expected: [-1800, -100, 900, 680] },
            { tag: "zero-coordinates", areas: [Qt.rect(0, 0, 1920, 1040)], saved: {x: 0, y: 0, width: 900, height: 680}, expected: [0, 0, 900, 680] },
            { tag: "saved-below-minimum", areas: [Qt.rect(0, 0, 1920, 1040)], saved: {x: 1420, y: 640, width: 500, height: 400}, minimumWidth: 855, minimumHeight: 620, expected: [1065, 420, 855, 620] },
            { tag: "removed-monitor", areas: [Qt.rect(0, 0, 1920, 1040)], saved: {x: 4000, y: -1080, width: 900, height: 680}, expected: [1020, 0, 900, 680] },
            { tag: "first-launch", areas: [Qt.rect(0, 0, 1920, 1040)], saved: {x: -9999, y: -9999, width: -1, height: -1}, expected: [510, 180, 900, 680] },
            { tag: "small-screen-first-launch", areas: [Qt.rect(0, 0, 640, 480)], saved: {x: -9999, y: -9999, width: -1, height: -1}, expected: [0, 0, 640, 480] }
        ]
    }

    function test_restoredGeometry(data) {
        testWindow.screenWorkAreas = data.areas
        testWindow.minimumWidth = data.minimumWidth || 0
        testWindow.minimumHeight = data.minimumHeight || 0
        config.state = data.saved
        const geometry = startup.resolveStartupGeometry()
        compare([geometry.x, geometry.y, geometry.width, geometry.height], data.expected)
    }

    function test_workAreaChangeClampsVisibleWindow() {
        testWindow.screenWorkAreas = [Qt.rect(0, 0, 1920, 1040)]
        startup.initializeWindow()
        testWindow.screenWorkAreas = [Qt.rect(0, 40, 1280, 680)]
        compare([testWindow.x, testWindow.y, testWindow.width, testWindow.height], [0, 40, 1280, 680])
    }

    function test_repeatedLaunchKeepsVisiblePosition() {
        config.state = { x: 0, y: 0, width: 500, height: 400, maximized: false }
        startup.initializeWindow()
        testWindow.hide()
        startup.initializeWindow()
        compare([testWindow.x, testWindow.y, testWindow.width, testWindow.height], [0, 0, 500, 400])
    }

    function test_maximizedLaunchRestoresFittedNormalGeometry() {
        config.state = { x: 346, y: -146, width: 1920, height: 1040, maximized: true }
        startup.initializeWindow()
        tryCompare(testWindow, "visibility", Window.Maximized)
        persistence.requestRestoreNormalWindow()
        tryCompare(testWindow, "visibility", Window.Windowed)
        compare([testWindow.x, testWindow.y, testWindow.width, testWindow.height], [0, 0, 800, 800])
    }

    function test_savedWindowFitsScreen() {
        startup.initializeWindow()
        wait(0)
        var screen = testWindow.screen
        var bounds = Qt.rect(screen.virtualX, screen.virtualY,
                             screen.desktopAvailableWidth, screen.desktopAvailableHeight)
        verify(testWindow.x >= bounds.x && testWindow.y >= bounds.y
               && testWindow.x + testWindow.width <= bounds.x + bounds.width
               && testWindow.y + testWindow.height <= bounds.y + bounds.height,
               "Window is outside the work area: "
               + [testWindow.x, testWindow.y, testWindow.width, testWindow.height]
               + "; bounds=" + bounds)
        testWindow.hide()
    }
}
