import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC
import qs.Commons
import qs.Ui
import "Model.js" as Model

// What Alt+P is about to do, before it does it: push sc-<id> to origin and
// open a pull request from it. The agent was told not to push, so this
// screen is the one door to GitHub, and nothing goes through it until Enter.
Item {
  id: view

  property var overlay: null
  property var store: null

  readonly property var raw: view.store ? view.store.detail : null
  readonly property bool opening: !!(view.store && view.store.openingPr)
  readonly property string fontFamily: view.overlay ? view.overlay.fontFamily : Style.font.menuFamily
  readonly property color foreground: view.overlay ? view.overlay.foreground : Color.menu.text
  readonly property color muted: view.overlay ? view.overlay.muted : Color.muted
  readonly property color accent: view.overlay ? view.overlay.accent : Color.accent
  readonly property color urgent: view.overlay ? view.overlay.urgent : Color.urgent

  // Filled once when the screen opens and edited from there. A status poll
  // arriving mid-edit must not put the title back.
  property var draft: ({})

  function prepare() {
    view.draft = view.raw && view.store ? Model.prDraft(view.raw, view.store.solveStatus) : ({})
    titleField.text = view.draft.title || ""
    bodyArea.text = view.draft.body || ""
  }

  function change(key, value) {
    var next = {}
    for (var k in view.draft) next[k] = view.draft[k]
    next[key] = value
    view.draft = next
  }

  readonly property bool ready: !view.opening && String(view.draft.title || "").trim() !== ""

  function submit() {
    if (!view.ready || !view.store) return
    view.store.openPr({
      dir: view.draft.dir, branch: view.draft.branch, base: view.draft.base,
      title: String(view.draft.title).trim(), body: String(view.draft.body || "").replace(/\s+$/, ""),
      draft: view.draft.draft === true
    })
  }

  // Lands on the screen, not in the title, so Enter and D work straight
  // away; Tab goes into the title, and on to the description.
  function takeFocus() { keys.forceActiveFocus() }

  function escapePressed() {
    if (view.opening) return true
    if (bodyArea.activeFocus || titleField.activeFocus) { keys.forceActiveFocus(); return true }
    if (view.store) view.store.closePrReview()
    return true
  }

  Component.onCompleted: view.prepare()

  Item {
    id: keys
    anchors.fill: parent
    focus: true

    Keys.priority: Keys.BeforeItem
    Keys.onPressed: function(event) {
      if (view.opening) { event.accepted = true; return }
      var ctrl = (event.modifiers & Qt.ControlModifier) !== 0
      var alt = (event.modifiers & Qt.AltModifier) !== 0
      if (ctrl && (event.key === Qt.Key_Return || event.key === Qt.Key_Enter)) {
        view.submit(); event.accepted = true; return
      }
      // In the body the keys are text; Enter is a new line there.
      if (bodyArea.activeFocus || titleField.activeFocus) return
      if (event.key === Qt.Key_Tab) {
        titleField.forceActiveFocus(); event.accepted = true
      } else if (event.key === Qt.Key_D && !ctrl && !alt) {
        view.change("draft", view.draft.draft !== true); event.accepted = true
      } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
        view.submit(); event.accepted = true
      }
    }

    ColumnLayout {
      anchors.fill: parent
      spacing: Style.spacing.md

      RowLayout {
        Layout.fillWidth: true
        spacing: Style.spacing.sm

        Button {
          bordered: false
          text: ""
          tooltipText: "Back to the story (Esc)"
          foreground: view.muted
          fontFamily: view.fontFamily
          onClicked: if (view.store) view.store.closePrReview()
        }

        Text {
          Layout.fillWidth: true
          elide: Text.ElideRight
          text: "Pull request from " + (view.draft.branch || "the story branch")
          color: view.foreground
          font.family: view.fontFamily
          font.pixelSize: Style.font.subtitle
          font.bold: true
        }

        Button {
          bordered: true
          enabled: view.ready
          text: view.opening ? "Opening..." : "Push and open"
          foreground: view.accent
          fontFamily: view.fontFamily
          onClicked: view.submit()
        }
      }

      Text {
        Layout.fillWidth: true
        visible: !!(view.store && view.store.openPrError !== "")
        wrapMode: Text.Wrap
        text: view.store ? view.store.openPrError : ""
        color: view.urgent
        font.family: view.fontFamily
        font.pixelSize: Style.font.caption
      }

      // ---- Where from, where to, and how much.
      Text {
        Layout.fillWidth: true
        elide: Text.ElideRight
        text: (view.draft.branch || "") + " → " + (view.draft.base || "the default branch")
          + (typeof view.draft.ahead === "number"
             ? " · " + view.draft.ahead + (view.draft.ahead === 1 ? " commit" : " commits") : "")
        color: view.foreground
        font.family: view.fontFamily
        font.pixelSize: Style.font.body
      }

      Text {
        Layout.fillWidth: true
        elide: Text.ElideMiddle
        text: view.draft.dir || ""
        color: view.muted
        font.family: view.fontFamily
        font.pixelSize: Style.font.caption
      }

      // Pushing sends commits, not the working tree, so work the agent left
      // uncommitted would silently stay behind.
      Text {
        Layout.fillWidth: true
        visible: view.draft.dirty === true
        wrapMode: Text.Wrap
        text: "There are uncommitted changes there. They are not part of this pull request."
        color: view.urgent
        font.family: view.fontFamily
        font.pixelSize: Style.font.caption
      }

      PanelSeparator { Layout.fillWidth: true }

      RowLayout {
        Layout.fillWidth: true
        spacing: Style.spacing.controlGap

        Text {
          text: "Title"
          color: view.muted
          font.family: view.fontFamily
          font.pixelSize: Style.font.caption
          Layout.preferredWidth: Style.space(90)
        }

        TextField {
          id: titleField
          Layout.fillWidth: true
          foreground: view.foreground
          accent: view.accent
          font.family: view.fontFamily
          font.pixelSize: Style.font.body
          onTextChanged: view.change("title", text)
          Keys.onPressed: function(event) {
            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
              view.submit(); event.accepted = true
            } else if (event.key === Qt.Key_Tab) {
              bodyArea.forceActiveFocus(); event.accepted = true
            }
          }
        }
      }

      RowLayout {
        Layout.fillWidth: true
        spacing: Style.spacing.md

        Text {
          text: "Draft"
          color: view.muted
          font.family: view.fontFamily
          font.pixelSize: Style.font.caption
          Layout.preferredWidth: Style.space(90)
        }

        Button {
          bordered: view.draft.draft === true
          text: view.draft.draft === true ? "Yes" : "No"
          fontSize: Style.font.bodySmall
          foreground: view.draft.draft === true ? view.accent : view.foreground
          fontFamily: view.fontFamily
          onClicked: view.change("draft", view.draft.draft !== true)
        }

        Item { Layout.fillWidth: true }
      }

      Text {
        text: "Description"
        color: view.muted
        font.family: view.fontFamily
        font.pixelSize: Style.font.caption
      }

      QQC.ScrollView {
        Layout.fillWidth: true
        Layout.fillHeight: true
        clip: true

        QQC.TextArea {
          id: bodyArea
          placeholderText: "What the pull request says (markdown)"
          wrapMode: TextEdit.Wrap
          color: view.foreground
          placeholderTextColor: view.muted
          selectionColor: Style.selectionFillFor(view.foreground, view.accent)
          font.family: view.fontFamily
          font.pixelSize: Style.font.body
          background: null
          onTextChanged: view.change("body", text)
        }
      }
    }
  }
}
