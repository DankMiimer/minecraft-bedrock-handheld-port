import QtQuick
import QtQuick.Window
import QtQuick.VirtualKeyboard
import QtWebEngine

Window {
    id: root
    width: 720
    height: 480
    visible: true
    visibility: Window.FullScreen
    color: "white"
    title: "Google Sign-In"
    property bool signInCaptured: false

    Connections {
        target: handheldController
        function onKeyboardNavigationKey(key) {
            InputContext.priv.navigationKeyPressed(key, false)
            InputContext.priv.navigationKeyReleased(key, false)
        }
    }

    Connections {
        target: signinBridge
        function onCaptureCompleted() {
            root.signInCaptured = true
        }
    }

    WebEngineView {
        id: browser
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.bottom: keyboard.active ? keyboard.top : parent.bottom
        focus: true
        url: "https://accounts.google.com/embedded/setup/v2/android?source=com.android.settings&xoauth_display_name=Android%20Phone&canFrp=1&canSk=1&lang=en&langCountry=en_us&hl=en-US&cc=us"

        onJavaScriptConsoleMessage: function(level, message, lineNumber, sourceId) {
            signinBridge.consoleMessage(message)
        }
    }

    InputPanel {
        id: keyboard
        z: 10
        width: parent.width
        y: active ? parent.height - height : parent.height
    }

    Rectangle {
        anchors.fill: parent
        z: 30
        visible: root.signInCaptured
        color: "#17365d"

        Text {
            anchors.centerIn: parent
            width: parent.width - 80
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            color: "white"
            font.pixelSize: 27
            text: "Sign-in approved\n\nFinishing Google Play setup…"
        }
    }
}
