import QtQuick
import QtQuick.Controls
import QtQuick.Window

QtObject {
    id: persistence
    required property ApplicationWindow window
    property var configService
    property real normalX: window.x
    property real normalY: window.y
    property real normalWidth: window.width
    property real normalHeight: window.height
    property bool stateTransitionInProgress: false
    property bool pendingNormalRestore: false
    property bool applyingGeometry: false
    property var screenWorkAreas: window && window.screenWorkAreas ? window.screenWorkAreas : []
    onScreenWorkAreasChanged: clampGeometry()
    function updateNormalGeometry(x, y, width, height) {
        normalX = x;
        normalY = y;
        normalWidth = width;
        normalHeight = height;
    }

    function captureNormalGeometry() {
        if (!window) {
            return;
        }

        updateNormalGeometry(window.x, window.y, window.width, window.height);
    }

    function availableBounds(geometry) {
        const areas = screenWorkAreas;
        if (areas && areas.length > 0) {
            var best = areas[0];
            var largestOverlap = 0;
            for (var i = 0; i < areas.length; ++i) {
                const area = areas[i];
                const overlapWidth = Math.max(0, Math.min(geometry.x + geometry.width, area.x + area.width) - Math.max(geometry.x, area.x));
                const overlapHeight = Math.max(0, Math.min(geometry.y + geometry.height, area.y + area.height) - Math.max(geometry.y, area.y));
                const overlap = overlapWidth * overlapHeight;
                if (overlap > largestOverlap) {
                    largestOverlap = overlap;
                    best = area;
                }
            }
            return best;
        }
        const screen = window.screen;
        return Qt.rect(screen.virtualX, screen.virtualY, screen.desktopAvailableWidth, screen.desktopAvailableHeight);
    }

    function fittedGeometry(geometry) {
        const bounds = availableBounds(geometry);
        const width = Math.min(Math.max(geometry.width, window.minimumWidth), bounds.width);
        const height = Math.min(Math.max(geometry.height, window.minimumHeight), bounds.height);
        const x = isFinite(geometry.x) && geometry.x !== -9999 ? geometry.x : bounds.x + Math.round((bounds.width - width) / 2);
        const y = isFinite(geometry.y) && geometry.y !== -9999 ? geometry.y : bounds.y + Math.round((bounds.height - height) / 2);
        return {
            x: Math.max(bounds.x, Math.min(x, bounds.x + bounds.width - width)),
            y: Math.max(bounds.y, Math.min(y, bounds.y + bounds.height - height)),
            width: width,
            height: height
        };
    }

    function clampGeometry() {
        if (!window || applyingGeometry || window.visibility === Window.Maximized || window.visibility === Window.FullScreen || window.visibility === Window.Minimized)
            return;
        const geometry = fittedGeometry({ x: window.x, y: window.y, width: window.width, height: window.height });
        applyGeometry(geometry);
    }

    function applyGeometry(geometry) {
        applyingGeometry = true;
        const centerX = geometry.x + geometry.width / 2;
        const centerY = geometry.y + geometry.height / 2;
        const screens = Qt.application.screens;
        for (var i = 0; i < screens.length; ++i) {
            const screen = screens[i];
            if (centerX >= screen.virtualX && centerX < screen.virtualX + screen.width && centerY >= screen.virtualY && centerY < screen.virtualY + screen.height) {
                window.screen = screen;
                break;
            }
        }
        window.width = geometry.width;
        window.height = geometry.height;
        window.x = geometry.x;
        window.y = geometry.y;
        applyingGeometry = false;
    }

    function persistGeometry() {
        if (!configService || !window) {
            return;
        }

        const isSpecialState = window.visibility === Window.Maximized || window.visibility === Window.FullScreen || window.visibility === Window.Minimized;
        const widthToSave = isSpecialState ? normalWidth : window.width;
        const heightToSave = isSpecialState ? normalHeight : window.height;
        const xToSave = isSpecialState ? normalX : window.x;
        const yToSave = isSpecialState ? normalY : window.y;
        configService.setWindowState({
            x: Math.round(xToSave),
            y: Math.round(yToSave),
            width: Math.round(widthToSave),
            height: Math.round(heightToSave),
            maximized: window.visibility === Window.Maximized
        });
    }

    function beginStateTransition() {
        stateTransitionInProgress = true;
    }

    function requestRestoreNormalWindow() {
        if (!window) {
            return;
        }

        pendingNormalRestore = true;
        beginStateTransition();
        window.showNormal();
    }

    property Connections windowConnections: Connections {
        target: persistence.window
        function onXChanged() {
            if (persistence.window.visibility === Window.Windowed && !persistence.stateTransitionInProgress) {
                persistence.normalX = persistence.window.x;
            }
        }

        function onYChanged() {
            if (persistence.window.visibility === Window.Windowed && !persistence.stateTransitionInProgress) {
                persistence.normalY = persistence.window.y;
            }
        }

        function onWidthChanged() {
            if (persistence.window.visibility === Window.Windowed && !persistence.stateTransitionInProgress) {
                persistence.normalWidth = persistence.window.width;
            }
        }

        function onHeightChanged() {
            if (persistence.window.visibility === Window.Windowed && !persistence.stateTransitionInProgress) {
                persistence.normalHeight = persistence.window.height;
            }
        }

        function onVisibilityChanged() {
            if (persistence.window.visibility === Window.Windowed && persistence.pendingNormalRestore) {
                persistence.window.x = Math.round(persistence.normalX);
                persistence.window.y = Math.round(persistence.normalY);
                persistence.window.width = Math.round(persistence.normalWidth);
                persistence.window.height = Math.round(persistence.normalHeight);
                persistence.clampGeometry();
                persistence.pendingNormalRestore = false;
            } else if (persistence.window.visibility !== Window.Windowed) {
                persistence.pendingNormalRestore = false;
            }

            persistence.stateTransitionInProgress = false;
            persistence.persistGeometry();
        }

        function onScreenChanged() {
            if (persistence.window.visibility === Window.Windowed)
                persistence.clampGeometry();
        }
    }
}
