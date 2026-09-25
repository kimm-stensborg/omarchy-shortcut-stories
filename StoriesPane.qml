import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as Controls
import Quickshell
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The stories assigned to you, grouped by what kind of state they are in --
// what you are doing, and what is waiting. A row is a glance: reference, name
// and state. Enter or a click opens the story itself, which is where the
// description and everything else lives.
Item {
  id: pane

  property var overlay: null
  property var store: null

  readonly property var refs: pane.overlay ? pane.overlay.refs : null
  readonly property string scope: pane.overlay ? pane.overlay.listScope : "all"
  readonly property string today: pane.overlay && pane.overlay.today
    ? pane.overlay.today : new Date().toISOString().slice(0, 10)
  readonly property string sprintLabel: Model.currentIterationLabel(pane.refs, pane.today)
  // Whose stories: you, the default team, or one teammate on it.
  readonly property string owner: pane.store ? pane.store.listOwner : "me"
  readonly property var ownerOptions: pane.store ? Model.listOwnerOptions(pane.refs, pane.store.teamId) : []
  readonly property bool others: pane.owner !== "me"
  readonly property bool othersReady: !!(pane.store && pane.store.otherFor === pane.owner)
  readonly property bool loading: pane.others ? !pane.othersReady
    : (pane.store ? pane.store.loadingStories : false)
  readonly property int moving: pane.store ? pane.store.movingStory : 0

  readonly property color foreground: pane.overlay ? pane.overlay.foreground : Color.menu.text
  readonly property color muted: pane.overlay ? pane.overlay.muted : Color.muted
  readonly property color accent: pane.overlay ? pane.overlay.accent : Color.accent
  readonly property var themeColors: pane.overlay ? pane.overlay.themeColors : ({})
  readonly property color background: pane.overlay ? pane.overlay.background : Color.menu.background

  // The filter's pills: one height, and a colour at a given strength.
  readonly property int pillHeight: Style.spacing.controlHeight + Style.space(6)
  readonly property int pillInset: 4
  function tint(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }
  readonly property string fontFamily: pane.overlay ? pane.overlay.fontFamily : Style.font.menuFamily

  // The sections flattened into rows, because a ListView wants one model and
  // the headers have to be walked past by the cursor anyway.
  readonly property var listedStories: !pane.store ? []
    : (pane.others ? (pane.othersReady ? pane.store.otherStories : []) : pane.store.stories)
  readonly property var scopedStories: Model.storiesInScope(pane.listedStories, pane.refs, pane.scope, pane.today)

  // How many open stories each half of the filter holds, on the filter itself,
  // so the size of a list is known before scrolling it.
  readonly property string allCount: String(Math.max(Model.openCount(pane.listedStories, pane.refs),
    !pane.store ? 0 : (pane.others ? pane.store.otherTotal : pane.store.storiesTotal)))
  // What the scope pill offers. The sprint is only there when one is on.
  readonly property var scopeOptions: {
    var out = [{ value: "all", label: "All · " + pane.allCount }]
    if (pane.sprintLabel !== "") out.push({ value: "current", label: pane.sprintLabel + " · " + pane.sprintCount })
    return out
  }
  readonly property string sprintCount: String(Model.openCount(
    Model.storiesInScope(pane.listedStories, pane.refs, "current", pane.today), pane.refs))

  // What you finished only reads as progress against a sprint. Across
  // everything assigned to you it is just a pile that keeps growing.
  // What is typed in the search, and the list narrowed by it.
  property string query: ""
  readonly property var searchedStories: Model.searchStories(pane.scopedStories, pane.refs, pane.query)

  readonly property var allRows: Model.storyRows(
    Model.sectionStories(pane.searchedStories, pane.refs, pane.scope === "current"))

  TextMetrics {
    id: refWidth
    font.family: pane.fontFamily
    font.pixelSize: Style.font.caption
    text: "sc-00000"
  }

  // A team's list can run to hundreds. It is all fetched at once, but drawn a
  // page at a time: the next page lands as the list reaches its bottom.
  readonly property int pageSize: 100
  property int shown: pane.pageSize
  readonly property var rows: Model.firstStories(pane.allRows, pane.shown)
  readonly property bool hasMore: pane.rows.length < pane.allRows.length
  // A different list starts at its top. Anything else -- the next page, a
  // refresh underneath -- keeps you where you were.
  property bool scrollToTop: false
  onScopeChanged: { pane.shown = pane.pageSize; pane.scrollToTop = true }
  onOwnerChanged: { pane.shown = pane.pageSize; pane.scrollToTop = true }
  onQueryChanged: { pane.shown = pane.pageSize; pane.scrollToTop = true }

  // The spinner in the footer goes up first, and the page is only drawn once
  // a frame with it has been painted -- drawing a page holds the thread, and
  // a spinner that appears after the pause says nothing. It then stays up
  // long enough to be seen rather than flickering.
  property bool pageLoading: false
  function showMore() {
    if (!pane.hasMore || pane.pageLoading) return
    pane.pageLoading = true
    pageSpinnerHold.restart()
    pageAfterPaint.restart()
  }
  Timer { id: pageAfterPaint; interval: 50; onTriggered: pane.shown += pane.pageSize }
  Timer { id: pageSpinnerHold; interval: 500; onTriggered: pane.pageLoading = false }

  // How far above the bottom the next page is asked for, so it is usually
  // there before you reach it.
  readonly property int prefetchDistance: 200

  // "3 hours ago" has to move on while the panel sits open.
  property real now: Date.now() / 1000
  Timer { interval: 60000; repeat: true; running: pane.visible; onTriggered: pane.now = Date.now() / 1000 }

  property int cursor: 0

  // A refresh, or narrowing to the sprint, can leave the cursor on a header
  // or past the end. Put it back on a story.
  // The list's model is only a count: each row reads pane.rows at its index.
  // A new page is then rows added at the end, which builds only what comes
  // into view, and a refresh underneath changes what rows say without the
  // list being rebuilt. Handing a ListView a whole new array instead rebuilds
  // it from scratch -- slow for a team's list, and back at the top.
  ListModel { id: rowSlots }
  function syncRows() {
    var n = pane.rows.length
    if (rowSlots.count > n) rowSlots.remove(n, rowSlots.count - n)
    if (rowSlots.count < n) {
      var more = []
      for (var i = rowSlots.count; i < n; i++) more.push({ slot: i })
      rowSlots.append(more)
    }
  }

  onRowsChanged: {
    pane.syncRows()
    if (pane.scrollToTop) { pane.scrollToTop = false; list.positionViewAtBeginning() }
    if (pane.cursor >= pane.rows.length
        || (pane.rows.length && pane.rows[pane.cursor] && pane.rows[pane.cursor].kind !== "story"))
      pane.cursor = pane.firstStoryRow()
  }

  function setScope(next) {
    if (!pane.store || next === pane.scope) return
    pane.store.persist("listScope", next)
  }

  function toggleScope() {
    if (pane.scope === "current") pane.setScope("all")
    else if (pane.sprintLabel !== "") pane.setScope("current")
  }

  function firstStoryRow() {
    for (var i = 0; i < pane.rows.length; i++) if (pane.rows[i].kind === "story") return i
    return 0
  }

  function moveCursor(step) {
    // Walking off the last story drawn brings in the next page, rather than
    // wrapping to the top of a list that does not end there.
    if (step > 0 && pane.hasMore && pane.cursor >= pane.rows.length - 1) pane.showMore()
    var at = pane.cursor
    for (var n = 0; n < pane.rows.length; n++) {
      at = (at + step + pane.rows.length) % pane.rows.length
      if (pane.rows[at].kind === "story") { pane.cursor = at; list.positionViewAtIndex(at, ListView.Contain); return }
    }
  }

  function currentStory() {
    var row = pane.rows[pane.cursor]
    return row && row.kind === "story" ? row.story : null
  }

  function takeFocus() {
    if (pane.rows.length && pane.rows[pane.cursor] && pane.rows[pane.cursor].kind !== "story")
      pane.cursor = pane.firstStoryRow()
    keys.forceActiveFocus()
  }

  function escapePressed() {
    if (ownerPicker.popupOpen) { ownerPicker.close(); keys.forceActiveFocus(); return true }
    if (scopePicker.popupOpen) { scopePicker.close(); keys.forceActiveFocus(); return true }
    // Esc empties the search, then leaves it; the next one goes on as before.
    if (pane.query !== "") { pane.query = ""; keys.forceActiveFocus(); return true }
    if (searchInput.activeFocus) { keys.forceActiveFocus(); return true }
    return false
  }

  function setOwner(next) {
    if (!pane.store || next === pane.owner) return
    pane.store.persist("listOwner", next)
  }

  function ownerLabel() {
    for (var i = 0; i < pane.ownerOptions.length; i++)
      if (pane.ownerOptions[i].value === pane.owner) return pane.ownerOptions[i].label
    return ""
  }

  // Opening a story used to expand its states in the row. The row had no
  // space for anything you would actually read, so it opens the detail view
  // instead and the states moved in there with it.
  function activate() {
    var story = pane.currentStory()
    if (!story || !pane.store) return
    pane.store.showStory(story.id)
  }

  function openInBrowser() {
    var story = pane.currentStory()
    if (story && story.appUrl) Quickshell.execDetached(["omarchy-launch-browser", story.appUrl])
  }

  Item {
    id: keys
    anchors.fill: parent
    focus: true

    Keys.priority: Keys.BeforeItem
    Keys.onPressed: function(event) {
      var ctrl = (event.modifiers & Qt.ControlModifier) !== 0
      if (ctrl && event.key === Qt.Key_O) { pane.openInBrowser(); event.accepted = true; return }

      if ((event.modifiers & Qt.AltModifier) && event.key === Qt.Key_I) {
        pane.toggleScope(); event.accepted = true; return
      }
      if ((event.modifiers & Qt.AltModifier) && event.key === Qt.Key_O) {
        if (pane.ownerOptions.length) ownerPicker.open()
        event.accepted = true; return
      }
      if (event.key === Qt.Key_Down) { pane.moveCursor(1); event.accepted = true }
      else if (event.key === Qt.Key_Up) { pane.moveCursor(-1); event.accepted = true }
      else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
        pane.activate(); event.accepted = true
      }
      // Anything else you type is a search. ? stays the key card, and a
      // leading space is nothing.
      else if (!ctrl && !(event.modifiers & Qt.AltModifier) && event.text.length === 1
               && event.text >= " " && event.text !== "?" && event.text !== " ") {
        pane.query += event.text
        searchInput.forceActiveFocus()
        searchInput.cursorPosition = searchInput.text.length
        event.accepted = true
      }
    }

    ColumnLayout {
      anchors.fill: parent
      spacing: Style.spacing.sm

      // The filter, on the right: which stories, then whose. Both are the
      // same soft pill -- an icon, what is chosen, how many, a chevron -- and
      // open the same searchable list. Whose is only there with a default
      // team: without one there is no one else to pick.
      RowLayout {
        Layout.fillWidth: true
        Layout.topMargin: Style.spacing.lg
        Layout.bottomMargin: Style.spacing.xs
        visible: !!pane.refs
        spacing: Style.spacing.md

        // The search: a pill like the filters beside it. Typing anywhere on
        // the list lands here; the arrows and Enter still walk and open.
        Rectangle {
          Layout.preferredWidth: Style.space(320)
          Layout.preferredHeight: pane.pillHeight
          radius: height / 2
          color: searchInput.activeFocus ? pane.tint(pane.foreground, 0.10)
            : pane.tint(pane.foreground, searchMouse.containsMouse ? 0.10 : 0.06)
          border.width: searchInput.activeFocus ? 1 : 0
          border.color: pane.tint(pane.accent, 0.6)
          Behavior on color { ColorAnimation { duration: 120 } }

          MouseArea {
            id: searchMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.IBeamCursor
            onClicked: searchInput.forceActiveFocus()
          }

          Text {
            id: searchIcon
            anchors.left: parent.left
            anchors.leftMargin: Style.spacing.controlPaddingX * 1.5
            anchors.verticalCenter: parent.verticalCenter
            text: "\uf002"
            color: searchInput.activeFocus || pane.query !== "" ? pane.accent : pane.muted
            font.family: pane.fontFamily
            font.pixelSize: Style.font.caption
          }

          TextInput {
            id: searchInput
            anchors.left: searchIcon.right
            anchors.right: clearSearch.visible ? clearSearch.left : parent.right
            anchors.leftMargin: Style.spacing.sm
            anchors.rightMargin: Style.spacing.controlPaddingX
            anchors.verticalCenter: parent.verticalCenter
            clip: true
            text: pane.query
            onTextEdited: pane.query = text
            color: pane.foreground
            selectionColor: pane.tint(pane.accent, 0.35)
            font.family: pane.fontFamily
            font.pixelSize: Style.font.body

            // The list's keys still work from here.
            Keys.onPressed: function(event) {
              if (event.key === Qt.Key_Down) { pane.moveCursor(1); event.accepted = true }
              else if (event.key === Qt.Key_Up) { pane.moveCursor(-1); event.accepted = true }
              else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                pane.activate(); event.accepted = true
              }
            }

            Text {
              anchors.fill: parent
              verticalAlignment: Text.AlignVCenter
              visible: searchInput.text === ""
              text: "Search stories"
              color: pane.muted
              font.family: pane.fontFamily
              font.pixelSize: Style.font.body
            }
          }

          Text {
            id: clearSearch
            visible: pane.query !== ""
            anchors.right: parent.right
            anchors.rightMargin: Style.spacing.controlPaddingX * 1.5
            anchors.verticalCenter: parent.verticalCenter
            text: "\uf00d"
            color: clearMouse.containsMouse ? pane.foreground : pane.muted
            font.family: pane.fontFamily
            font.pixelSize: Style.font.caption

            MouseArea {
              id: clearMouse
              anchors.fill: parent
              anchors.margins: -Style.spacing.sm
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: { pane.query = ""; keys.forceActiveFocus() }
            }
          }
        }

        Item { Layout.fillWidth: true }

        FilterPill {
          id: scopePicker
          icon: pane.scope === "current" ? "\uf073" : "\uf03a"
          label: pane.scope === "current" && pane.sprintLabel !== "" ? pane.sprintLabel : "All"
          count: pane.loading ? "" : (pane.scope === "current" ? pane.sprintCount : pane.allCount)
          highlighted: pane.scope === "current"
          options: pane.scopeOptions
          value: pane.scope === "current" ? "current" : "all"
          onPicked: function(v) { pane.setScope(v) }
        }

        FilterPill {
          id: ownerPicker
          visible: pane.ownerOptions.length > 0
          icon: pane.owner === "team" ? "\uf0c0" : "\uf007"
          label: pane.ownerLabel()
          highlighted: pane.others
          options: pane.ownerOptions
          value: pane.owner
          placeholderText: "Search teammates..."
          onPicked: function(v) { pane.setOwner(v) }
        }
      }

      // The list, or in its place a line saying why there is none. Either
      // way it keeps the room under the filter, so the filter stays at the
      // top while a list loads instead of drifting to the middle.
      Item {
        Layout.fillWidth: true
        Layout.fillHeight: true
        // Room between the filter and the first heading, so the list does not
        // read as part of the buttons above it.
        Layout.topMargin: Style.spacing.xl

        Column {
          anchors.centerIn: parent
          visible: !pane.rows.length
          spacing: Style.spacing.sm

          Text {
            id: loader
            property int tick: 0
            anchors.horizontalCenter: parent.horizontalCenter
            visible: pane.loading || !pane.refs
            text: Model.loaderFrame(loader.tick, 18)
            color: pane.accent
            font.family: pane.fontFamily
            font.pixelSize: Style.font.body
            Timer {
              interval: 70
              repeat: true
              running: loader.visible && pane.visible
              onTriggered: loader.tick++
            }
          }

          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            color: pane.muted
            font.family: pane.fontFamily
            font.pixelSize: Style.font.body
            text: !pane.refs ? "Loading your workspace..."
              : (pane.loading ? Model.loadingListText(pane.owner, pane.ownerLabel())
                : (pane.query.trim() !== "" ? "No stories match \u201c" + pane.query.trim() + "\u201d."
                  : Model.emptyListText(pane.owner, pane.ownerLabel(), pane.scope)))
          }
        }

        // The list's edges fade into the card, so a row scrolling past the
        // filter or the footer softens away instead of being cut in half.
        Rectangle {
          anchors.top: parent.top
          anchors.left: parent.left
          anchors.right: parent.right
          height: Style.space(16)
          z: 2
          visible: list.visible && !list.atYBeginning
          gradient: Gradient {
            GradientStop { position: 0; color: pane.background }
            GradientStop { position: 1; color: pane.tint(pane.background, 0) }
          }
        }

        Rectangle {
          anchors.bottom: parent.bottom
          anchors.left: parent.left
          anchors.right: parent.right
          height: Style.space(16)
          z: 2
          visible: list.visible && !list.atYEnd
          gradient: Gradient {
            GradientStop { position: 0; color: pane.tint(pane.background, 0) }
            GradientStop { position: 1; color: pane.background }
          }
        }

        ListView {
          id: list
          anchors.fill: parent
          visible: pane.rows.length > 0
          clip: true
          model: rowSlots
          Component.onCompleted: pane.syncRows()
          spacing: Style.spacing.xs
          boundsBehavior: Flickable.StopAtBounds
          onContentYChanged: {
            if (pane.hasMore
                && contentY + height >= originY + contentHeight - pane.prefetchDistance)
              pane.showMore()
          }

          // Shown only while the list moves, so a still list stays clean and
          // a scrolling one says how much is left.
          Controls.ScrollBar.vertical: Controls.ScrollBar {
            id: scrollBar
            policy: Controls.ScrollBar.AsNeeded
            width: Style.space(6)
            padding: 0
            contentItem: Rectangle {
              implicitWidth: Style.space(4)
              radius: width / 2
              color: pane.muted
              opacity: scrollBar.active ? 0.8 : 0
              Behavior on opacity { NumberAnimation { duration: 250 } }
            }
            background: Item {}
          }

        delegate: Loader {
          required property int index
          width: ListView.view.width
          property var rowData: pane.rows[index] || null
          property int rowIndex: index
          sourceComponent: !rowData ? null : (rowData.kind === "header" ? headerRow : storyRow)
        }
        }
      }
    }
  }

  // The state, in the colour of how far along it is and behind a dot of it.
  // The gap above parts one group from the last; the room under the filter
  // is the list's own margin.
  // One filter: a soft pill showing what is chosen, over the shell's
  // searchable dropdown. The dropdown sits in a slot of no height level with
  // the pill, so its own box never shows but its popup -- drawn on the
  // overlay, outside any clip -- opens just under the pill, wide enough to
  // read.
  component FilterPill: Item {
    id: pill
    property string icon: ""
    property string label: ""
    property string count: ""
    property bool highlighted: false
    property var options: []
    property string value: ""
    property string placeholderText: "Search..."
    signal picked(string value)
    readonly property bool popupOpen: dropdown.popupOpen
    function open() { dropdown.open() }
    function close() { dropdown.close() }

    implicitWidth: pillRow.implicitWidth + Style.spacing.controlPaddingX * 3
    implicitHeight: pane.pillHeight

    Item {
      anchors.top: parent.top
      anchors.right: parent.right
      width: Math.max(Style.space(240), pill.width)
      height: 0
      clip: true

      SearchableDropdown {
        id: dropdown
        width: parent.width
        showLabel: false
        rowHeight: pane.pillHeight
        options: pill.options
        value: pill.value
        placeholderText: pill.placeholderText
        foreground: pane.foreground
        accent: pane.accent
        fontFamily: pane.fontFamily
        onChanged: function(v) { pill.picked(v); keys.forceActiveFocus() }
      }
    }

    Rectangle {
      anchors.fill: parent
      radius: height / 2
      color: pill.highlighted
        ? pane.tint(pane.accent, pillMouse.containsMouse || dropdown.popupOpen ? 0.26 : 0.18)
        : pane.tint(pane.foreground, pillMouse.containsMouse || dropdown.popupOpen ? 0.12 : 0.06)
      Behavior on color { ColorAnimation { duration: 120 } }

      Row {
        id: pillRow
        anchors.centerIn: parent
        spacing: Style.spacing.sm

        Text {
          anchors.verticalCenter: parent.verticalCenter
          text: pill.icon
          color: pill.highlighted ? pane.accent : pane.muted
          font.family: pane.fontFamily
          font.pixelSize: Style.font.body
        }

        Text {
          anchors.verticalCenter: parent.verticalCenter
          text: pill.label
          color: pill.highlighted ? pane.accent : pane.foreground
          font.family: pane.fontFamily
          font.pixelSize: Style.font.body
          font.bold: pill.highlighted
        }

        // Hidden until the list has been read: a 0 that is really "not yet"
        // would be a lie.
        Rectangle {
          anchors.verticalCenter: parent.verticalCenter
          visible: pill.count !== ""
          implicitWidth: pillCount.implicitWidth + Style.spacing.md * 2
          implicitHeight: pillCount.implicitHeight + 2
          radius: height / 2
          color: pill.highlighted ? pane.tint(pane.accent, 0.22) : pane.tint(pane.foreground, 0.08)

          Text {
            id: pillCount
            anchors.centerIn: parent
            text: pill.count
            color: pill.highlighted ? pane.accent : pane.muted
            font.family: pane.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        Text {
          anchors.verticalCenter: parent.verticalCenter
          text: "\uf078"
          color: pane.muted
          font.family: pane.fontFamily
          font.pixelSize: Style.font.caption
        }
      }

      MouseArea {
        id: pillMouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: dropdown.toggle()
      }
    }
  }

  Component {
    id: headerRow
    Item {
      id: headerItem
      readonly property var info: parent.rowData
      readonly property color tint: Model.sectionColor(info.type, pane.themeColors, pane.muted)
      height: header.implicitHeight + (info.first ? Style.spacing.xs : Style.spacing.xl + Style.spacing.md) + Style.spacing.xxs

      RowLayout {
        id: header
        anchors.bottom: parent.bottom
        anchors.bottomMargin: Style.spacing.xxs
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: Style.spacing.sm
        spacing: Style.spacing.sm

        Rectangle {
          Layout.alignment: Qt.AlignVCenter
          Layout.preferredWidth: Style.space(6)
          Layout.preferredHeight: Style.space(6)
          radius: Style.space(3)
          color: headerItem.tint
        }

        PanelSectionHeader {
          Layout.maximumWidth: header.width - Style.space(60)
          elide: Text.ElideRight
          text: headerItem.info.title
          foreground: headerItem.tint
          color: headerItem.tint
          fontFamily: pane.fontFamily
        }

        Text {
          Layout.fillWidth: true
          text: String(headerItem.info.count)
          color: pane.muted
          font.family: pane.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }
  }

  Component {
    id: storyRow
    Item {
      id: row
      readonly property var story: parent.rowData.story
      readonly property bool showState: parent.rowData.showState
      readonly property var agent: pane.store ? Model.solveProgress(pane.store.solveStatus, story.id) : null
      readonly property bool current: parent.rowIndex === pane.cursor
      readonly property bool busy: pane.moving === story.id

      height: body.implicitHeight + Style.spacing.md * 2

      Rectangle {
        anchors.fill: parent
        radius: Style.cornerRadius
        color: row.current ? Style.selectionFillFor(pane.foreground, pane.accent) : "transparent"
      }

      MouseArea {
        anchors.fill: parent
        onClicked: { pane.cursor = row.parent.rowIndex; pane.activate() }
      }

      ColumnLayout {
        id: body
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: Style.spacing.sm
        anchors.rightMargin: Style.spacing.sm
        spacing: Style.spacing.sm

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.spacing.sm

          // A fixed width, so a wrench and a bulb take the same room and the
          // references line up down the list.
          Text {
            Layout.preferredWidth: Style.space(16)
            horizontalAlignment: Text.AlignHCenter
            text: row.story.glyph
            color: Model.storyTypeColor(row.story.storyType, pane.themeColors, pane.muted)
            font.family: pane.fontFamily
            font.pixelSize: Style.font.body
          }

          // As wide as the longest reference, so the titles line up.
          Text {
            Layout.preferredWidth: refWidth.advanceWidth
            text: row.story.ref
            color: pane.muted
            font.family: pane.fontFamily
            font.pixelSize: Style.font.caption
          }

          Text {
            id: nameText
            Layout.fillWidth: true
            elide: Text.ElideRight
            text: row.story.name
            // Finished work is there to look back at, so it steps back.
            color: row.busy || row.story.stateType === "done" ? pane.muted : pane.foreground
            font.family: pane.fontFamily
            font.pixelSize: Style.font.body
          }

          // No padding of its own and the title's height, so a row with a PR
          // is exactly as tall as one without: the list does not step.
          Button {
            visible: row.story.prUrl !== ""
            Layout.preferredHeight: nameText.implicitHeight
            horizontalPadding: Style.space(2)
            verticalPadding: 0
            bordered: false
            text: ""
            tooltipText: "Open the linked pull request"
            foreground: pane.muted
            fontFamily: pane.fontFamily
            onClicked: Quickshell.execDetached(["omarchy-launch-browser", row.story.prUrl])
          }

          // An agent Solve started on it: accent when it wants you back.
          Text {
            visible: !!row.agent
            text: "󰚩"
            color: row.agent && row.agent.attention ? pane.accent : pane.muted
            font.family: pane.fontFamily
            font.pixelSize: Style.font.body
          }

          // Whose it is, when the list is the whole team's.
          Text {
            visible: pane.owner === "team"
            Layout.maximumWidth: Style.space(160)
            elide: Text.ElideRight
            text: Model.ownerNames(pane.refs, row.story.ownerIds)
            color: pane.muted
            font.family: pane.fontFamily
            font.pixelSize: Style.font.caption
          }

          // Only when it is not the state the heading already names.
          Text {
            visible: row.busy || row.showState
            text: row.busy ? "moving..." : row.story.stateName
            color: row.busy ? pane.accent : pane.muted
            font.family: pane.fontFamily
            font.pixelSize: Style.font.caption
          }

          // A fixed column, right-aligned, so the times line up down the list.
          Text {
            Layout.preferredWidth: Style.space(80)
            horizontalAlignment: Text.AlignRight
            text: Model.relativeTime(row.story.updatedAt, pane.now)
            color: pane.muted
            font.family: pane.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

      }
    }
  }
}
