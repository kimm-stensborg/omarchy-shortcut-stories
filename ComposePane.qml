import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The new-story form. Six fields, in the order you think of them: what it is
// called, what kind of thing it is, whose board it belongs on, which sprint,
// whose it is, and then the detail.
Item {
  id: pane

  property var overlay: null
  property var store: null

  // Editing an existing story reuses this whole form rather than a second
  // copy of it: same fields, same picker wiring, just a different draft
  // underneath and a different verb at the end.
  readonly property bool editing: !!(pane.store && pane.store.editingId)
  readonly property var form: pane.overlay ? (pane.editing ? pane.overlay.editForm : pane.overlay.form) : ({})
  readonly property var refs: pane.overlay ? pane.overlay.refs : null
  readonly property bool hasRefs: pane.overlay ? pane.overlay.hasRefs : false
  readonly property bool busy: pane.store
    ? (pane.editing ? pane.store.updating : (pane.store.creating || pane.store.loadingPr)) : false
  // Nothing for Save to do until the edit differs from the story it opened
  // with. Always false outside editing -- Create has no "unchanged" to guard.
  readonly property bool unchanged: pane.editing
    && !Model.editFormDirty(pane.form, pane.overlay ? pane.overlay.editFormSeededWith : null)
  readonly property string prLabel: Model.prSourceLabel(pane.form)

  readonly property color foreground: pane.overlay ? pane.overlay.foreground : Color.menu.text
  readonly property color muted: pane.overlay ? pane.overlay.muted : Color.muted
  readonly property color accent: pane.overlay ? pane.overlay.accent : Color.accent
  readonly property string fontFamily: pane.overlay ? pane.overlay.fontFamily : Style.font.menuFamily

  readonly property string today: new Date().toISOString().slice(0, 10)

  function change(key, value) {
    var next = {}
    for (var k in pane.form) next[k] = pane.form[k]
    next[key] = value
    // Changing team re-resolves the landing state and re-filters the sprints.
    // A sprint that no longer belongs is dropped rather than sent to a team it
    // is not on.
    if (key === "groupId") {
      var allowed = Model.iterationOptions(pane.refs, value, pane.today)
      var keep = false
      for (var i = 0; i < allowed.length; i++) if (allowed[i].value === next.iterationId) keep = true
      if (!keep) next.iterationId = ""
    }
    if (!pane.overlay) return
    if (pane.editing) pane.overlay.editForm = next
    else pane.overlay.form = next
  }

  function takeFocus() { titleField.forceActiveFocus() }

  // Returns true when this pane swallowed the Escape. A dropdown that is open
  // owns it; a focused field gives up focus but keeps its text.
  function escapePressed() {
    if (teamPicker.popupOpen) { teamPicker.close(); return true }
    if (iterationPicker.popupOpen) { iterationPicker.close(); return true }
    if (ownerPicker.popupOpen) { ownerPicker.close(); return true }
    if (titleField.activeFocus || descriptionArea.activeFocus) { ring.forceActiveFocus(); return true }
    return false
  }

  function submit() {
    if (pane.busy || pane.unchanged || !pane.store) return
    if (pane.editing) pane.store.updateStory(pane.store.editingId, pane.form)
    else pane.store.createStory(pane.form)
  }

  // A pasted GitHub PR URL is looked up after a short pause so a mid-edit
  // does not fire twice, and so typing something that only looks like a URL
  // for a moment does not thrash gh.
  Timer {
    id: prLookup
    interval: 350
    onTriggered: {
      // Retitling an existing story from a PR link is not a feature the edit
      // form offers -- Save just files whatever the title says, PR-shaped or
      // not.
      if (!pane.store || pane.editing) return
      var parsed = Model.parseGithubPrUrl(pane.form.name)
      if (!parsed) return
      // Already filled from this same PR — leave the title alone.
      if (pane.form.externalLinks && pane.form.externalLinks[0] === parsed.url) return
      pane.store.lookupPr(parsed.url)
    }
  }

  // Tab walks Qt's own focus chain rather than a list kept here. A hand-rolled
  // ring cannot see into a SearchableDropdown -- the focusable thing is its
  // trigger, not the wrapper -- so focusing the wrapper silently did nothing
  // and Tab fell back to the top of the form every time.
  function step(item, direction) {
    var next = item.nextItemInFocusChain(direction > 0)
    if (next) next.forceActiveFocus()
  }

  Item { id: ring; anchors.fill: parent; visible: false }

  ColumnLayout {
    anchors.fill: parent
    spacing: Style.spacing.md

    // ---- Title.
    TextField {
      id: titleField
      Layout.fillWidth: true
      text: pane.form.name || ""
      placeholderText: pane.editing ? "What needs doing?" : "What needs doing? Or a GitHub PR link"
      foreground: pane.foreground
      accent: pane.accent
      font.family: pane.fontFamily
      font.pixelSize: Style.font.subtitle
      onTextChanged: {
        pane.change("name", text)
        prLookup.restart()
      }
      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
          // A title is one line, and this is the fast path: summon, type, Enter.
          // A PR URL on Enter is resolved first, then filed.
          pane.submit(); event.accepted = true
        } else if (event.key === Qt.Key_Tab) {
          pane.step(titleField, 1); event.accepted = true
        } else if (event.key === Qt.Key_Backtab) {
          pane.step(titleField, -1); event.accepted = true
        }
      }
    }

    // ---- Type. Three buttons rather than a dropdown, so the three shortcuts
    // are visible and an invalid value is unreachable.
    RowLayout {
      id: typeRow
      Layout.fillWidth: true
      spacing: Style.spacing.controlGap
      activeFocusOnTab: true

      Text {
        text: "Type"
        color: pane.muted
        font.family: pane.fontFamily
        font.pixelSize: Style.font.caption
        Layout.preferredWidth: Style.space(90)
      }

      Repeater {
        model: Model.storyTypes()
        Button {
          required property var modelData
          bordered: pane.form.storyType === modelData.value
          text: modelData.glyph + "  " + modelData.label
          foreground: pane.form.storyType === modelData.value ? pane.accent : pane.muted
          fontFamily: pane.fontFamily
          onClicked: pane.change("storyType", modelData.value)
        }
      }

      Item { Layout.fillWidth: true }

      Keys.onPressed: function(event) {
        var types = Model.storyTypes()
        var at = 0
        for (var i = 0; i < types.length; i++) if (types[i].value === pane.form.storyType) at = i
        if (event.key === Qt.Key_Left) { pane.change("storyType", types[(at + 2) % 3].value); event.accepted = true }
        else if (event.key === Qt.Key_Right) { pane.change("storyType", types[(at + 1) % 3].value); event.accepted = true }
        else if (event.key === Qt.Key_Tab) { pane.step(typeRow, 1); event.accepted = true }
        else if (event.key === Qt.Key_Backtab) { pane.step(typeRow, -1); event.accepted = true }
      }
    }

    // ---- Team, iteration, owner.
    RowLayout {
      Layout.fillWidth: true
      spacing: Style.spacing.controlGap

      Text {
        text: "Team"
        color: pane.muted
        font.family: pane.fontFamily
        font.pixelSize: Style.font.caption
        Layout.preferredWidth: Style.space(90)
      }

      SearchableDropdown {
        id: teamPicker
        Layout.fillWidth: true
        enabled: pane.hasRefs
        showLabel: false
        options: Model.groupOptions(pane.refs)
        value: pane.form.groupId || ""
        placeholderText: pane.hasRefs ? "Search teams..." : "Loading teams..."
        foreground: pane.foreground
        accent: pane.accent
        fontFamily: pane.fontFamily
        onChanged: function(v) { pane.change("groupId", v) }
      }
    }

    RowLayout {
      Layout.fillWidth: true
      spacing: Style.spacing.controlGap

      Text {
        text: "Iteration"
        color: pane.muted
        font.family: pane.fontFamily
        font.pixelSize: Style.font.caption
        Layout.preferredWidth: Style.space(90)
      }

      SearchableDropdown {
        id: iterationPicker
        Layout.fillWidth: true
        enabled: pane.hasRefs
        showLabel: false
        options: Model.iterationOptions(pane.refs, pane.form.groupId || "", pane.today)
        value: pane.form.iterationId || ""
        placeholderText: pane.hasRefs ? "Search iterations..." : "Loading..."
        foreground: pane.foreground
        accent: pane.accent
        fontFamily: pane.fontFamily
        onChanged: function(v) { pane.change("iterationId", v) }
      }
    }

    RowLayout {
      Layout.fillWidth: true
      spacing: Style.spacing.controlGap

      Text {
        text: "Owner"
        color: pane.muted
        font.family: pane.fontFamily
        font.pixelSize: Style.font.caption
        Layout.preferredWidth: Style.space(90)
      }

      SearchableDropdown {
        id: ownerPicker
        Layout.fillWidth: true
        enabled: pane.hasRefs
        showLabel: false
        options: Model.memberOptions(pane.refs, pane.refs && pane.refs.me ? pane.refs.me.id : "")
        value: pane.form.ownerId || ""
        placeholderText: pane.hasRefs ? "Search people..." : "Loading..."
        foreground: pane.foreground
        accent: pane.accent
        fontFamily: pane.fontFamily
        onChanged: function(v) { pane.change("ownerId", v) }
      }
    }

    // ---- Linked PR. Edit only: create already links a story from a pasted
    // PR title (see the prLookup timer above), and retitling an existing
    // story from a paste is not something this form offers, so this is the
    // one place attaching, changing or clearing the link lives. Any other
    // external link the story already had (a doc, a Figma file) rides along
    // untouched -- see Model.formFromDetail and buildUpdateRequest.
    RowLayout {
      Layout.fillWidth: true
      visible: pane.editing
      spacing: Style.spacing.controlGap

      Text {
        text: "Linked PR"
        color: pane.muted
        font.family: pane.fontFamily
        font.pixelSize: Style.font.caption
        Layout.preferredWidth: Style.space(90)
      }

      TextField {
        id: prField
        Layout.fillWidth: true
        text: (pane.form.externalLinks && pane.form.externalLinks[0]) || ""
        placeholderText: "https://github.com/owner/repo/pull/123"
        foreground: pane.foreground
        accent: pane.accent
        font.family: pane.fontFamily
        font.pixelSize: Style.font.body
        onTextChanged: pane.change("externalLinks", text.trim() === "" ? [] : [text])
        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Tab) { pane.step(prField, 1); event.accepted = true }
          else if (event.key === Qt.Key_Backtab) { pane.step(prField, -1); event.accepted = true }
        }
      }
    }

    Text {
      Layout.fillWidth: true
      visible: pane.editing && !!(pane.form.externalLinks && pane.form.externalLinks[0])
      elide: Text.ElideRight
      color: pane.muted
      font.family: pane.fontFamily
      font.pixelSize: Style.font.caption
      text: pane.prLabel !== "" ? "Linked to " + pane.prLabel
                                : "Not recognized as a GitHub pull request link"
    }

    // ---- Description.
    QQC.ScrollView {
      Layout.fillWidth: true
      Layout.fillHeight: true
      clip: true

      QQC.TextArea {
        id: descriptionArea
        text: pane.form.description || ""
        placeholderText: "Anything more? (optional, markdown)"
        wrapMode: TextEdit.Wrap
        color: pane.foreground
        placeholderTextColor: pane.muted
        selectionColor: Style.selectionFillFor(pane.foreground, pane.accent)
        font.family: pane.fontFamily
        font.pixelSize: Style.font.body
        background: null
        onTextChanged: pane.change("description", text)
        Keys.onPressed: function(event) {
          // Enter is a newline here and nowhere else in the form; Ctrl+Enter
          // is what files the story from inside it.
          if (event.key === Qt.Key_Tab) { pane.step(descriptionArea, 1); event.accepted = true }
          else if (event.key === Qt.Key_Backtab) { pane.step(descriptionArea, -1); event.accepted = true }
        }
      }
    }

    // ---- Where it lands, and the button.
    RowLayout {
      Layout.fillWidth: true
      spacing: Style.spacing.md

      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.spacing.xs

        Text {
          Layout.fillWidth: true
          // Where a new story lands is a landing state picked from the team --
          // exactly what an edit must not silently do to a story that already
          // has one. "Move to" on the detail view is the place for that.
          visible: !pane.editing
          elide: Text.ElideRight
          color: pane.muted
          font.family: pane.fontFamily
          font.pixelSize: Style.font.caption
          // "Loading" has to stop being the answer once the load has failed,
          // or the line sits there claiming progress that is not happening.
          text: pane.hasRefs ? Model.destinationLabel(pane.form, pane.refs)
            : (pane.store && pane.store.failure ? "Your workspace could not be read — Ctrl+R retries"
                                                : "Loading your workspace...")
        }

        Text {
          Layout.fillWidth: true
          // The edit form has its own line, right under the Linked PR field --
          // this one is about a title just pasted in, which editing never does.
          visible: !pane.editing && (pane.prLabel !== "" || !!(pane.store && pane.store.loadingPr))
          elide: Text.ElideRight
          color: pane.muted
          font.family: pane.fontFamily
          font.pixelSize: Style.font.caption
          text: pane.store && pane.store.loadingPr
            ? "Reading the pull request…"
            : (pane.prLabel !== "" ? "From " + pane.prLabel : "")
        }
      }

      Button {
        visible: pane.editing
        bordered: true
        // Mid-save, Cancel would read as "discard this" while the write is
        // already on its way -- same reasoning as disabling Save itself.
        enabled: !pane.busy
        text: "Cancel"
        foreground: pane.muted
        fontFamily: pane.fontFamily
        onClicked: if (pane.store) pane.store.cancelEdit()
      }

      Button {
        bordered: true
        enabled: !pane.busy && !pane.unchanged
        text: pane.editing
          ? (pane.store && pane.store.updating ? "Saving..." : "Save changes")
          : (pane.store && pane.store.loadingPr ? "Reading…"
            : (pane.store && pane.store.creating ? "Filing..." : "Create story"))
        foreground: (pane.busy || pane.unchanged) ? pane.muted : pane.accent
        fontFamily: pane.fontFamily
        onClicked: pane.submit()
      }
    }
  }

  // Ctrl+Enter files the story wherever the focus happens to be, and the type
  // shortcuts work from any field so you never have to go back for them.
  Keys.priority: Keys.BeforeItem
  Keys.onPressed: function(event) {
    var ctrl = (event.modifiers & Qt.ControlModifier) !== 0
    var alt = (event.modifiers & Qt.AltModifier) !== 0
    if (ctrl && (event.key === Qt.Key_Return || event.key === Qt.Key_Enter)) {
      pane.submit(); event.accepted = true
    } else if (alt && event.key === Qt.Key_F) {
      pane.change("storyType", "feature"); event.accepted = true
    } else if (alt && event.key === Qt.Key_B) {
      pane.change("storyType", "bug"); event.accepted = true
    } else if (alt && event.key === Qt.Key_C) {
      pane.change("storyType", "chore"); event.accepted = true
    }
  }
}
