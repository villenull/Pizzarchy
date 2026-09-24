// Installed as /usr/share/sddm/themes/omarchy-deck/Main.qml by omarchy-deck.
//
// Omarchy's own SDDM theme, loaded UNCHANGED from its package, plus an
// always-visible Qt Virtual Keyboard, so a Steam Deck with no physical
// keyboard can type its password at the Gaming=No login screen. At the
// greeter the Deck's firmware lizard mode is on: the right trackpad moves
// the pointer and R2 clicks, which is enough to press these keys.
//
// Why a wrapper and not a copy: the Omarchy theme is upstream's and changes
// with it. Loading its Main.qml by path keeps its look, its password field
// and its login call exactly as shipped; this file adds one thing.
//
// Why embedded: SDDM's InputMethod=qtvirtualkeyboard alone only selects the
// input-method plugin. With no InputPanel in the scene, the greeter (a Qt
// Quick app inside SDDM's Hyprland greeter compositor) shows no keyboard at
// all -- verified in QEMU by clicking the stock theme's password field.
import QtQuick 2.15
import QtQuick.VirtualKeyboard 2.15

Item {
  id: deck
  width: 640
  height: 480

  Loader {
    id: omarchy
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: parent.top
    anchors.bottom: keyboard.top
    focus: true
    source: "file:///usr/share/sddm/themes/omarchy/Main.qml"
  }

  InputPanel {
    id: keyboard
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    visible: true
  }

  // The stock theme focuses its password field on load; showing the input
  // method up front means no click is needed before the first key.
  Component.onCompleted: Qt.inputMethod.show()
}
