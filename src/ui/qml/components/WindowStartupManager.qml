import QtQuick
import QtQuick.Controls
import QtQuick.Window

QtObject {
    id: startup
    required property ApplicationWindow window
    property var configService
    property var persistenceManager
    property var windowState: configService ? configService.getWindowState() : ({
            x: -9999,
            y: -9999,
            width: -1,
            height: -1,
            maximized: false
        })
    function resolveStartupGeometry() {
        var savedWidth = windowState.width;
        var savedHeight = windowState.height;
        return persistenceManager.fittedGeometry({
            x: windowState.x,
            y: windowState.y,
            width: savedWidth > 0 ? savedWidth : window.defaultWidth,
            height: savedHeight > 0 ? savedHeight : window.defaultHeight
        });
    }

    property int _retryCount: 0
    function initializeWindow() {
        if (!window || !configService || !persistenceManager) {
            if (_retryCount < 20) {
                _retryCount++;
                Qt.callLater(initializeWindow);
            } else {
                console.error("WindowStartupManager: 依赖在 20 次重试后仍未就绪, window=", !!window, "configService=", !!configService, "persistenceManager=", !!persistenceManager);
            }
            return;
        }

        const geometry = resolveStartupGeometry();
        const restoreMaximized = windowState.maximized;
        persistenceManager.applyGeometry(geometry);
        persistenceManager.updateNormalGeometry(window.x, window.y, window.width, window.height);
        window.visible = true;
        window.show();
        window.raise();
        window.requestActivate();
        if (restoreMaximized) {
            persistenceManager.beginStateTransition();
            Qt.callLater(function () {
                if (window) {
                    window.showMaximized();
                }
            });
        } else {
            persistenceManager.persistGeometry();
        }
    }
}
