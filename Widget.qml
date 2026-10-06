import QtQuick
import QtQml
import Quickshell
import Quickshell.Io
import Quickshell.Services.Mpris
import Quickshell.Services.Pipewire
import qs.Commons
import qs.Ui

// Play-circle button on the bar for YouTube Music (an Omarchy web app:
// ~/.local/share/applications/YouTube Music.desktop).
// Click: a small player pops up (cover, song, progress you can drag, previous /
// play-pause / next, like / dislike, and a button to open the full app).
// Right click: play / pause. Scroll: next / previous track.
// The icon lights up while it's playing.
// Like / dislike aren't in the system media controls, so they send YouTube
// Music's own "+" / "_" shortcuts to its window (bin/ytmusic-key).
// Volume: the slider and SUPER+SHIFT+UP / DOWN set Chromium's PipeWire playback
// stream (Chromium ignores MPRIS volume) -- the same "Chromium" volume the
// audio widget shows, shared by every Chromium tab playing sound. With
// settings.json "music": {"volumeYouTubeOnly": true} and the bridge on, they
// set YouTube Music's own player volume instead (other tabs untouched).
// Like / dislike state isn't in MPRIS either, so the player remembers what you
// rated from here (<state>/ratings.json, keyed by song +
// artist): outline = not rated from here, filled = liked / disliked.
// With the YT Music bar bridge (a Chromium extension + native host in
// this plugin's bridge/ folder) loaded, like / shuffle state and the
// queue come straight from the page instead (<state>/state.json),
// and like / shuffle / play / remove click YouTube Music's own buttons via
// bin/ytmusic-cmd.
Panel {
  id: root
  moduleName: "ytmusic-player"
  ipcTarget: "ytmusic-player"
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  readonly property string url: "https://music.youtube.com/"
  readonly property string home: Quickshell.env("HOME")
  // This plugin's own folder (its bin/ scripts and bridge/ live here), and the
  // folders it keeps settings / state in.
  readonly property string pluginDir: decodeURIComponent(String(Qt.resolvedUrl(".")).replace(/^file:\/\//, "")).replace(/\/$/, "")
  readonly property string binDir: pluginDir + "/bin"
  readonly property string configDir: (Quickshell.env("XDG_CONFIG_HOME") || home + "/.config") + "/ytmusic-player"
  readonly property string stateDir: (Quickshell.env("XDG_STATE_HOME") || home + "/.local/state") + "/ytmusic-player"
  readonly property color fg: root.bar ? root.bar.foreground : Color.foreground
  readonly property string font: root.bar ? root.bar.fontFamily : Style.font.family

  // Chromium web apps register one MPRIS player per tab, all called "Chromium".
  // YouTube Music's cover art comes from googleusercontent.com (YouTube videos
  // use ytimg.com), so prefer that one; else whichever Chromium player is playing.
  readonly property var player: {
    var players = Mpris.players ? Mpris.players.values : []
    // With YouTube Music open in more than one window, the playing one wins.
    var musicPlaying = null
    var music = null
    var playing = null
    var any = null
    for (var i = 0; i < players.length; i++) {
      var p = players[i]
      var name = String(p.identity || p.desktopEntry || "").toLowerCase()
      if (name.indexOf("chrom") < 0) continue
      var isMusic = String(p.trackArtUrl || "").indexOf("googleusercontent.com") >= 0
      if (isMusic && p.isPlaying && !musicPlaying) musicPlaying = p
      if (isMusic && !music) music = p
      if (p.isPlaying && !playing) playing = p
      if (!any && p.trackTitle) any = p
    }
    return musicPlaying || music || playing || any
  }
  // ---- What the widget shows/controls. With the bridge connected it comes
  // straight from the YouTube Music page, so a YouTube video (which takes over
  // Chromium's single system media session) can't hijack the widget. Without
  // the bridge, fall back to the system media controls (MPRIS).
  readonly property bool hasMusic: bridgeOn ? (bridge.title || "") !== "" : root.player !== null
  readonly property string mTitle: bridgeOn ? (bridge.title || "") : (root.player ? (root.player.trackTitle || "") : "")
  readonly property string mByline: bridgeOn ? (bridge.artist || "")
    : (root.player ? [root.player.trackArtist, root.player.trackAlbum].filter(function(s) { return !!s }).join(" · ") : "")
  readonly property string mArtist: bridgeOn ? String(bridge.artist || "").split(" • ")[0] : (root.player ? (root.player.trackArtist || "") : "")
  readonly property string mArt: bridgeOn ? (bridge.art || "") : (root.player && root.player.trackArtUrl ? root.player.trackArtUrl : "")
  readonly property bool playing: bridgeOn ? bridge.playing === true : (root.player !== null && root.player.isPlaying)
  readonly property real length: bridgeOn ? (bridge.duration || 0)
    : (root.player && root.player.lengthSupported ? root.player.length : 0)
  property real position: 0

  // ---- Audio focus: when other audio starts (a YouTube video, or another
  // app's media player), pause YouTube Music, like a phone does. It doesn't
  // resume by itself. Setting: settings.json "music": {"pauseForOtherAudio"}.
  property var prefs: ({})
  readonly property bool pauseForOtherAudio: !(prefs.music && prefs.music.pauseForOtherAudio === false)
  // Signals older than the shell's start are stale; anything newer is new.
  property real otherSeenTs: Date.now() / 1000

  FileView {
    id: settingsFile
    path: root.configDir + "/settings.json"
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: { try { root.prefs = JSON.parse(text()) || {} } catch (e) {} }
  }

  // Shared with the gear panel's YouTube Music entry (same settings.json keys).
  function setMusicPref(key, value) {
    var next = JSON.parse(JSON.stringify(root.prefs || {}))
    next.music = next.music || {}
    next.music[key] = value
    root.prefs = next
    settingsFile.setText(JSON.stringify(next, null, 2) + "\n")
  }
  property bool showSettings: false

  // Written by the bridge host when a youtube.com video starts.
  FileView {
    path: root.stateDir + "/other.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      var ts = 0
      try { ts = JSON.parse(text()).ts || 0 } catch (e) {}
      if (ts > root.otherSeenTs) {
        root.otherSeenTs = ts
        root.otherAudioStarted("a YouTube video")
      }
    }
  }

  // Other apps' media players (not Chromium, whose single session is
  // YouTube Music / YouTube itself).
  Instantiator {
    model: Mpris.players
    delegate: QtObject {
      required property var modelData
      readonly property bool isOther: !/chrom/i.test(String(modelData.identity || modelData.desktopEntry || ""))
      readonly property bool nowPlaying: modelData.isPlaying
      onNowPlayingChanged: if (nowPlaying && isOther) root.otherAudioStarted(modelData.identity || "another app")
    }
  }

  function otherAudioStarted(what) {
    if (!root.pauseForOtherAudio || !root.bridgeOn || !root.playing) return
    root.bridgeCmd(["pause"])
    root.feedback = "Paused for " + what
    feedbackTimer.restart()
  }

  function togglePlay() {
    if (root.bridgeOn) root.bridgeCmd(["toggle"])
    else if (root.player && root.player.canTogglePlaying) root.player.togglePlaying()
  }
  function nextTrack() {
    if (root.bridgeOn) root.bridgeCmd(["next"])
    else if (root.player && root.player.canGoNext) root.player.next()
  }
  function prevTrack() {
    if (root.bridgeOn) root.bridgeCmd(["previous"])
    else if (root.player && root.player.canGoPrevious) root.player.previous()
  }
  function seekTo(v) {
    if (root.bridgeOn) root.bridgeCmd(["seek", String(Math.round(v))])
    else if (root.player && root.player.canSeek) root.player.position = v
    root.position = v
  }

  // Chromium's audio output stream(s); exists while something is playing.
  readonly property var musicStreams: {
    var nodes = Pipewire.nodes ? Pipewire.nodes.values : []
    var out = []
    for (var i = 0; i < nodes.length; i++) {
      var n = nodes[i]
      if (!n || !n.isStream || !n.isSink) continue
      var app = String(n.properties ? (n.properties["application.name"] || "") : "")
      if (/chrom/i.test(app)) out.push(n)
    }
    return out
  }
  readonly property var musicStream: musicStreams.length > 0 ? musicStreams[0] : null
  readonly property bool streamVolume: musicStream !== null && musicStream.audio !== null

  // "YouTube Music only" mode (settings.json music.volumeYouTubeOnly, bridge
  // on): volume is YouTube Music's own player volume (0-100, bridge.volume), so
  // other Chromium tabs aren't affected; mute = volume 0 (unmute restores the
  // level before). Otherwise (default): Chromium's stream volume.
  readonly property bool volumeYouTubeOnly: !!(prefs.music && prefs.music.volumeYouTubeOnly === true)
  readonly property bool pageVolume: volumeYouTubeOnly && bridgeOn && typeof bridge.volume === "number" && bridge.volume >= 0
  property real pageVolumeSet: 0     // last level sent (0-1); the page reports back ~1 s later
  property real pageVolumeSetAt: 0
  property real pageVolumeBeforeMute: 0.5
  readonly property bool hasVolume: pageVolume || streamVolume
  readonly property real volume: pageVolume
    ? (now - pageVolumeSetAt < 2500 ? pageVolumeSet : bridge.volume / 100)
    : (streamVolume ? musicStream.audio.volume : 0)
  readonly property bool muted: !pageVolume && streamVolume && musicStream.audio.muted

  function setVolume(v) {
    v = Math.max(0, Math.min(1, v))
    if (root.pageVolume) {
      root.pageVolumeSet = v
      root.pageVolumeSetAt = Date.now()
      root.now = Date.now()
      // Slider drags fire often; send at most one command per 60 ms.
      if (!pageVolumeTimer.running) { root.bridgeCmd(["volume", String(Math.round(v * 100))]); pageVolumeTimer.start() }
      else pageVolumeTimer.pending = true
      return
    }
    for (var i = 0; i < root.musicStreams.length; i++) {
      var a = root.musicStreams[i].audio
      if (!a) continue
      a.volume = v
      if (v > 0 && a.muted) a.muted = false
    }
  }

  Timer {
    id: pageVolumeTimer
    property bool pending: false
    interval: 60
    onTriggered: if (pending) { pending = false; root.bridgeCmd(["volume", String(Math.round(root.pageVolumeSet * 100))]); start() }
  }

  function toggleMute() {
    if (root.pageVolume) {
      if (root.volume > 0) { root.pageVolumeBeforeMute = root.volume; root.setVolume(0) }
      else root.setVolume(root.pageVolumeBeforeMute > 0 ? root.pageVolumeBeforeMute : 0.5)
      return
    }
    var on = !root.muted
    for (var i = 0; i < root.musicStreams.length; i++)
      if (root.musicStreams[i].audio) root.musicStreams[i].audio.muted = on
  }

  PwObjectTracker { objects: root.musicStreams }

  // ---- Volume keys: SUPER+SHIFT+UP / DOWN (hypr/bindings.lua) call
  // `omarchy-shell ytmusic-player-volume up|down`. Each press moves the volume by
  // settings.json "music": {"volumeStep"} percent (default 5), snapped to that
  // step; holding the key repeats, throttled so it ramps instead of jumping.
  // A small card under the bar icon shows the level for a moment (not while
  // the player is open, which has its own slider).
  readonly property int volumeStep: prefs.music && prefs.music.volumeStep > 0 ? Math.min(25, prefs.music.volumeStep) : 5
  property real keyVolume: 0       // last level set from the keys
  property real keyVolumeAt: 0     // when (ms); PipeWire reports back async
  property bool volumeCard: false

  function stepVolume(dir) {
    var now = Date.now()
    if (now - root.keyVolumeAt < 70) return
    if (root.hasVolume) {
      var recent = now - root.keyVolumeAt < 600
      var pct = Math.round((recent ? root.keyVolume : (root.muted ? 0 : root.volume)) * 100)
      var s = root.volumeStep
      var next = dir > 0 ? (Math.floor(pct / s) + 1) * s : (Math.ceil(pct / s) - 1) * s
      next = Math.max(0, Math.min(100, next))
      root.keyVolume = next / 100
      root.setVolume(root.keyVolume)
    }
    root.keyVolumeAt = now
    if (!root.opened) {
      root.trackCard = false
      root.volumeCard = true
      volumeCardTimer.restart()
    }
  }

  // Level the card shows: what the keys just set, else what PipeWire reports.
  readonly property real shownVolume: volumeCard ? keyVolume : (muted ? 0 : volume)

  IpcHandler {
    target: "ytmusic-player-volume"
    function up(): void { root.stepVolume(1) }
    function down(): void { root.stepVolume(-1) }
  }

  Timer {
    id: volumeCardTimer
    interval: 1400
    onTriggered: root.volumeCard = false
  }

  // ---- Media hotkeys: SUPER+CTRL+M / ] / [ (hypr/bindings.lua) call
  // `omarchy-shell ytmusic-player-media toggle|next|previous`. The widget does the
  // action and shows a card under the bar icon, like the volume one: cover,
  // ▶ / ⏸ / ⏭ / ⏮ and the song, updating as soon as the new song is playing.
  property bool trackCard: false
  property string trackCardAction: ""
  function mediaKey(action) {
    if (action === "toggle") root.togglePlay()
    else if (action === "next") root.nextTrack()
    else if (action === "previous") root.prevTrack()
    else return
    root.trackCardAction = action
    if (root.opened) return
    root.volumeCard = false
    if (action === "toggle") { root.showTrackCard(); return }
    // Next / previous: wait until the new song (and its cover) has arrived, so
    // the card never shows the old song first. If the song doesn't change
    // (previous restarts the current one), show it after a short wait.
    root.trackCard = false
    root.cardWaitFrom = root.mTitle
    root.cardWaitArt = root.mArt
    root.cardWaiting = true
    cardWaitTimer.interval = action === "previous" ? 1500 : 3000
    cardWaitTimer.restart()
  }
  function showTrackCard() {
    root.cardWaiting = false
    cardWaitTimer.stop()
    root.trackCard = true
    trackCardTimer.restart()
  }
  property bool cardWaiting: false
  property string cardWaitFrom: ""
  property string cardWaitArt: ""
  readonly property bool cardSongChanged: cardWaiting && mTitle !== "" && mTitle !== cardWaitFrom
  // The new song is here; show once its cover has loaded (or it has none).
  // The cover can arrive a moment after the name, so also wait for it to change —
  // but only briefly, since songs from the same album share a cover.
  onCardSongChangedChanged: if (cardSongChanged) { artGrace.restart(); maybeShowCard() }
  function coverReady() {
    return root.mArt === "" || coverPreload.status === Image.Ready || coverPreload.status === Image.Error
  }
  function maybeShowCard() {
    if (!root.cardWaiting || !root.cardSongChanged) return
    if (root.mArt !== root.cardWaitArt && root.coverReady()) root.showTrackCard()
  }
  onMArtChanged: { if (root.mTitle === root.lastSeenTitle) root.lastSeenArt = root.mArt; maybeShowCard() }
  Timer {
    id: artGrace
    interval: 600
    onTriggered: if (root.cardWaiting && root.cardSongChanged && root.coverReady()) root.showTrackCard()
  }
  // Loads the cover off-screen so the card appears with the new image already there.
  Image {
    id: coverPreload
    visible: false
    source: root.mArt
    sourceSize.width: 96
    sourceSize.height: 96
    asynchronous: true
    onStatusChanged: root.maybeShowCard()
  }
  Timer {
    id: cardWaitTimer
    onTriggered: if (root.cardWaiting) root.showTrackCard()
  }
  IpcHandler {
    target: "ytmusic-player-media"
    function toggle(): void { root.mediaKey("toggle") }
    function next(): void { root.mediaKey("next") }
    function previous(): void { root.mediaKey("previous") }
    // Show the card for the current song without doing anything (testing).
    function card(): void {
      root.trackCardAction = "next"
      root.volumeCard = false
      root.trackCard = true
      trackCardTimer.restart()
    }
  }
  Timer {
    id: trackCardTimer
    interval: 1800
    onTriggered: trackCardFade.restart()
  }
  // Omarchy's pop-up card fades in a fixed 0.14 s; fading the contents first
  // (0.46 s) makes the whole fade about 0.6 s and softer.
  SequentialAnimation {
    id: trackCardFade
    NumberAnimation { target: trackRow; property: "opacity"; to: 0; duration: 460; easing.type: Easing.InOutQuad }
    ScriptAction { script: root.trackCard = false }
  }
  onTrackCardChanged: if (trackCard) { trackCardFade.stop(); trackRow.opacity = 1 }

  // Brief "Liked" / "Disliked" note after pressing those buttons.
  property string feedback: ""

  // { "title — artist": "like" | "dislike" }
  property var ratings: ({})
  readonly property string songKey: root.mTitle !== "" ? root.mTitle + " — " + root.mArtist : ""
  readonly property string localRating: root.songKey !== "" ? (root.ratings[root.songKey] || "") : ""

  // ---- Bridge (extension) state; "live" if it reported in the last 10 s.
  property var bridge: ({})
  property real now: Date.now()
  readonly property bool bridgeOn: bridge.connected === true && bridge.ts > 0 && now - bridge.ts * 1000 < 10000
  readonly property var queue: bridgeOn && bridge.queue ? bridge.queue : []
  readonly property string rating: bridgeOn && bridge.like
    ? (bridge.like === "LIKE" ? "like" : bridge.like === "DISLIKE" ? "dislike" : "")
    : root.localRating
  readonly property bool shuffleOn: bridgeOn && bridge.shuffle === true

  // Health check from the extension: which page pieces went missing after a
  // YouTube Music update. Notify once per distinct problem; warn in the popup.
  readonly property var healthFailed: bridgeOn && bridge.health && bridge.health.failed ? bridge.health.failed : []
  readonly property string healthKey: healthFailed.join(", ")
  property string notifiedHealth: ""
  onHealthKeyChanged: {
    if (healthKey === "" || healthKey === notifiedHealth) return
    notifiedHealth = healthKey
    Quickshell.execDetached(["notify-send", "-a", "YouTube Music", "-i", "dialog-warning",
      "YouTube Music changed its page",
      "Not working in the bar player: " + healthKey + ". Play, pause and volume still work. Check for an update to the ytmusic-player plugin (omarchy plugin update ytmusic-player)."])
  }
  // Bottom half shows one thing at a time: "queue", "search", "library" or "".
  property string bottomView: ""
  readonly property bool showQueue: bottomView === "queue"
  function setView(v) {
    root.bottomView = root.bottomView === v ? "" : v
    if (root.bottomView === "library") root.bridgeCmd(["library"])
    if (root.bottomView === "speeddial") { root.speedDialLoading = root.speedDialItems.length === 0; root.bridgeCmd(["speeddial"]) }
    if (root.bottomView === "lyrics" && root.lyricsFor !== root.mTitle) root.loadLyrics()
    if (root.bottomView === "search") Qt.callLater(function() { searchInput.forceActiveFocus() })
  }

  // ---- Search / library results (from the bridge, <state>/results.json)
  property var searchItems: []
  property var libraryItems: []
  property string searchError: ""
  property string libraryError: ""
  property bool searching: false
  property bool libraryLoading: false
  property string lastQuery: ""
  FileView {
    path: root.stateDir + "/results.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      var d = null
      try { d = JSON.parse(text()) } catch (e) { return }
      if (!d) return
      if (d.list === "search") {
        // While typing, an answer for text that has since changed is stale.
        if (d.query !== undefined && d.query !== root.lastQuery) return
        if ((d.chipLabel || "") !== root.chipLabel) return
        root.searchItems = d.items || []; root.searchError = d.error || ""; root.searching = false
        if ((d.chips || []).length) root.searchChips = d.chips
      }
      else if (d.list === "artist") {
        root.artistItems = (d.items || []).map(function(x, i) { return Object.assign({ _i: i }, x) })
        root.artistError = d.error || ""; root.artistLoading = false
        root.artistTitle = d.title || root.artistTitle
        root.artistHasShuffle = !!d.hasShuffle; root.artistHasRadio = !!d.hasRadio
        root.artistHasAllSongs = !!d.hasAllSongs
        root.artistSongsItems = []
        root.artistSongsError = ""
      }
      else if (d.list === "library") {
        root.libraryItems = (d.items || []).map(function(x, i) { return Object.assign({ _i: i }, x) })
        root.libraryError = d.error || ""; root.libraryLoading = false
      }
      else if (d.list === "saveto") {
        root.saveTargets = d.items || []; root.saveError = d.error || ""; root.saveLoading = false
      }
      else if (d.list === "saved" && d.ts * 1000 > root.saveRequestedAt) {
        root.feedback = d.error ? "Couldn't save: " + d.error : "Saved to " + d.title
        feedbackTimer.restart()
      }
      else if (d.list === "lyrics") {
        root.lyricsText = d.text || ""; root.lyricsSource = d.source || ""
        root.lyricsNote = d.error ? "Couldn't load lyrics: " + d.error : (d.note || "")
        root.lyricsLoading = false; root.lyricsFor = root.mTitle
      }
      else if (d.list === "speeddial") {
        root.speedDialItems = d.items || []; root.speedDialError = d.error || ""
        root.speedDialTitle = d.title || ""; root.speedDialLoading = false
      }
      else if (d.list === "artistsongs") {
        root.artistSongsItems = d.items || []; root.artistSongsError = d.error || ""; root.artistSongsLoading = false
        root.artistSongsCanPlay = !!d.canPlayAll
      }
      else if (d.list === "added" && d.ts * 1000 > root.addRequestedAt) {
        root.feedback = d.error
          ? "Couldn't add " + d.title + ": " + d.error
          : (d.action === "next" ? "Playing next: " : "Added to queue: ") + d.title
            + (d.count > 1 ? " (" + d.count + " songs)" : "")
        feedbackTimer.restart()
      }
    }
  }
  // Filter chips (Songs, Albums, Artists, …), picked by name so one can be
  // chosen before typing. Until a search returns YouTube Music's own list,
  // show its usual one. "" = All.
  property var searchChips: []
  readonly property var defaultChips: ["Songs", "Videos", "Albums", "Artists", "Community playlists", "Podcasts", "Episodes", "Profiles"]
  readonly property var chipLabels: searchChips.length ? searchChips.map(function(c) { return c.label }) : defaultChips
  property string chipLabel: ""
  readonly property int selectedChip: chipLabel === "" ? -1 : chipLabels.indexOf(chipLabel)
  function runSearch(q) {
    q = String(q || "").trim()
    if (q === "" || !root.bridgeOn) return
    root.lastQuery = q
    root.searching = true
    root.showArtist = false
    var args = ["search"]
    if (root.chipLabel !== "") args.push("--filter", root.chipLabel)
    root.bridgeCmd(args.concat(q.split(/\s+/)))
  }
  function chooseChip(i) {
    root.chipLabel = (i < 0 || root.chipLabels[i] === root.chipLabel) ? "" : root.chipLabels[i]
    if (searchInput.text.trim() !== "") root.runSearch(searchInput.text)
  }

  // Live search: once typing pauses for a moment (one search per pause, not
  // per key), for 2+ characters.
  Timer {
    id: liveSearch
    interval: 350
    onTriggered: {
      var q = searchInput.text.trim()
      if (q.length >= 2 && q !== root.lastQuery) root.runSearch(q)
    }
  }

  // ---- Artist page (opened from a search / library / artist result).
  property bool showArtist: false
  property bool artistLoading: false
  property string artistTitle: ""
  property string artistError: ""
  property var artistItems: []
  property bool artistHasShuffle: false
  // Sections of the artist's page (Top songs, Albums, Singles & EPs, Videos, …)
  // as chips; -1 = All.
  property string artistSectionLabel: ""   // "" = All
  property bool artistHasAllSongs: false
  property var artistSongsItems: []
  property bool artistSongsLoading: false
  property string artistSongsError: ""
  property bool artistSongsCanPlay: false
  function playAllSongs(mode) {
    root.bridgeCmd(["artistsongsplay", mode])
    root.feedback = (mode === "shuffle" ? "Shuffling all of " : "Playing all of ") + root.artistTitle + "'s songs"
    feedbackTimer.restart()
    root.bottomView = "queue"
  }
  readonly property bool artistAllSongsOn: artistSectionLabel === "All songs"
  // Which kinds of artist-page section to show (settings.json music.artistSections,
  // { "Albums": false, … }; missing = shown). Matched by type, since some
  // section names include the artist ("Playlists by …").
  readonly property var artistSectionTypes: [
    { name: "Top songs", match: /^(top )?songs/i },
    { name: "All songs", match: /^$^/ },
    { name: "Albums", match: /^albums/i },
    { name: "Singles & EPs", match: /^singles/i },
    { name: "Videos", match: /^videos/i },
    { name: "Featured on", match: /^featured/i },
    { name: "Playlists", match: /^playlists/i },
    { name: "Other", match: /.*/ }
  ]
  function sectionType(shelf) {
    for (var i = 0; i < artistSectionTypes.length; i++)
      if (artistSectionTypes[i].match.test(shelf || "")) return artistSectionTypes[i].name
    return "Other"
  }
  function sectionTypeOn(name) {
    var m = root.prefs.music && root.prefs.music.artistSections
    return !(m && m[name] === false)
  }
  function setSectionType(name, on) {
    var m = JSON.parse(JSON.stringify((root.prefs.music && root.prefs.music.artistSections) || {}))
    m[name] = on
    root.setMusicPref("artistSections", m)
    root.artistSectionLabel = ""
  }
  readonly property var artistVisibleItems: artistItems.filter(function(x) { return root.sectionTypeOn(root.sectionType(x.shelf)) })
  readonly property var artistSections: {
    var out = []
    for (var i = 0; i < artistVisibleItems.length; i++) {
      var sh = artistVisibleItems[i].shelf || ""
      if (sh !== "" && out.indexOf(sh) < 0) out.push(sh)
    }
    return out
  }
  // Chips: the page's sections, with "All songs" (the full list) right after Top songs.
  readonly property var artistChipLabels: {
    var out = artistSections.slice()
    if (artistHasAllSongs && sectionTypeOn("All songs")) {
      var at = -1
      for (var i = 0; i < out.length; i++) if (sectionType(out[i]) === "Top songs") at = i
      out.splice(at + 1, 0, "All songs")
    }
    return out
  }
  function pickArtistChip(index) {
    var label = index < 0 ? "" : root.artistChipLabels[index]
    root.artistSectionLabel = label === root.artistSectionLabel ? "" : label
    if (root.artistAllSongsOn && root.artistSongsItems.length === 0 && !root.artistSongsLoading) {
      root.artistSongsLoading = true
      root.artistSongsError = ""
      root.bridgeCmd(["artistsongs"])
    }
  }
  readonly property var artistShown: artistAllSongsOn ? artistSongsItems
    : artistSectionLabel === "" ? artistVisibleItems
    : artistVisibleItems.filter(function(x) { return x.shelf === artistSectionLabel })
  property bool artistHasRadio: false
  function openArtist(list, index, it) {
    root.artistSectionLabel = ""
    root.artistTitle = it.title
    root.artistItems = []
    root.artistError = ""
    root.artistLoading = true
    root.showArtist = true
    root.bottomView = "search"
    root.bridgeCmd(["artist", list, String(index)])
  }
  function playArtist(mode) {
    root.bridgeCmd(["artistplay", mode])
    root.feedback = (mode === "shuffle" ? "Shuffling " : "Radio: ") + root.artistTitle
    feedbackTimer.restart()
    root.bottomView = "queue"
  }
  property real addRequestedAt: 0
  function queueResult(list, index, title, action) {
    root.addRequestedAt = Date.now() - 1000
    root.bridgeCmd(["pick", list, String(index), action])
    root.feedback = (action === "next" ? "Adding to play next: " : "Adding to queue: ") + title
    feedbackTimer.restart()
  }

  // ---- Pinned playlists (bookmark icon): kept only on this computer in
  // <config>/pins.json, shown at the top of the Library tab.
  property var pins: []
  FileView {
    id: pinsFile
    path: root.configDir + "/pins.json"
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: { try { root.pins = JSON.parse(text()) || [] } catch (e) { root.pins = [] } }
  }
  function pinKey(it) { return it && it.playlistId ? "p:" + it.playlistId : (it && it.videoId ? "v:" + it.videoId : "") }
  function isPinned(it) {
    var k = root.pinKey(it)
    if (k === "") return false
    for (var i = 0; i < root.pins.length; i++) if (root.pinKey(root.pins[i]) === k) return true
    return false
  }
  function togglePin(it) {
    var k = root.pinKey(it)
    if (k === "") return
    var next = root.pins.filter(function(p) { return root.pinKey(p) !== k })
    var pinning = next.length === root.pins.length
    if (pinning) next.unshift({ title: it.title, subtitle: it.subtitle || "", art: it.art || "", kind: it.kind,
                                playlistId: it.playlistId || "", videoId: it.videoId || "" })
    root.pins = next
    pinsFile.setText(JSON.stringify(next, null, 1) + "\n")
    root.feedback = (pinning ? "Pinned: " : "Unpinned: ") + it.title
    feedbackTimer.restart()
  }

  // ---- Repeat (bottom row): off → all → one, from the player bar's own marker.
  readonly property string repeatMode: bridgeOn ? (bridge.repeat || "NONE") : "NONE"

  // ---- Start radio from the current song (YouTube Music's own "Start radio").
  function startRadio() {
    root.bridgeCmd(["radio"])
    root.feedback = "Radio: " + root.mTitle
    feedbackTimer.restart()
    root.bottomView = "queue"
  }

  // ---- Save the current song to one of your playlists (floating card).
  property bool showSaveCard: false
  property var saveTargets: []
  property string saveError: ""
  property bool saveLoading: false
  property real saveRequestedAt: 0
  function openSaveCard() {
    root.showSaveCard = !root.showSaveCard
    if (!root.showSaveCard) return
    root.saveTargets = []; root.saveError = ""; root.saveLoading = true
    root.bridgeCmd(["saveto"])
  }
  function saveTo(t) {
    root.showSaveCard = false
    root.saveRequestedAt = Date.now() - 1000
    root.bridgeCmd(["saveadd", t.playlistId, t.title])
    root.feedback = "Saving to " + t.title + "…"
    feedbackTimer.restart()
  }

  // ---- Lyrics (5th bottom view): what YouTube Music has for the song.
  property string lyricsText: ""
  property string lyricsSource: ""
  property string lyricsNote: ""
  property string lyricsFor: ""      // title the lyrics belong to
  property bool lyricsLoading: false
  function loadLyrics() {
    root.lyricsLoading = true; root.lyricsText = ""; root.lyricsNote = ""; root.lyricsSource = ""
    root.bridgeCmd(["lyrics"])
  }

  // ---- Equalizer (settings card): bass / mid / treble for Chromium's sound,
  // through the "Music EQ" PipeWire filter (bin/music-eq).
  readonly property var eq: (prefs.music && prefs.music.eq) || ({})
  readonly property bool eqOn: eq.enabled !== false
  function eqValue(band) { var v = Number(root.eq[band]); return isFinite(v) ? v : 0 }
  function setEq(band, value) {
    Quickshell.execDetached([root.binDir + "/music-eq", "set", band, String(Math.round(value))])
  }
  function setEqOn(on) {
    Quickshell.execDetached([root.binDir + "/music-eq", on ? "on" : "off"])
  }

  // ---- Sleep timer (settings card): pause after N minutes or at the song's end.
  property real sleepAt: 0            // ms; 0 = off
  property bool sleepEndOfSong: false
  readonly property bool sleepOn: sleepAt > 0 || sleepEndOfSong
  function setSleep(minutes) {        // 0 = off, -1 = end of song
    root.sleepEndOfSong = minutes === -1
    root.sleepAt = minutes > 0 ? Date.now() + minutes * 60000 : 0
    root.feedback = minutes === 0 ? "Sleep timer off"
      : minutes === -1 ? "Pausing at the end of this song" : "Pausing in " + minutes + " min"
    feedbackTimer.restart()
  }
  readonly property string sleepLabel: sleepEndOfSong ? "end"
    : sleepAt > 0 ? Math.max(1, Math.ceil((sleepAt - now) / 60000)) + "m" : ""
  Timer {
    interval: 1000
    repeat: true
    running: root.sleepOn
    onTriggered: {
      root.now = Date.now()
      var due = (root.sleepAt > 0 && Date.now() >= root.sleepAt)
        || (root.sleepEndOfSong && root.length > 0 && root.position >= root.length - 1.5)
      if (!due) return
      root.sleepAt = 0; root.sleepEndOfSong = false
      if (root.playing) root.togglePlay()
      Quickshell.execDetached(["notify-send", "-a", "YouTube Music", "Sleep timer", "Music paused."])
    }
  }

  // ---- Recently played (Speed dial view, second chip), kept in
  // <state>/history.json (last 50).
  property var history: []
  FileView {
    id: historyFile
    path: root.stateDir + "/history.json"
    atomicWrites: true
    printErrors: false
    onLoaded: { try { root.history = JSON.parse(text()) || [] } catch (e) { root.history = [] } }
  }
  readonly property string currentVideoId: {
    for (var i = 0; i < queue.length; i++) if (queue[i].current) return queue[i].id || ""
    return ""
  }
  // Up next (bar tooltip): the queue entry after the current one.
  readonly property var upNext: currentQueueIndex >= 0 && currentQueueIndex + 1 < queue.length ? queue[currentQueueIndex + 1] : null

  // ---- Song-change notification (settings card, off by default).
  readonly property bool notifySongs: !!(prefs.music && prefs.music.notifySongChange)
  readonly property bool progressRing: !(prefs.music && prefs.music.progressRing === false)
  property string lastSeenTitle: ""
  property string lastSeenArt: ""
  onMTitleChanged: {
    var t = root.mTitle
    if (t === "" || t === root.lastSeenTitle) return
    var first = root.lastSeenTitle === ""
    var prevTitle = root.lastSeenTitle
    var prevArt = root.lastSeenArt
    root.lastSeenTitle = t
    root.lastSeenArt = root.mArt
    if (!root.bridgeOn) return
    // History (skip the song already showing when the shell started).
    if (!first) {
      var entry = { title: t, artist: root.mArtist, art: root.mArt, kind: "song", videoId: root.currentVideoId,
                    subtitle: root.mArtist, playlistId: "" }
      var next = [entry].concat(root.history.filter(function(h) { return h.title !== t })).slice(0, 50)
      root.history = next
      historyFile.setText(JSON.stringify(next, null, 1) + "\n")
    }
    // Lyrics view open: follow the new song.
    if (root.bottomView === "lyrics" && root.opened) root.loadLyrics()
    // Song-change card (the same card as the media keys, with ♪): not for the
    // song at startup, not when a skip / pause card is already handling it, and
    // not while the player is open. Waits for the new cover like a skip does.
    if (!first && root.notifySongs && !root.cardWaiting && !root.trackCard && !root.opened) {
      root.trackCardAction = "change"
      root.volumeCard = false
      root.cardWaitFrom = prevTitle
      root.cardWaitArt = prevArt
      root.cardWaiting = true
      cardWaitTimer.interval = 3000
      cardWaitTimer.restart()
      artGrace.restart()
      root.maybeShowCard()
    }
  }

  // ---- Speed dial (4th bottom view): YouTube Music's quick-access shelf from
  // its home page ("Speed dial", or "Listen again" on the web).
  property var speedDialItems: []
  property string speedDialError: ""
  property string speedDialTitle: ""
  property bool speedDialLoading: false

  // Library chips: All / Playlists / Albums ("" = All).
  property string libraryFilter: ""
  property bool speedDialRecent: false   // Speed dial view: show Recently played

  // ---- Hidden library items (eye icon): kept only on this computer in
  // <config>/hidden.json (list of pin-style keys). The eye
  // button at the top of the Library tab shows them again, dimmed.
  property var hiddenKeys: []
  property bool showHidden: false
  FileView {
    id: hiddenFile
    path: root.configDir + "/hidden.json"
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: { try { root.hiddenKeys = JSON.parse(text()) || [] } catch (e) { root.hiddenKeys = [] } }
  }
  function isHidden(it) { var k = root.pinKey(it); return k !== "" && root.hiddenKeys.indexOf(k) >= 0 }
  function toggleHidden(it) {
    var k = root.pinKey(it)
    if (k === "") return
    var hiding = root.hiddenKeys.indexOf(k) < 0
    var next = hiding ? root.hiddenKeys.concat([k]) : root.hiddenKeys.filter(function(x) { return x !== k })
    root.hiddenKeys = next
    hiddenFile.setText(JSON.stringify(next, null, 1) + "\n")
    root.feedback = (hiding ? "Hidden: " : "Unhidden: ") + it.title
    feedbackTimer.restart()
  }
  readonly property int hiddenCount: libraryItems.filter(function(x) { return root.isHidden(x) }).length
  readonly property var librarySections: {
    var out = []
    for (var i = 0; i < libraryItems.length; i++) {
      var sh = libraryItems[i].shelf || ""
      if (sh !== "" && out.indexOf(sh) < 0) out.push(sh)
    }
    return out
  }
  readonly property var libraryShown: libraryItems
    .filter(function(x) { return root.libraryFilter === "" || x.shelf === root.libraryFilter })
    .filter(function(x) { return root.showHidden || !root.isHidden(x) })
    .map(function(x) { return Object.assign({}, x, { hidden: root.isHidden(x) }) })

  // Every result action (click, hover icons, right-click menu) goes through here.
  // Search / library items are played by their place in the list; pinned ones by id.
  function rowAction(list, index, it, action) {
    // Artist-page items carry their place in the full page list (filters hide some).
    if (it && it._i !== undefined) index = it._i
    if (action === "pin") { root.togglePin(it); return }
    if (action === "hide") { root.toggleHidden(it); return }
    if (it && it.kind === "artist") { root.openArtist(list, index, it); return }
    if (list === "pinned" || list === "history") {
      root.addRequestedAt = Date.now() - 1000
      root.bridgeCmd(["pickid", it.playlistId ? "playlist" : "song", it.playlistId || it.videoId, action, it.title])
      if (action === "play") {
        root.feedback = "Playing " + it.title
        root.bottomView = "queue"
      } else {
        root.feedback = (action === "next" ? "Adding to play next: " : "Adding to queue: ") + it.title
      }
      feedbackTimer.restart()
      return
    }
    if (action === "play") root.pickResult(list, index, it.title)
    else root.queueResult(list, index, it.title, action)
  }

  function pickResult(list, index, title) {
    root.bridgeCmd(["pick", list, String(index)])
    root.feedback = "Playing " + title
    feedbackTimer.restart()
    // Show what's playing now: switch the bottom half to the queue.
    root.bottomView = "queue"
  }

  onOpenedChanged: {
    if (opened) { volumeCard = false; trackCard = false }
    if (!opened) { queueMenu.visible = false; resultMenu.visible = false; showSettings = false; showSaveCard = false }
    else if (showQueue) resetQueuePaging()
  }

  // The queue shows 20 songs at a time ("Show more" adds 20). It starts with
  // enough pages to include the song that's playing.
  readonly property int queuePage: 20
  property int queueShown: queuePage
  // Songs already played are hidden: the list starts at the one playing now.
  // Rows are numbered from there; queue commands use queueOffset + row index.
  readonly property int queueOffset: Math.max(0, currentQueueIndex)
  readonly property int queueLeft: Math.max(0, queue.length - queueOffset - queueShown)
  readonly property int currentQueueIndex: {
    for (var i = 0; i < queue.length; i++) if (queue[i].current) return i
    return -1
  }
  function resetQueuePaging() {
    root.queueShown = root.queuePage
  }
  onShowQueueChanged: if (showQueue) resetQueuePaging()

  FileView {
    id: bridgeFile
    path: root.stateDir + "/state.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      try { root.bridge = JSON.parse(text()) || {} } catch (e) {}
      root.now = Date.now()
    }
  }

  Timer {
    interval: 2000
    repeat: true
    running: root.opened
    onTriggered: root.now = Date.now()
  }

  function bridgeCmd(args) {
    Quickshell.execDetached([root.binDir + "/ytmusic-cmd"].concat(args))
  }

  function playQueueItem(index) {
    var item = root.queue[index]
    if (item) root.bridgeCmd(["play", String(index), item.title, item.id || ""])
  }

  // ---- Drag to reorder (grip on the right of each queue row).
  // Swipe left on a queue row: all the way removes it; part way leaves a
  // Remove button showing (one row at a time).
  property int revealedIndex: -1
  readonly property real revealWidth: Style.space(96)

  property int dragFrom: -1       // queue index being dragged, -1 = none
  property int dragTo: -1         // where it would land
  property real dragPressY: 0     // pointer y in the list (column) at press
  property real dragViewY: 0      // pointer y in the visible list area now
  readonly property real queuePitch: Style.space(42) + Style.space(2)  // row + spacing
  readonly property real dragDy: dragFrom < 0 ? 0 : dragViewY + queueScroll.contentY - dragPressY

  function updateDragTarget() {
    if (root.dragFrom < 0) return
    var center = root.dragFrom * root.queuePitch + root.queuePitch / 2 + root.dragDy
    var last = Math.min(root.queueShown, root.queue.length - root.queueOffset) - 1
    // Row 0 is the song playing now; anything dropped above it would land in the
    // (hidden) already-played part of the queue, so the earliest spot is right after it.
    var first = root.currentQueueIndex >= 0 ? 1 : 0
    root.dragTo = Math.max(first, Math.min(last, Math.floor(center / root.queuePitch)))
  }

  function moveQueueItem(from, to) {
    var item = root.queue[from]
    if (!item || from === to) return
    root.bridgeCmd(["move", String(from), String(to), item.title, item.id || ""])
    root.feedback = "Moved " + item.title + " to #" + (to + 1)
    feedbackTimer.restart()
  }

  function removeQueueItem(index) {
    var item = root.queue[index]
    if (!item) return
    root.bridgeCmd(["remove", String(index), item.title, item.id || ""])
    root.feedback = "Removed " + item.title
    feedbackTimer.restart()
  }

  FileView {
    id: ratingsFile
    path: root.stateDir + "/ratings.json"
    atomicWrites: true
    printErrors: false
    onLoaded: {
      try { root.ratings = JSON.parse(text()) || {} } catch (e) { root.ratings = {} }
    }
  }

  function formatTime(seconds) {
    if (!(seconds > 0)) return "0:00"
    var s = Math.floor(seconds)
    var m = Math.floor(s / 60)
    var h = Math.floor(m / 60)
    var ss = (s % 60 < 10 ? "0" : "") + (s % 60)
    if (h > 0) return h + ":" + (m % 60 < 10 ? "0" : "") + (m % 60) + ":" + ss
    return m + ":" + ss
  }

  function openApp() {
    root.close()
    Quickshell.execDetached(["omarchy-launch-or-focus-webapp", "music.youtube.com", root.url])
  }

  // YouTube Music's "s" shortcut shuffles the queue (a one-off action, not a mode).
  function shuffle() {
    if (root.bridgeOn) root.bridgeCmd(["shuffle"])
    else Quickshell.execDetached([root.binDir + "/ytmusic-key", "shuffle"])
    root.feedback = "Queue shuffled"
    feedbackTimer.restart()
  }

  function rate(kind) {
    if (root.songKey === "") return
    if (root.bridgeOn) {
      // The page reports the new state back; no local bookkeeping needed.
      var undoing = root.rating === kind
      root.bridgeCmd([kind])
      root.feedback = undoing
        ? (kind === "like" ? "Like removed" : "Dislike removed")
        : (kind === "like" ? "Liked" : "Disliked")
      feedbackTimer.restart()
      return
    }
    Quickshell.execDetached([root.binDir + "/ytmusic-key", kind])
    // YouTube Music's +/_ toggle: pressing the same one again clears it.
    var undo = root.localRating === kind
    var next = JSON.parse(JSON.stringify(root.ratings))
    if (undo) delete next[root.songKey]
    else next[root.songKey] = kind
    root.ratings = next
    ratingsFile.setText(JSON.stringify(next, null, 1) + "\n")
    root.feedback = undo
      ? (kind === "like" ? "Like removed" : "Dislike removed")
      : (kind === "like" ? "Liked" : "Disliked")
    feedbackTimer.restart()
  }

  // MPRIS doesn't push position updates; poll it (and count on from the bridge's reports).
  Timer {
    repeat: true
    triggeredOnStart: true
    // Fast while the player is open; once a second while closed (bar progress ring).
    interval: root.opened ? 500 : 1000
    running: root.hasMusic && (root.opened || (root.progressRing && root.playing))
    onTriggered: {
      if (progress.dragging) return
      if (root.bridgeOn) {
        // The page reports whole seconds; count on from its last report.
        var extra = root.playing ? Math.max(0, (Date.now() - root.bridge.ts * 1000) / 1000) : 0
        root.position = Math.min(root.length > 0 ? root.length : 1e9, (root.bridge.position || 0) + extra)
      } else if (root.player) {
        root.player.positionChanged()
        root.position = root.player.position
      }
    }
  }

  Timer {
    id: feedbackTimer
    interval: 1800
    onTriggered: root.feedback = ""
  }

  // Progress ring: a thin arc around the bar icon that fills as the song plays.
  Canvas {
    id: progressRingCanvas
    anchors.centerIn: button
    width: Math.min(button.width, button.height) - 2
    height: width
    visible: root.progressRing && root.hasMusic && root.length > 0
    opacity: 0.85
    readonly property real fraction: root.length > 0 ? Math.max(0, Math.min(1, root.position / root.length)) : 0
    onFractionChanged: requestPaint()
    onVisibleChanged: requestPaint()
    onPaint: {
      var ctx = getContext("2d")
      ctx.reset()
      var r = width / 2 - 1.5
      ctx.lineWidth = 1.5
      ctx.strokeStyle = Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.15)
      ctx.beginPath(); ctx.arc(width / 2, height / 2, r, 0, 2 * Math.PI); ctx.stroke()
      ctx.strokeStyle = root.playing && root.bar ? root.bar.urgent : root.fg
      ctx.beginPath(); ctx.arc(width / 2, height / 2, r, -Math.PI / 2, -Math.PI / 2 + 2 * Math.PI * fraction); ctx.stroke()
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰐌"  // play-in-a-circle
    active: root.playing
    tooltipText: root.opened ? "" : (root.mTitle !== ""
      ? (root.playing ? "Playing: " : "Paused: ") + root.mTitle
        + (root.mArtist ? " — " + root.mArtist : "")
        + (root.upNext ? "\nUp next: " + root.upNext.title + (root.upNext.artist ? " — " + root.upNext.artist : "") : "")
      : "YouTube Music")
    onPressed: function(b) {
      if (b === Qt.RightButton) {
        root.togglePlay()
      } else {
        root.toggle()
      }
    }
    onWheelMoved: function(delta) {
      if (!root.hasMusic) return
      if (delta < 0) root.nextTrack()
      else if (delta > 0) root.prevTrack()
    }
  }

  // Track card for the media hotkeys (see mediaKey).
  PopupCard {
    id: trackPopup
    anchorItem: button
    bar: root.bar
    triggerMode: "hover"
    open: root.trackCard && !root.opened
    contentWidth: trackRow.implicitWidth + trackPopup.padding * 2 + Style.space(4)
    contentHeight: trackPopup.fittedContentHeight(trackRow.implicitHeight)

    Row {
      id: trackRow
      anchors.centerIn: parent
      spacing: Style.space(10)

      Rectangle {
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(40)
        height: width
        radius: Math.max(3, Style.cornerRadius / 2)
        color: Qt.darker(Color.menu.background, 1.3)
        clip: true
        Text {
          anchors.centerIn: parent
          visible: trackArt.status !== Image.Ready
          text: "󰝚"
          color: root.fg
          opacity: 0.5
          font.family: root.font
          font.pixelSize: Style.font.body
        }
        Image {
          id: trackArt
          anchors.fill: parent
          source: root.mArt
          sourceSize.width: 96
          sourceSize.height: 96
          fillMode: Image.PreserveAspectCrop
          asynchronous: true
        }
      }

      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: root.trackCardAction === "next" ? "󰒭"
          : root.trackCardAction === "previous" ? "󰒮"
          : root.trackCardAction === "change" ? "󰝚"
          : root.playing ? "󰐊" : "󰏤"
        color: root.fg
        font.family: root.font
        font.pixelSize: Style.font.title + Style.space(4)
      }

      Column {
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(2)
        Text {
          width: Math.min(implicitWidth, Style.space(220))
          text: root.trackCardAction === "toggle" && !root.playing ? "Paused"
            : (root.mTitle !== "" ? root.mTitle : "Nothing playing")
          elide: Text.ElideRight
          color: root.fg
          font.family: root.font
          font.pixelSize: Style.font.bodySmall
          font.bold: true
        }
        Text {
          width: Math.min(implicitWidth, Style.space(220))
          visible: text !== ""
          text: root.trackCardAction === "toggle" && !root.playing ? root.mTitle : root.mArtist
          elide: Text.ElideRight
          color: root.fg
          opacity: 0.65
          font.family: root.font
          font.pixelSize: Style.font.caption
        }
      }
    }
  }

  // Volume card for the SUPER+SHIFT+UP / DOWN keys (see stepVolume).
  PopupCard {
    id: volumePopup
    anchorItem: button
    bar: root.bar
    triggerMode: "hover"
    open: root.volumeCard
    contentWidth: popupRow.implicitWidth + volumePopup.padding * 2 + Style.space(4)
    contentHeight: volumePopup.fittedContentHeight(popupRow.implicitHeight)

    Row {
      id: popupRow
      anchors.centerIn: parent
      spacing: Style.space(10)

      // The bar button's play-circle, so it's clear this is the music's volume.
      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: "󰐌"
        color: root.fg
        font.family: root.font
        font.pixelSize: Style.font.body + Style.space(4)
      }

      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: !root.hasVolume || root.shownVolume === 0 ? "󰝟" : root.shownVolume < 0.34 ? "󰕿" : root.shownVolume < 0.67 ? "󰖀" : "󰕾"
        color: root.fg
        font.family: root.font
        font.pixelSize: Style.font.body
      }
      Rectangle {
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(140)
        height: Style.space(6)
        radius: height / 2
        color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.18)
        visible: root.hasVolume
        Rectangle {
          width: parent.width * Math.max(0, Math.min(1, root.shownVolume))
          height: parent.height
          radius: parent.radius
          color: root.fg
          Behavior on width { NumberAnimation { duration: 90; easing.type: Easing.OutCubic } }
        }
      }
      Text {
        anchors.verticalCenter: parent.verticalCenter
        width: root.hasVolume ? Style.space(38) : implicitWidth
        horizontalAlignment: Text.AlignRight
        text: root.hasVolume ? Math.round(root.shownVolume * 100) + "%" : "Nothing playing"
        color: root.fg
        font.family: root.font
        font.pixelSize: Style.font.caption
      }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(340))
    contentHeight: panel.fittedContentHeight(Math.max(column.implicitHeight,
      root.showSettings ? settingsCard.y + settingsCard.height - Style.space(8) : 0,
      root.showSaveCard ? saveCard.y + saveCard.height - Style.space(8) : 0))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // While typing a search, keys go to the search box (Space types a space).
      blocked: searchInput.activeFocus
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      Keys.onSpacePressed: root.togglePlay()

      // Right-click menu for queue rows; clicking anywhere else dismisses it.
      MouseArea {
        anchors.fill: parent
        z: 99
        visible: queueMenu.visible
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onClicked: queueMenu.visible = false
      }
      QueueMenu { id: queueMenu }

      // Right-click menu for search / library results.
      MouseArea {
        anchors.fill: parent
        z: 99
        visible: resultMenu.visible
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onClicked: resultMenu.visible = false
      }
      ResultMenu { id: resultMenu }

      // Settings card: floats over the player under the gear (doesn't resize
      // the popup). Clicking anywhere else, or the gear again, closes it.
      MouseArea {
        anchors.fill: parent
        z: 98
        visible: root.showSettings
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onClicked: root.showSettings = false
      }
      // Save-to-playlist card: floats over the player above the bottom row.
      MouseArea {
        anchors.fill: parent
        z: 98
        visible: root.showSaveCard
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onClicked: root.showSaveCard = false
      }
      Rectangle {
        id: saveCard
        z: 99
        visible: root.showSaveCard
        width: parent.width
        height: Math.min(saveCardColumn.implicitHeight + Style.space(20), Style.space(320))
        x: 0
        y: root.showSaveCard ? Math.max(0, saveButton.mapToItem(keyCatcher, 0, 0).y - height - Style.space(4)) : 0
        radius: Style.cornerRadius
        color: Color.menu.background
        border.width: 1
        border.color: Color.menu.border
        MouseArea { anchors.fill: parent }
        Flickable {
          anchors.fill: parent
          anchors.margins: Style.space(10)
          contentHeight: saveCardColumn.implicitHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          Column {
            id: saveCardColumn
            width: parent.width
            spacing: Style.space(4)
            Text {
              text: "SAVE \u201C" + root.mTitle.toUpperCase() + "\u201D TO"
              width: parent.width
              elide: Text.ElideRight
              color: Qt.darker(root.fg, 1.4)
              font.family: root.font
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.2
            }
            Text {
              visible: text !== ""
              text: root.saveLoading ? "Loading your playlists…" : root.saveError !== "" ? "Couldn't load playlists: " + root.saveError : ""
              color: root.fg
              opacity: 0.6
              font.family: root.font
              font.pixelSize: Style.font.caption
            }
            Repeater {
              model: root.saveLoading ? [] : root.saveTargets
              Rectangle {
                required property var modelData
                width: saveCardColumn.width
                height: Style.space(30)
                radius: Style.cornerRadius
                color: saveRowMouse.containsMouse ? Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.1) : "transparent"
                Text {
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(8)
                  anchors.right: parent.right
                  anchors.rightMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  text: (modelData.contains ? "✓  " : "") + modelData.title
                  elide: Text.ElideRight
                  color: root.fg
                  opacity: modelData.contains ? 0.55 : 1
                  font.family: root.font
                  font.pixelSize: Style.font.bodySmall
                }
                MouseArea {
                  id: saveRowMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: if (!modelData.contains) root.saveTo(modelData)
                }
              }
            }
          }
        }
      }

      Rectangle {
        id: settingsCard
        z: 99
        visible: root.showSettings
        width: parent.width
        height: settingsCardColumn.implicitHeight + Style.space(20)
        x: parent.width - width
        y: root.showSettings ? settingsButton.mapToItem(keyCatcher, 0, settingsButton.height).y + Style.space(4) : 0
        radius: Style.cornerRadius
        color: Color.menu.background
        border.width: 1
        border.color: Color.menu.border

        // Swallow clicks on the card so they don't reach the dismiss layer.
        MouseArea { anchors.fill: parent }

        Column {
          id: settingsCardColumn
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: parent.top
          anchors.margins: Style.space(10)
          spacing: Style.space(8)

          Text {
            text: "MUSIC SETTINGS"
            color: Qt.darker(root.fg, 1.4)
            font.family: root.font
            font.pixelSize: Style.font.caption
            font.bold: true
            font.letterSpacing: 1.2
          }

          Item {
            width: parent.width
            height: Math.max(pauseText.implicitHeight, pauseSwitch.implicitHeight)
            Column {
              id: pauseText
              anchors.left: parent.left
              anchors.right: pauseSwitch.left
              anchors.rightMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)
              Text {
                width: parent.width
                text: "Pause music when other audio starts"
                wrapMode: Text.Wrap
                color: root.fg
                font.family: root.font
                font.pixelSize: Style.font.bodySmall
              }
              Text {
                width: parent.width
                text: "A YouTube video or another app playing pauses YouTube Music. It won't resume on its own."
                wrapMode: Text.Wrap
                color: root.fg
                opacity: 0.55
                font.family: root.font
                font.pixelSize: Style.font.caption
              }
            }
            ToggleSwitch {
              id: pauseSwitch
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              checked: root.pauseForOtherAudio
              foreground: root.fg
              onToggled: root.setMusicPref("pauseForOtherAudio", !root.pauseForOtherAudio)
            }
          }

          Rectangle { width: parent.width; height: 1; color: root.fg; opacity: 0.12 }

          // Equalizer: on/off + bass / mid / treble.
          Item {
            width: parent.width
            height: Math.max(eqTitle.implicitHeight, eqSwitch.implicitHeight)
            Text {
              id: eqTitle
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: "Equalizer"
              color: root.fg
              font.family: root.font
              font.pixelSize: Style.font.bodySmall
            }
            ToggleSwitch {
              id: eqSwitch
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              checked: root.eqOn
              foreground: root.fg
              onToggled: root.setEqOn(!root.eqOn)
            }
          }
          Repeater {
            model: [{ band: "bass", label: "Bass" }, { band: "mid", label: "Mid" }, { band: "treble", label: "Treble" }]
            Item {
              required property var modelData
              width: settingsCardColumn.width
              height: Style.space(22)
              opacity: root.eqOn ? 1 : 0.4
              enabled: root.eqOn
              Text {
                id: eqBandLabel
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(52)
                text: modelData.label
                color: root.fg
                opacity: 0.7
                font.family: root.font
                font.pixelSize: Style.font.caption
              }
              PanelSlider {
                id: eqSlider
                bar: root.bar
                anchors.left: eqBandLabel.right
                anchors.right: eqBandValue.left
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                height: Style.space(18)
                minimum: -12
                maximum: 12
                step: 1
                integer: true
                value: root.eqValue(modelData.band)
                onReleased: function(v) { root.setEq(modelData.band, v) }
              }
              Text {
                id: eqBandValue
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(44)
                horizontalAlignment: Text.AlignRight
                readonly property int v: Math.round(eqSlider.dragging ? eqSlider.liveValue : root.eqValue(modelData.band))
                text: (v > 0 ? "+" : "") + v + " dB"
                color: root.fg
                opacity: 0.6
                font.family: root.font
                font.pixelSize: Style.font.caption
              }
            }
          }

          Rectangle { width: parent.width; height: 1; color: root.fg; opacity: 0.12 }

          // Sleep timer: pause after N minutes or at the end of the song.
          Text {
            width: parent.width
            text: "Sleep timer" + (root.sleepOn ? "  ·  " + (root.sleepEndOfSong ? "end of this song" : root.sleepLabel + " left") : "")
            color: root.fg
            font.family: root.font
            font.pixelSize: Style.font.bodySmall
          }
          Flow {
            width: parent.width
            spacing: Style.space(6)
            Repeater {
              model: [
                { label: "Off", minutes: 0 }, { label: "15m", minutes: 15 }, { label: "30m", minutes: 30 },
                { label: "60m", minutes: 60 }, { label: "End of song", minutes: -1 }
              ]
              Rectangle {
                required property var modelData
                readonly property bool on: modelData.minutes === 0 ? !root.sleepOn
                  : modelData.minutes === -1 ? root.sleepEndOfSong : false
                width: sleepLabelText.implicitWidth + Style.space(16)
                height: sleepLabelText.implicitHeight + Style.space(8)
                radius: height / 2
                color: on ? root.fg : Qt.rgba(root.fg.r, root.fg.g, root.fg.b, sleepMouse.containsMouse ? 0.16 : 0.08)
                Text {
                  id: sleepLabelText
                  anchors.centerIn: parent
                  text: modelData.label
                  color: parent.on ? Color.menu.background : root.fg
                  font.family: root.font
                  font.pixelSize: Style.font.caption
                }
                MouseArea {
                  id: sleepMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.setSleep(modelData.minutes)
                }
              }
            }
          }

          Rectangle { width: parent.width; height: 1; color: root.fg; opacity: 0.12 }

          // Song-change notification (off by default) and the bar icon's progress ring.
          Repeater {
            model: [
              { key: "notifySongChange", label: "Show the song card when the song changes", on: root.notifySongs },
              { key: "progressRing", label: "Progress ring on the bar icon", on: root.progressRing }
            ]
            Item {
              required property var modelData
              width: settingsCardColumn.width
              height: Math.max(optLabel.implicitHeight, optSwitch.implicitHeight)
              Text {
                id: optLabel
                anchors.left: parent.left
                anchors.right: optSwitch.left
                anchors.rightMargin: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
                text: modelData.label
                wrapMode: Text.Wrap
                color: root.fg
                font.family: root.font
                font.pixelSize: Style.font.bodySmall
              }
              ToggleSwitch {
                id: optSwitch
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                checked: modelData.on
                foreground: root.fg
                onToggled: root.setMusicPref(modelData.key, !modelData.on)
              }
            }
          }

          Rectangle { width: parent.width; height: 1; color: root.fg; opacity: 0.12 }

          Text {
            width: parent.width
            text: "Artist page sections (tap to hide / show)"
            color: root.fg
            font.family: root.font
            font.pixelSize: Style.font.bodySmall
          }
          Flow {
            width: parent.width
            spacing: Style.space(6)
            Repeater {
              model: root.artistSectionTypes
              Rectangle {
                required property var modelData
                readonly property bool on: root.sectionTypeOn(modelData.name)
                width: sectionLabel.implicitWidth + Style.space(16)
                height: sectionLabel.implicitHeight + Style.space(8)
                radius: height / 2
                color: on ? root.fg : Qt.rgba(root.fg.r, root.fg.g, root.fg.b, sectionMouse.containsMouse ? 0.16 : 0.08)
                Text {
                  id: sectionLabel
                  anchors.centerIn: parent
                  text: (parent.on ? "✓ " : "") + modelData.name
                  color: parent.on ? Color.menu.background : root.fg
                  opacity: parent.on ? 1 : 0.7
                  font.family: root.font
                  font.pixelSize: Style.font.caption
                }
                MouseArea {
                  id: sectionMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.setSectionType(modelData.name, !parent.on)
                }
              }
            }
          }
        }
      }

      Column {
        id: column
        width: parent.width
        spacing: Style.space(12)

        // ---------- Page-change warning (from the health check) ----------
        Rectangle {
          visible: root.healthKey !== ""
          width: parent.width
          height: healthText.implicitHeight + Style.space(12)
          radius: Style.cornerRadius
          color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.08)
          border.width: 1
          border.color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.25)
          Text {
            id: healthText
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.margins: Style.space(8)
            wrapMode: Text.Wrap
            text: "󰀦  YouTube Music changed its page. Not working here: " + root.healthKey + ". Check for a plugin update."
            color: root.fg
            font.family: root.font
            font.pixelSize: Style.font.caption
          }
        }

        // ---------- Cover + song ----------
        Item {
          width: parent.width
          height: cover.height

          Rectangle {
            id: cover
            width: Style.space(72)
            height: width
            radius: Style.cornerRadius
            color: Qt.darker(Color.menu.background, 1.3)
            clip: true

            Text {
              anchors.centerIn: parent
              visible: art.status !== Image.Ready
              text: "󰝚"
              color: root.fg
              opacity: 0.5
              font.family: root.font
              font.pixelSize: Style.font.display
            }
            Image {
              id: art
              anchors.fill: parent
              source: root.mArt
              fillMode: Image.PreserveAspectCrop
              asynchronous: true
            }
          }

          Column {
            anchors.left: cover.right
            anchors.leftMargin: Style.space(14)
            anchors.right: expand.left
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: cover.verticalCenter
            spacing: Style.space(3)

            // Song name and artist · album: while the mouse is anywhere over
            // them, whichever is too long to read scrolls in a loop.
            HoverHandler { id: headerTextHover }
            Marquee {
              width: parent.width
              text: root.mTitle !== "" ? root.mTitle : "Nothing playing"
              pixelSize: Style.font.title
              bold: true
              hovered: headerTextHover.hovered
            }
            Marquee {
              width: parent.width
              visible: text !== ""
              text: root.hasMusic ? root.mByline : "Open YouTube Music to start listening"
              pixelSize: Style.font.bodySmall
              textOpacity: 0.7
              hovered: headerTextHover.hovered
            }
          }

          // Settings (far right) and expand (open the full YouTube Music window).
          IconButton {
            id: settingsButton
            anchors.right: parent.right
            anchors.top: parent.top
            icon: "󰒓"
            size: Style.font.title
            opacity: root.showSettings ? 1 : 0.75
            onClicked: root.showSettings = !root.showSettings
          }
          IconButton {
            id: expand
            anchors.right: settingsButton.left
            anchors.top: parent.top
            icon: "󰊓"
            size: Style.font.title
            onClicked: root.openApp()
          }
        }

        // ---------- Progress ----------
        Column {
          width: parent.width
          spacing: Style.space(4)
          visible: root.length > 0

          PanelSlider {
            id: progress
            bar: root.bar
            width: parent.width
            height: Style.space(18)
            minimum: 0
            maximum: Math.max(1, root.length)
            step: 1
            value: root.position
            onReleased: function(v) { root.seekTo(v) }
          }

          Item {
            width: parent.width
            height: elapsed.implicitHeight
            Text {
              id: elapsed
              text: root.formatTime(progress.dragging ? progress.liveValue : root.position)
              color: root.fg
              opacity: 0.6
              font.family: root.font
              font.pixelSize: Style.font.caption
            }
            Text {
              anchors.right: parent.right
              text: root.formatTime(root.length)
              color: root.fg
              opacity: 0.6
              font.family: root.font
              font.pixelSize: Style.font.caption
            }
          }
        }

        // ---------- Controls ----------
        Item {
          width: parent.width
          height: playButton.height

          IconButton {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            icon: root.rating === "dislike" ? "󰔑" : "󰔒"
            enabled: root.hasMusic
            onClicked: root.rate("dislike")
          }

          Row {
            anchors.centerIn: parent
            spacing: Style.space(18)

            IconButton {
              anchors.verticalCenter: parent.verticalCenter
              icon: "󰒮"
              size: Style.font.title * 1.3
              enabled: root.hasMusic
              onClicked: root.prevTrack()
            }
            IconButton {
              id: playButton
              anchors.verticalCenter: parent.verticalCenter
              icon: root.playing ? "󰏤" : "󰐊"
              size: Style.font.display
              enabled: root.hasMusic
              onClicked: root.togglePlay()
            }
            IconButton {
              anchors.verticalCenter: parent.verticalCenter
              icon: "󰒭"
              size: Style.font.title * 1.3
              enabled: root.hasMusic
              onClicked: root.nextTrack()
            }
          }

          IconButton {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            icon: root.rating === "like" ? "󰔓" : "󰔔"
            enabled: root.hasMusic
            onClicked: root.rate("like")
          }
        }

        // ---------- Volume ----------
        Item {
          width: parent.width
          height: Math.max(muteButton.height, volumeSlider.height)
          visible: root.hasMusic
          opacity: root.hasVolume ? 1 : 0.4
          enabled: root.hasVolume

          IconButton {
            id: muteButton
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            icon: root.muted || root.volume === 0 ? "󰝟" : root.volume < 0.34 ? "󰕿" : root.volume < 0.67 ? "󰖀" : "󰕾"
            onClicked: root.toggleMute()
          }
          PanelSlider {
            id: volumeSlider
            bar: root.bar
            anchors.left: muteButton.right
            anchors.leftMargin: Style.space(8)
            anchors.right: volumeText.left
            anchors.rightMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            height: Style.space(18)
            minimum: 0
            maximum: 1
            step: 0.01
            value: root.muted ? 0 : root.volume
            onMoved: function(v) { root.setVolume(v) }
            onReleased: function(v) { root.setVolume(v) }
          }
          Text {
            id: volumeText
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(36)
            horizontalAlignment: Text.AlignRight
            text: Math.round((volumeSlider.dragging ? volumeSlider.liveValue : (root.muted ? 0 : root.volume)) * 100) + "%"
            color: root.fg
            opacity: 0.6
            font.family: root.font
            font.pixelSize: Style.font.caption
          }
        }

        // ---------- Bottom row: queue (left), shuffle (right) ----------
        Item {
          width: parent.width
          height: shuffleButton.height + Style.space(4)
          visible: root.hasMusic

          // Queue / Search / Library: one view at a time; a dot marks the open one.
          Row {
            id: viewButtons
            anchors.left: parent.left
            anchors.top: parent.top
            spacing: Style.space(4)
            Repeater {
              model: [
                { view: "queue", icon: "󰍜" },
                { view: "search", icon: "󰍉" },
                { view: "library", icon: "󰲸" },
                { view: "speeddial", icon: "󰓅" },
                { view: "lyrics", icon: "󰍬" }
              ]
              Item {
                required property var modelData
                width: viewIcon.width
                height: viewIcon.height + Style.space(4)
                IconButton {
                  id: viewIcon
                  icon: modelData.icon
                  opacity: root.bottomView === modelData.view ? 1 : 0.75
                  onClicked: root.setView(modelData.view)
                }
                Rectangle {
                  anchors.horizontalCenter: viewIcon.horizontalCenter
                  anchors.top: viewIcon.bottom
                  width: Style.space(4)
                  height: width
                  radius: width / 2
                  color: root.fg
                  visible: root.bottomView === modelData.view
                }
              }
            }
          }

          // Right side: sleep timer (when set) · radio · save to playlist · repeat · shuffle.
          Row {
            id: rightButtons
            anchors.right: parent.right
            anchors.top: parent.top
            spacing: Style.space(2)

            Text {
              visible: root.sleepOn
              anchors.verticalCenter: parent.verticalCenter
              text: "󰖔 " + root.sleepLabel
              color: root.fg
              opacity: 0.75
              font.family: root.font
              font.pixelSize: Style.font.caption
              rightPadding: Style.space(4)
              MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.setSleep(0) }
            }
            IconButton { icon: "󰐹"; onClicked: root.startRadio() }
            IconButton { id: saveButton; icon: "󰐒"; opacity: root.showSaveCard ? 1 : 0.85; onClicked: root.openSaveCard() }
            Item {
              width: repeatButton.width
              height: repeatButton.height + Style.space(4)
              IconButton {
                id: repeatButton
                icon: root.repeatMode === "ONE" ? "󰑘" : root.repeatMode === "ALL" ? "󰑖" : "󰑗"
                opacity: root.repeatMode === "NONE" ? 0.75 : 1
                onClicked: root.bridgeCmd(["repeat"])
              }
              Rectangle {
                anchors.horizontalCenter: repeatButton.horizontalCenter
                anchors.top: repeatButton.bottom
                width: Style.space(4); height: width; radius: width / 2
                color: root.fg
                visible: root.repeatMode !== "NONE"
              }
            }
            Item {
              width: shuffleButton.width
              height: shuffleButton.height + Style.space(4)
              IconButton {
                id: shuffleButton
                icon: "󰒟"
                onClicked: root.shuffle()
              }
              // Dot under shuffle while it's on (needs the bridge to know).
              Rectangle {
                anchors.horizontalCenter: shuffleButton.horizontalCenter
                anchors.top: shuffleButton.bottom
                width: Style.space(4); height: width; radius: width / 2
                color: root.fg
                visible: root.shuffleOn
              }
            }
          }
        }

        // ---------- Search ----------
        Column {
          width: parent.width
          spacing: Style.space(8)
          visible: root.bottomView === "search" && root.hasMusic

          Rectangle { width: parent.width; height: 1; color: root.fg; opacity: 0.12 }

          Rectangle {
            width: parent.width
            height: Style.space(34)
            radius: Style.cornerRadius
            color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.07)
            border.width: searchInput.activeFocus ? 1 : 0
            border.color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.35)
            Text {
              id: searchGlyph
              anchors.left: parent.left
              anchors.leftMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              text: "󰍉"
              color: root.fg
              opacity: 0.6
              font.family: root.font
              font.pixelSize: Style.font.body
            }
            TextInput {
              id: searchInput
              anchors.left: searchGlyph.right
              anchors.leftMargin: Style.space(8)
              anchors.right: parent.right
              anchors.rightMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              color: root.fg
              font.family: root.font
              font.pixelSize: Style.font.bodySmall
              clip: true
              selectByMouse: true
              onAccepted: { liveSearch.stop(); root.runSearch(text) }
              onTextChanged: liveSearch.restart()
              Keys.onEscapePressed: { if (text !== "") text = ""; else root.bottomView = "" }
              Text {
                anchors.fill: parent
                verticalAlignment: Text.AlignVCenter
                visible: searchInput.text === "" && !searchInput.activeFocus
                text: "Search songs, albums, playlists…"
                color: root.fg
                opacity: 0.4
                font: searchInput.font
              }
            }
          }

          // Filter chips (All + YouTube Music's own); scroll wheel moves them sideways.
          ChipBar {
            width: parent.width
            visible: !root.showArtist
            labels: root.chipLabels
            selected: root.selectedChip
            onPicked: function(index) { root.chooseChip(index) }
          }

          Text {
            width: parent.width
            visible: !root.showArtist && text !== ""
            wrapMode: Text.Wrap
            text: !root.bridgeOn ? "Search needs the YT Music bar bridge."
              : root.searching ? "Searching…"
              : root.searchError !== "" ? "Search failed: " + root.searchError
              : (root.lastQuery !== "" && root.searchItems.length === 0) ? "No results."
              : root.searchItems.length > 0 ? "Click to play · hover for more · artists open their page"
              : "Start typing to search" + (root.chipLabel !== "" ? " " + root.chipLabel.toLowerCase() : "")
            color: root.fg
            opacity: 0.55
            font.family: root.font
            font.pixelSize: Style.font.caption
          }

          ResultList {
            width: parent.width
            visible: !root.showArtist && items.length > 0
            items: root.searchItems
            listName: "search"
            opacity: root.searching ? 0.55 : 1
          }

          // ---- Artist page: back · name · Shuffle / Radio, then their music.
          Item {
            width: parent.width
            height: Math.max(artistBack.height, artistButtons.height)
            visible: root.showArtist

            IconButton {
              id: artistBack
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              icon: "󰁍"
              onClicked: root.showArtist = false
            }
            Text {
              anchors.left: artistBack.right
              anchors.leftMargin: Style.space(6)
              anchors.right: artistButtons.left
              anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              text: root.artistTitle
              elide: Text.ElideRight
              color: root.fg
              font.family: root.font
              font.pixelSize: Style.font.body
              font.bold: true
            }
            Row {
              id: artistButtons
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(6)
              Repeater {
                model: [
                  { mode: "shuffle", label: "󰒟  Shuffle", show: root.artistHasShuffle },
                  { mode: "radio", label: "󰐹  Radio", show: root.artistHasRadio }
                ]
                Rectangle {
                  required property var modelData
                  visible: modelData.show && !root.artistLoading
                  width: artistBtnText.implicitWidth + Style.space(16)
                  height: artistBtnText.implicitHeight + Style.space(10)
                  radius: height / 2
                  color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, artistBtnMouse.containsMouse ? 0.18 : 0.1)
                  Text {
                    id: artistBtnText
                    anchors.centerIn: parent
                    text: modelData.label
                    color: root.fg
                    font.family: root.font
                    font.pixelSize: Style.font.caption
                  }
                  MouseArea {
                    id: artistBtnMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.playArtist(modelData.mode)
                  }
                }
              }
            }
          }
          Text {
            width: parent.width
            visible: root.showArtist && text !== ""
            wrapMode: Text.Wrap
            text: root.artistLoading ? "Loading " + root.artistTitle + "…"
              : root.artistError !== "" ? "Couldn't open this artist: " + root.artistError
              : root.artistAllSongsOn && root.artistSongsLoading ? "Loading all of " + root.artistTitle + "'s songs…"
              : root.artistAllSongsOn && root.artistSongsError !== "" ? "Couldn't load all songs: " + root.artistSongsError
              : root.artistAllSongsOn ? root.artistSongsItems.length + " songs"
              : root.artistItems.length === 0 ? "Nothing to show." : ""
            color: root.fg
            opacity: 0.55
            font.family: root.font
            font.pixelSize: Style.font.caption
          }
          ChipBar {
            width: parent.width
            visible: root.showArtist && !root.artistLoading && root.artistChipLabels.length > 1
            labels: root.artistChipLabels
            selected: root.artistChipLabels.indexOf(root.artistSectionLabel)
            onPicked: function(index) { root.pickArtistChip(index) }
          }
          // All songs: play the whole list in order, or shuffled.
          Row {
            spacing: Style.space(6)
            visible: root.showArtist && root.artistAllSongsOn && !root.artistSongsLoading
              && root.artistSongsCanPlay && root.artistSongsItems.length > 0
            Repeater {
              model: [
                { mode: "play", label: "󰐊  Play all" },
                { mode: "shuffle", label: "󰒟  Shuffle all" }
              ]
              Rectangle {
                required property var modelData
                width: playAllText.implicitWidth + Style.space(18)
                height: playAllText.implicitHeight + Style.space(10)
                radius: height / 2
                color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, playAllMouse.containsMouse ? 0.18 : 0.1)
                Text {
                  id: playAllText
                  anchors.centerIn: parent
                  text: modelData.label
                  color: root.fg
                  font.family: root.font
                  font.pixelSize: Style.font.caption
                }
                MouseArea {
                  id: playAllMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.playAllSongs(modelData.mode)
                }
              }
            }
          }
          ResultList {
            width: parent.width
            visible: root.showArtist && items.length > 0
            items: root.artistLoading ? [] : root.artistShown
            listName: root.artistAllSongsOn ? "artistsongs" : "artist"
          }
        }

        // ---------- Library ----------
        Column {
          width: parent.width
          spacing: Style.space(8)
          visible: root.bottomView === "library" && root.hasMusic

          Rectangle { width: parent.width; height: 1; color: root.fg; opacity: 0.12 }

          Item {
            width: parent.width
            height: Math.max(libraryHint.implicitHeight, eyeToggle.height)
            Text {
              id: libraryHint
              anchors.left: parent.left
              anchors.right: eyeToggle.left
              anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              wrapMode: Text.Wrap
              text: !root.bridgeOn ? "Your library needs the YT Music bar bridge."
                : root.libraryError !== "" ? "Couldn't load your library: " + root.libraryError
                : root.libraryItems.length === 0 ? "Loading your library…"
                : root.showHidden ? "Showing hidden ones (dimmed) · 󰈈 on a row unhides it"
                : "Click to play · hover for more · 󰃃 pins · 󰈉 hides"
              color: root.fg
              opacity: 0.55
              font.family: root.font
              font.pixelSize: Style.font.caption
            }
            // Eye: show / hide the hidden albums and playlists.
            Rectangle {
              id: eyeToggle
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              visible: root.hiddenCount > 0 || root.showHidden
              width: visible ? eyeText.implicitWidth + Style.space(14) : 0
              height: eyeText.implicitHeight + Style.space(8)
              radius: height / 2
              color: root.showHidden ? root.fg : Qt.rgba(root.fg.r, root.fg.g, root.fg.b, eyeMouse.containsMouse ? 0.16 : 0.08)
              Text {
                id: eyeText
                anchors.centerIn: parent
                text: (root.showHidden ? "󰈈" : "󰈉") + "  " + root.hiddenCount
                color: root.showHidden ? Color.menu.background : root.fg
                font.family: root.font
                font.pixelSize: Style.font.caption
              }
              MouseArea {
                id: eyeMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.showHidden = !root.showHidden
              }
            }
          }

          ChipBar {
            width: parent.width
            visible: root.librarySections.length > 1
            labels: root.librarySections
            selected: root.librarySections.indexOf(root.libraryFilter)
            onPicked: function(index) {
              var label = index < 0 ? "" : root.librarySections[index]
              root.libraryFilter = label === root.libraryFilter ? "" : label
            }
          }

          Text {
            visible: root.pins.length > 0
            text: "PINNED"
            color: Qt.darker(root.fg, 1.4)
            font.family: root.font
            font.pixelSize: Style.font.caption
            font.bold: true
            font.letterSpacing: 1.2
          }
          ResultList {
            width: parent.width
            items: root.pins
            listName: "pinned"
            maxHeight: Style.space(156)
          }

          Text {
            visible: root.pins.length > 0 && root.libraryShown.length > 0
            text: "YOUR LIBRARY"
            color: Qt.darker(root.fg, 1.4)
            font.family: root.font
            font.pixelSize: Style.font.caption
            font.bold: true
            font.letterSpacing: 1.2
          }
          ResultList {
            width: parent.width
            items: root.libraryShown
            listName: "library"
            maxHeight: root.pins.length > 0 ? Style.space(220) : Style.space(300)
          }
        }

        // ---------- Speed dial ----------
        Column {
          width: parent.width
          spacing: Style.space(8)
          visible: root.bottomView === "speeddial" && root.hasMusic

          Rectangle { width: parent.width; height: 1; color: root.fg; opacity: 0.12 }

          Text {
            width: parent.width
            wrapMode: Text.Wrap
            text: !root.bridgeOn ? "Speed dial needs the YT Music bar bridge."
              : root.speedDialLoading ? "Loading your speed dial…"
              : root.speedDialError !== "" ? "Couldn't load it: " + root.speedDialError
              : (root.speedDialTitle !== "" && root.speedDialTitle.toLowerCase() !== "speed dial"
                  ? root.speedDialTitle + " (your speed dial)" : "Speed dial") + " · click to play · hover for more"
            color: root.fg
            opacity: 0.55
            font.family: root.font
            font.pixelSize: Style.font.caption
          }

          ChipBar {
            width: parent.width
            visible: root.history.length > 0
            labels: ["Recently played"]
            selected: root.speedDialRecent ? 0 : -1
            onPicked: function(index) { root.speedDialRecent = index === 0 && !root.speedDialRecent }
          }
          ResultList {
            width: parent.width
            items: root.speedDialRecent ? root.history : root.speedDialItems
            listName: root.speedDialRecent ? "history" : "speeddial"
          }
        }

        // ---------- Lyrics ----------
        Column {
          width: parent.width
          spacing: Style.space(8)
          visible: root.bottomView === "lyrics" && root.hasMusic

          Rectangle { width: parent.width; height: 1; color: root.fg; opacity: 0.12 }

          Text {
            width: parent.width
            visible: text !== ""
            wrapMode: Text.Wrap
            text: !root.bridgeOn ? "Lyrics need the YT Music bar bridge."
              : root.lyricsLoading ? "Loading lyrics…" : root.lyricsNote
            color: root.fg
            opacity: 0.55
            font.family: root.font
            font.pixelSize: Style.font.caption
          }

          Flickable {
            id: lyricsScroll
            width: parent.width
            height: Math.min(lyricsBody.implicitHeight, Style.space(300))
            visible: root.lyricsText !== "" && !root.lyricsLoading
            contentHeight: lyricsBody.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            Text {
              id: lyricsBody
              width: lyricsScroll.width - Style.space(10)
              text: root.lyricsText
              wrapMode: Text.Wrap
              lineHeight: 1.25
              color: root.fg
              font.family: root.font
              font.pixelSize: Style.font.bodySmall
            }
          }
          Text {
            width: parent.width
            visible: root.lyricsSource !== "" && !root.lyricsLoading
            text: root.lyricsSource
            wrapMode: Text.Wrap
            color: root.fg
            opacity: 0.45
            font.family: root.font
            font.pixelSize: Style.font.caption
          }
        }

        // ---------- Queue ----------
        Column {
          width: parent.width
          spacing: Style.space(6)
          visible: root.showQueue && root.hasMusic

          Rectangle {
            width: parent.width
            height: 1
            color: root.fg
            opacity: 0.12
          }

          Text {
            width: parent.width
            text: !root.bridgeOn
              ? "The queue needs the YT Music bar bridge. Run " + root.pluginDir + "/setup.sh once, then in Chromium open chrome://extensions, turn on Developer mode, click \"Load unpacked\" and pick " + root.pluginDir + "/bridge/extension. Then reload YouTube Music."
              : root.queue.length === 0
                ? "Queue is empty (open the player in YouTube Music once if this stays empty)."
                : "Up next · click to play · drag ⋮⋮ to reorder · swipe left (all the way) or right-click to remove"
            wrapMode: Text.Wrap
            color: root.fg
            opacity: 0.6
            font.family: root.font
            font.pixelSize: Style.font.caption
          }

          // Queue list + scrollbar on the right (drag the handle or click the track).
          Item {
            width: parent.width
            height: Math.min(queueColumn.implicitHeight, Style.space(280))
            visible: root.bridgeOn && root.queue.length > 0

            Flickable {
              id: queueScroll
              // Leave room on the right for the scrollbar when the list scrolls.
              width: parent.width - (scrollable ? queueBar.width + Style.space(6) : 0)
              height: parent.height
              readonly property bool scrollable: contentHeight > height + 1
              contentHeight: queueColumn.implicitHeight
              clip: true
              boundsBehavior: Flickable.StopAtBounds
              interactive: scrollable && root.dragFrom < 0

              // Where a dragged song will land.
              Rectangle {
                z: 20
                visible: root.dragFrom >= 0 && root.dragTo >= 0 && root.dragTo !== root.dragFrom
                x: Style.space(4)
                width: queueColumn.width - Style.space(8)
                height: 2
                radius: 1
                color: root.fg
                y: root.dragTo > root.dragFrom
                  ? (root.dragTo + 1) * root.queuePitch - Style.space(2) / 2 - 1
                  : Math.max(0, root.dragTo * root.queuePitch - Style.space(2) / 2 - 1)
              }

              // While dragging near the top / bottom edge, scroll the list.
              Timer {
                interval: 16
                repeat: true
                running: root.dragFrom >= 0 && queueScroll.scrollable
                onTriggered: {
                  var edge = Style.space(28)
                  var step = 0
                  if (root.dragViewY < edge) step = -Math.ceil((edge - root.dragViewY) / 4)
                  else if (root.dragViewY > queueScroll.height - edge) step = Math.ceil((root.dragViewY - (queueScroll.height - edge)) / 4)
                  if (step === 0) return
                  var maxY = Math.max(0, queueScroll.contentHeight - queueScroll.height)
                  queueScroll.contentY = Math.max(0, Math.min(maxY, queueScroll.contentY + step))
                  root.updateDragTarget()
                }
              }

              Column {
                id: queueColumn
                width: queueScroll.width
                spacing: Style.space(2)

                Repeater {
                  model: root.queue.slice(root.queueOffset, root.queueOffset + root.queueShown)

                  Item {
                    id: row
                    required property var modelData
                    required property int index
                    width: queueColumn.width
                    height: rowContent.height
                    clip: true
                    readonly property bool dragging: root.dragFrom === index
                    Connections {
                      target: root
                      function onRevealedIndexChanged() {
                        if (root.revealedIndex !== row.index && rowContent.x < 0 && rowContent.x > -row.width && !rowMouse.pressed)
                          rowContent.x = 0
                      }
                    }
                    z: dragging ? 10 : 0
                    opacity: dragging ? 0.92 : 1
                    transform: Translate { y: row.dragging ? root.dragDy : 0 }

                    // Revealed behind the row while swiping left; the right part
                    // is the Remove button when the row stops half way.
                    // Only the strip the row has slid away from (right side) turns red.
                    Rectangle {
                      anchors.right: parent.right
                      anchors.top: parent.top
                      anchors.bottom: parent.bottom
                      width: Math.max(0, -rowContent.x - Style.space(2))
                      visible: width > 0
                      radius: Style.cornerRadius
                      color: Color.urgent !== undefined ? Color.urgent : "#c0392b"
                      clip: true
                      Text {
                        anchors.right: parent.right
                        width: Math.min(parent.width, root.revealWidth)
                        horizontalAlignment: Text.AlignHCenter
                        anchors.verticalCenter: parent.verticalCenter
                        opacity: parent.width > Style.space(24) ? 1 : 0
                        text: "󰆴  Remove"
                        color: "white"
                        font.family: root.font
                        font.pixelSize: Style.font.bodySmall
                        font.bold: true
                      }
                    }

                    Rectangle {
                      id: rowContent
                      width: row.width
                      height: Style.space(42)
                      radius: Style.cornerRadius
                      color: row.modelData.current
                        ? Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.12)
                        : (rowMouse.containsMouse ? Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.07) : Color.menu.background)
                      Behavior on x {
                        enabled: !rowMouse.drag.active
                        NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
                      }

                      Text {
                        id: rowMarker
                        anchors.left: parent.left
                        anchors.leftMargin: Style.space(8)
                        anchors.verticalCenter: parent.verticalCenter
                        width: Style.space(18)
                        // Now playing gets the icon; up next is numbered 1, 2, 3…
                        text: row.modelData.current ? (root.playing ? "󰐊" : "󰏤")
                          : String(row.index + (root.currentQueueIndex >= 0 ? 0 : 1))
                        horizontalAlignment: Text.AlignHCenter
                        color: root.fg
                        opacity: row.modelData.current ? 1 : 0.5
                        font.family: root.font
                        font.pixelSize: Style.font.caption
                      }
                      // Album cover (from the bridge); note glyph until it loads.
                      Rectangle {
                        id: rowCover
                        anchors.left: rowMarker.right
                        anchors.leftMargin: Style.space(6)
                        anchors.verticalCenter: parent.verticalCenter
                        width: Style.space(32)
                        height: width
                        radius: Math.max(3, Style.cornerRadius / 2)
                        color: Qt.darker(Color.menu.background, 1.3)
                        clip: true
                        Text {
                          anchors.centerIn: parent
                          visible: rowArt.status !== Image.Ready
                          text: "󰝚"
                          color: root.fg
                          opacity: 0.4
                          font.family: root.font
                          font.pixelSize: Style.font.bodySmall
                        }
                        Image {
                          id: rowArt
                          anchors.fill: parent
                          source: row.modelData.art || ""
                          sourceSize.width: 64
                          sourceSize.height: 64
                          fillMode: Image.PreserveAspectCrop
                          asynchronous: true
                          cache: true
                        }
                      }
                      Column {
                        anchors.left: rowCover.right
                        anchors.leftMargin: Style.space(10)
                        anchors.right: rowDuration.left
                        anchors.rightMargin: Style.space(8)
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Style.space(1)
                        // Title: a long one scrolls like a ticker while the row is
                        // hovered — the start comes round again after a small gap.
                        Item {
                          id: titleBox
                          width: parent.width
                          height: titleText.implicitHeight
                          clip: true
                          readonly property real gap: Style.space(32)
                          readonly property bool overflowing: titleText.implicitWidth > width
                          readonly property bool scrolling: rowMouse.containsMouse && overflowing && rowContent.x === 0
                          Row {
                            id: ticker
                            spacing: titleBox.gap
                            Text {
                              id: titleText
                              width: titleBox.scrolling ? implicitWidth : titleBox.width
                              text: row.modelData.title
                              elide: titleBox.scrolling ? Text.ElideNone : Text.ElideRight
                              color: root.fg
                              font.family: root.font
                              font.pixelSize: Style.font.bodySmall
                              font.bold: row.modelData.current
                            }
                            // Second copy that follows the first round.
                            Text {
                              visible: titleBox.scrolling
                              text: row.modelData.title
                              color: root.fg
                              font: titleText.font
                            }
                          }
                          SequentialAnimation {
                            running: titleBox.scrolling
                            loops: Animation.Infinite
                            onRunningChanged: if (!running) ticker.x = 0
                            PauseAnimation { duration: 700 }
                            NumberAnimation {
                              target: ticker; property: "x"
                              from: 0
                              to: -(titleText.implicitWidth + titleBox.gap)
                              // ~40 px a second, steady.
                              duration: (titleText.implicitWidth + titleBox.gap) * 50
                              easing.type: Easing.Linear
                            }
                          }
                        }
                        // Artist line: scrolls with the title while the row is hovered.
                        Marquee {
                          width: parent.width
                          text: row.modelData.artist
                          pixelSize: Style.font.caption
                          textOpacity: 0.6
                          hovered: rowMouse.containsMouse && rowContent.x === 0
                        }
                      }
                      // Grip: 2 x 3 dots (drawn, so it doesn't depend on the icon font).
                      Item {
                        id: rowGrip
                        anchors.right: parent.right
                        anchors.rightMargin: Style.space(8)
                        anchors.verticalCenter: parent.verticalCenter
                        width: Style.space(14)
                        height: Style.space(16)
                        visible: !row.modelData.current
                        opacity: gripMouse.containsMouse || row.dragging ? 0.9 : (rowMouse.containsMouse ? 0.5 : 0.25)
                        Grid {
                          anchors.centerIn: parent
                          columns: 2
                          rowSpacing: Style.space(3)
                          columnSpacing: Style.space(4)
                          Repeater {
                            model: 6
                            Rectangle {
                              width: Style.space(3)
                              height: width
                              radius: width / 2
                              color: root.fg
                            }
                          }
                        }
                      }
                      Text {
                        id: rowDuration
                        anchors.right: rowGrip.left
                        anchors.rightMargin: Style.space(6)
                        anchors.verticalCenter: parent.verticalCenter
                        text: row.modelData.duration
                        color: root.fg
                        opacity: 0.5
                        font.family: root.font
                        font.pixelSize: Style.font.caption
                      }
                    }

                    MouseArea {
                      id: rowMouse
                      anchors.fill: parent
                      hoverEnabled: true
                      acceptedButtons: Qt.LeftButton | Qt.RightButton
                      cursorShape: Qt.PointingHandCursor
                      drag.target: rowContent
                      drag.axis: Drag.XAxis
                      drag.minimumX: -row.width
                      drag.maximumX: 0
                      drag.threshold: Style.space(5)
                      preventStealing: true
                      property bool swiped: false
                      property real pressX: 0
                      property real startX: 0
                      onPressed: function(mouse) {
                        swiped = false
                        pressX = mouse.x
                        startX = rowContent.x
                        // Touching another row closes any open Remove button.
                        if (root.revealedIndex !== row.index) root.revealedIndex = -1
                      }
                      onPositionChanged: function(mouse) {
                        if (drag.active || Math.abs(mouse.x - pressX) > Style.space(5)) swiped = true
                      }
                      onReleased: function(mouse) {
                        if (!swiped) return
                        if (rowContent.x < -row.width * 0.6) {
                          // Swiped (nearly) all the way: remove now.
                          rowContent.x = -row.width
                          root.revealedIndex = -1
                          root.removeQueueItem(root.queueOffset + row.index)
                        } else if (rowContent.x < -root.revealWidth * 0.2) {
                          // Part way: stop with the Remove button showing.
                          rowContent.x = -root.revealWidth
                          root.revealedIndex = row.index
                        } else {
                          rowContent.x = 0
                          if (root.revealedIndex === row.index) root.revealedIndex = -1
                        }
                      }
                      onClicked: function(mouse) {
                        if (swiped) return
                        // Row with its Remove button showing: the button removes,
                        // anywhere else just closes it (never plays the song).
                        if (rowContent.x < 0) {
                          if (mouse.x > row.width - root.revealWidth) {
                            rowContent.x = -row.width
                            root.revealedIndex = -1
                            root.removeQueueItem(root.queueOffset + row.index)
                          } else {
                            rowContent.x = 0
                            root.revealedIndex = -1
                          }
                          return
                        }
                        if (mouse.button === Qt.RightButton) {
                          queueMenu.index = root.queueOffset + row.index
                          var p = row.mapToItem(queueMenu.parent, mouse.x, mouse.y)
                          queueMenu.x = Math.min(p.x, queueMenu.parent.width - queueMenu.width)
                          queueMenu.y = p.y
                          queueMenu.visible = true
                        } else {
                          root.playQueueItem(root.queueOffset + row.index)
                        }
                      }
                    }

                    // Grip: hold and drag up / down to move the song.
                    MouseArea {
                      id: gripMouse
                      anchors.right: parent.right
                      anchors.top: parent.top
                      anchors.bottom: parent.bottom
                      width: Style.space(34)
                      enabled: rowContent.x === 0 && !row.modelData.current
                      hoverEnabled: true
                      preventStealing: true
                      cursorShape: row.dragging ? Qt.ClosedHandCursor : Qt.OpenHandCursor
                      onPressed: function(mouse) {
                        var p = gripMouse.mapToItem(queueScroll, mouse.x, mouse.y)
                        root.dragViewY = p.y
                        root.dragPressY = p.y + queueScroll.contentY
                        root.dragFrom = row.index
                        root.dragTo = row.index
                      }
                      onPositionChanged: function(mouse) {
                        if (root.dragFrom !== row.index) return
                        root.dragViewY = gripMouse.mapToItem(queueScroll, mouse.x, mouse.y).y
                        root.updateDragTarget()
                      }
                      onReleased: {
                        var from = root.dragFrom
                        var to = root.dragTo
                        root.dragFrom = -1
                        root.dragTo = -1
                        if (from >= 0 && to >= 0 && to !== from)
                          root.moveQueueItem(root.queueOffset + from, root.queueOffset + to)
                      }
                      onCanceled: { root.dragFrom = -1; root.dragTo = -1 }
                    }
                  }
                }

                // "Show more": the next 20 songs.
                Rectangle {
                  visible: root.queueLeft > 0
                  width: queueColumn.width
                  height: Style.space(34)
                  radius: Style.cornerRadius
                  color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, moreMouse.containsMouse ? 0.12 : 0.06)
                  Text {
                    anchors.centerIn: parent
                    text: "•••  Show more (" + Math.min(root.queuePage, root.queueLeft)
                      + " of " + root.queueLeft + " left)"
                    color: root.fg
                    opacity: 0.8
                    font.family: root.font
                    font.pixelSize: Style.font.bodySmall
                  }
                  MouseArea {
                    id: moreMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.queueShown += root.queuePage
                  }
                }
              }
            }

            Item {
              id: queueBar
              anchors.right: parent.right
              anchors.top: parent.top
              anchors.bottom: parent.bottom
              width: Style.space(8)
              visible: queueScroll.scrollable

              readonly property real range: Math.max(1, queueScroll.contentHeight - queueScroll.height)
              readonly property real handleHeight: Math.max(Style.space(28), height * queueScroll.height / Math.max(1, queueScroll.contentHeight))

              // Track
              Rectangle {
                anchors.fill: parent
                radius: width / 2
                color: root.fg
                opacity: barMouse.containsMouse || barMouse.pressed ? 0.12 : 0.06
              }
              // Handle
              Rectangle {
                width: parent.width
                height: queueBar.handleHeight
                y: (queueBar.height - height) * Math.min(1, Math.max(0, queueScroll.contentY / queueBar.range))
                radius: width / 2
                color: root.fg
                opacity: barMouse.pressed ? 0.7 : (barMouse.containsMouse ? 0.5 : 0.3)
              }
              MouseArea {
                id: barMouse
                anchors.fill: parent
                anchors.leftMargin: -Style.space(4)  // a slightly wider hit area
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                preventStealing: true
                // Centre the handle on the pointer: click to jump, drag to scroll.
                function scrollTo(y) {
                  var track = queueBar.height - queueBar.handleHeight
                  var f = track > 0 ? (y - queueBar.handleHeight / 2) / track : 0
                  queueScroll.contentY = Math.min(1, Math.max(0, f)) * queueBar.range
                }
                onPressed: function(mouse) { scrollTo(mouse.y) }
                onPositionChanged: function(mouse) { if (pressed) scrollTo(mouse.y) }
              }
            }
          }
        }

        Text {
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          text: root.feedback
          visible: root.feedback !== ""
          color: root.fg
          opacity: 0.7
          font.family: root.font
          font.pixelSize: Style.font.caption
        }

        // Nothing open yet: one obvious way in.
        Button {
          visible: !root.hasMusic
          anchors.horizontalCenter: parent.horizontalCenter
          text: "Open YouTube Music"
          bordered: true
          foreground: root.fg
          fontFamily: root.font
          fontSize: Style.font.bodySmall
          onClicked: root.openApp()
        }
      }
    }
  }

  // Right-click menu for queue rows (lives above the player content).
  component QueueMenu: Rectangle {
    property int index: -1
    visible: false
    z: 100
    width: Style.space(180)
    height: menuColumn.implicitHeight + Style.space(8)
    radius: Style.cornerRadius
    color: Color.menu.background
    border.width: 1
    border.color: Color.menu.border

    Column {
      id: menuColumn
      anchors.fill: parent
      anchors.margins: Style.space(4)
      Repeater {
        model: [
          { label: "󰐊  Play now", action: "play" },
          { label: "󰆴  Remove from queue", action: "remove" }
        ]
        Rectangle {
          required property var modelData
          width: menuColumn.width
          height: Style.space(30)
          radius: Style.cornerRadius
          color: itemMouse.containsMouse ? Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.1) : "transparent"
          Text {
            anchors.left: parent.left
            anchors.leftMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            text: modelData.label
            color: root.fg
            font.family: root.font
            font.pixelSize: Style.font.bodySmall
          }
          MouseArea {
            id: itemMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
              var i = queueMenu.index
              queueMenu.visible = false
              if (modelData.action === "play") root.playQueueItem(i)
              else root.removeQueueItem(i)
            }
          }
        }
      }
    }
  }

  // Search / library results: cover, title, subtitle; click plays it.
  component ResultList: Item {
    id: resultList
    property var items: []
    property string listName: ""
    property real maxHeight: Style.space(300)
    height: Math.min(resultColumn.implicitHeight, maxHeight)
    visible: items.length > 0

    Flickable {
      id: resultScroll
      width: parent.width - (scrollable ? resultBar.width + Style.space(6) : 0)
      height: parent.height
      readonly property bool scrollable: contentHeight > height + 1
      contentHeight: resultColumn.implicitHeight
      clip: true
      boundsBehavior: Flickable.StopAtBounds
      interactive: scrollable

      Column {
        id: resultColumn
        width: resultScroll.width
        spacing: Style.space(2)

        Repeater {
          model: resultList.items
          Rectangle {
            id: result
            required property var modelData
            required property int index
            width: resultColumn.width
            height: Style.space(48)
            radius: Style.cornerRadius
            color: rowHover.hovered ? Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.07) : "transparent"
            opacity: result.modelData.hidden ? 0.45 : 1
            property string tip: ""   // label of the hovered action icon
            HoverHandler { id: rowHover }

            Rectangle {
              id: resultCover
              anchors.left: parent.left
              anchors.leftMargin: Style.space(6)
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(38)
              height: width
              radius: result.modelData.kind === "playlist" ? Math.max(3, Style.cornerRadius / 2) : width / 2 > 0 && result.modelData.subtitle.indexOf("Artist") === 0 ? width / 2 : Math.max(3, Style.cornerRadius / 2)
              color: Qt.darker(Color.menu.background, 1.3)
              clip: true
              Text {
                anchors.centerIn: parent
                visible: resultArt.status !== Image.Ready
                text: result.modelData.kind === "playlist" ? "󰲸" : "󰝚"
                color: root.fg
                opacity: 0.4
                font.family: root.font
                font.pixelSize: Style.font.body
              }
              Image {
                id: resultArt
                anchors.fill: parent
                source: result.modelData.art || ""
                sourceSize.width: 96
                sourceSize.height: 96
                fillMode: Image.PreserveAspectCrop
                asynchronous: true
              }
            }
            Column {
              anchors.left: resultCover.right
              anchors.leftMargin: Style.space(10)
              anchors.right: rowHover.hovered ? rowActions.left : parent.right
              anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(1)
              Marquee {
                width: parent.width
                text: result.modelData.title
                pixelSize: Style.font.bodySmall
                hovered: rowHover.hovered
              }
              Marquee {
                width: parent.width
                text: result.modelData.subtitle
                pixelSize: Style.font.caption
                textOpacity: 0.6
                hovered: rowHover.hovered
              }
            }
            MouseArea {
              id: resultMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              acceptedButtons: Qt.LeftButton | Qt.RightButton
              onClicked: function(mouse) {
                if (mouse.button === Qt.RightButton) {
                  resultMenu.list = resultList.listName
                  resultMenu.index = result.index
                  resultMenu.item = result.modelData
                  resultMenu.title = result.modelData.title
                  var p = result.mapToItem(resultMenu.parent, mouse.x, mouse.y)
                  resultMenu.x = Math.min(p.x, resultMenu.parent.width - resultMenu.width)
                  resultMenu.y = Math.min(p.y, resultMenu.parent.height - resultMenu.height)
                  resultMenu.visible = true
                } else {
                  root.rowAction(resultList.listName, result.index, result.modelData, "play")
                }
              }
            }

            // Hover: action icons on the right; hovering one names it.
            Row {
              id: rowActions
              anchors.right: parent.right
              anchors.rightMargin: Style.space(4)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)
              visible: rowHover.hovered
              Repeater {
                model: result.modelData.kind === "artist"
                  ? [{ action: "open", icon: "󰅂", tip: "Open artist" }]
                  : [
                  { action: "play", icon: "󰐊", tip: "Play now" },
                  { action: "next", icon: "󰒭", tip: "Play next" },
                  { action: "queue", icon: "󰐒", tip: "Add to queue" }
                ].concat(resultList.listName === "library"
                  ? [{ action: "hide", icon: result.modelData.hidden ? "󰈈" : "󰈉",
                       tip: result.modelData.hidden ? "Unhide" : "Hide from Library" }] : [])
                 .concat(result.modelData.kind === "playlist"
                  ? [{ action: "pin", icon: root.isPinned(result.modelData) ? "󰃀" : "󰃃",
                       tip: root.isPinned(result.modelData) ? "Unpin" : "Pin to Library" }] : [])
                Rectangle {
                  required property var modelData
                  width: Style.space(28)
                  height: width
                  radius: width / 2
                  color: actMouse.containsMouse ? Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.14) : "transparent"
                  Text {
                    anchors.centerIn: parent
                    text: modelData.icon
                    color: root.fg
                    font.family: root.font
                    font.pixelSize: Style.font.body
                  }
                  MouseArea {
                    id: actMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onEntered: result.tip = modelData.tip
                    onExited: if (result.tip === modelData.tip) result.tip = ""
                    onClicked: root.rowAction(resultList.listName, result.index, result.modelData, modelData.action)
                  }
                }
              }
            }
            // The hovered icon's name, as a small label just left of the icons.
            Rectangle {
              visible: rowHover.hovered && result.tip !== ""
              anchors.right: rowActions.left
              anchors.rightMargin: Style.space(4)
              anchors.verticalCenter: parent.verticalCenter
              width: tipText.implicitWidth + Style.space(12)
              height: tipText.implicitHeight + Style.space(6)
              radius: height / 2
              color: Color.menu.background
              border.width: 1
              border.color: Color.menu.border
              Text {
                id: tipText
                anchors.centerIn: parent
                text: result.tip
                color: root.fg
                font.family: root.font
                font.pixelSize: Style.font.caption
              }
            }
          }
        }
      }
    }

    // Scrollbar: drag the handle or click the track.
    Item {
      id: resultBar
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.bottom: parent.bottom
      width: Style.space(8)
      visible: resultScroll.scrollable
      readonly property real range: Math.max(1, resultScroll.contentHeight - resultScroll.height)
      readonly property real handleHeight: Math.max(Style.space(28), height * resultScroll.height / Math.max(1, resultScroll.contentHeight))
      Rectangle {
        anchors.fill: parent
        radius: width / 2
        color: root.fg
        opacity: resultBarMouse.containsMouse || resultBarMouse.pressed ? 0.12 : 0.06
      }
      Rectangle {
        width: parent.width
        height: resultBar.handleHeight
        y: (resultBar.height - height) * Math.min(1, Math.max(0, resultScroll.contentY / resultBar.range))
        radius: width / 2
        color: root.fg
        opacity: resultBarMouse.pressed ? 0.7 : (resultBarMouse.containsMouse ? 0.5 : 0.3)
      }
      MouseArea {
        id: resultBarMouse
        anchors.fill: parent
        anchors.leftMargin: -Style.space(4)
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        preventStealing: true
        function scrollTo(y) {
          var track = resultBar.height - resultBar.handleHeight
          var f = track > 0 ? (y - resultBar.handleHeight / 2) / track : 0
          resultScroll.contentY = Math.min(1, Math.max(0, f)) * resultBar.range
        }
        onPressed: function(mouse) { scrollTo(mouse.y) }
        onPositionChanged: function(mouse) { if (pressed) scrollTo(mouse.y) }
      }
    }
  }

  component ResultMenu: Rectangle {
    property string list: ""
    property var item: null
    property int index: -1
    property string title: ""
    visible: false
    z: 100
    width: Style.space(180)
    height: resultMenuColumn.implicitHeight + Style.space(8)
    radius: Style.cornerRadius
    color: Color.menu.background
    border.width: 1
    border.color: Color.menu.border

    Column {
      id: resultMenuColumn
      anchors.fill: parent
      anchors.margins: Style.space(4)
      Repeater {
        model: [
          { label: "󰐊  Play now", action: "play" },
          { label: "󰒭  Play next", action: "next" },
          { label: "󰐒  Add to queue", action: "queue" }
        ]
        Rectangle {
          required property var modelData
          width: resultMenuColumn.width
          height: Style.space(30)
          radius: Style.cornerRadius
          color: resultItemMouse.containsMouse ? Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.1) : "transparent"
          Text {
            anchors.left: parent.left
            anchors.leftMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            text: modelData.label
            color: root.fg
            font.family: root.font
            font.pixelSize: Style.font.bodySmall
          }
          MouseArea {
            id: resultItemMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
              resultMenu.visible = false
              root.rowAction(resultMenu.list, resultMenu.index, resultMenu.item, modelData.action)
            }
          }
        }
      }
    }
  }

  // A one-line row of filter chips: "All" + labels. Drag or use the scroll wheel
  // to move it sideways. picked(-1) = All.
  component ChipBar: Item {
    id: chipBar
    property var labels: []
    property int selected: -1
    signal picked(int index)
    height: chipBarRow.height

    Flickable {
      id: chipFlick
      anchors.fill: parent
      contentWidth: chipBarRow.width
      clip: true
      boundsBehavior: Flickable.StopAtBounds
      flickableDirection: Flickable.HorizontalFlick
      Row {
        id: chipBarRow
        spacing: Style.space(6)
        Repeater {
          model: ["All"].concat(chipBar.labels)
          Rectangle {
            required property var modelData
            required property int index
            readonly property bool on: index - 1 === chipBar.selected
            width: chipLabel.implicitWidth + Style.space(16)
            height: chipLabel.implicitHeight + Style.space(8)
            radius: height / 2
            color: on ? root.fg : Qt.rgba(root.fg.r, root.fg.g, root.fg.b, chipHover.containsMouse ? 0.16 : 0.08)
            Text {
              id: chipLabel
              anchors.centerIn: parent
              text: modelData
              color: parent.on ? Color.menu.background : root.fg
              font.family: root.font
              font.pixelSize: Style.font.caption
              font.bold: parent.on
            }
            MouseArea {
              id: chipHover
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: chipBar.picked(index - 1)
            }
          }
        }
      }
    }
    // Scroll wheel (up/down or sideways) moves the chips left / right; clicks pass through.
    MouseArea {
      anchors.fill: parent
      acceptedButtons: Qt.NoButton
      onWheel: function(wheel) {
        var d = wheel.angleDelta.x !== 0 ? wheel.angleDelta.x : wheel.angleDelta.y
        var maxX = Math.max(0, chipFlick.contentWidth - chipFlick.width)
        chipFlick.contentX = Math.max(0, Math.min(maxX, chipFlick.contentX - d * 0.6))
      }
    }
  }

  // One line of text that, when it doesn't fit, scrolls like a ticker in a
  // loop while hovered (the start comes round again after a gap); otherwise
  // it's cut off with "…". Same motion as the queue titles.
  component Marquee: Item {
    id: marquee
    property string text: ""
    property real pixelSize: Style.font.body
    property bool bold: false
    property real textOpacity: 1
    property bool hovered: false   // set by a parent row to scroll while the row is hovered
    readonly property real gap: Style.space(32)
    readonly property bool overflowing: marqueeText.implicitWidth > width
    readonly property bool scrolling: (marqueeHover.hovered || hovered) && overflowing
    height: marqueeText.implicitHeight
    clip: true
    HoverHandler { id: marqueeHover }
    Row {
      id: marqueeRow
      spacing: marquee.gap
      Text {
        id: marqueeText
        width: marquee.scrolling ? implicitWidth : marquee.width
        text: marquee.text
        elide: marquee.scrolling ? Text.ElideNone : Text.ElideRight
        color: root.fg
        opacity: marquee.textOpacity
        font.family: root.font
        font.pixelSize: marquee.pixelSize
        font.bold: marquee.bold
      }
      Text {
        visible: marquee.scrolling
        text: marquee.text
        color: root.fg
        opacity: marquee.textOpacity
        font: marqueeText.font
      }
    }
    SequentialAnimation {
      running: marquee.scrolling
      loops: Animation.Infinite
      onRunningChanged: if (!running) marqueeRow.x = 0
      PauseAnimation { duration: 700 }
      NumberAnimation {
        target: marqueeRow; property: "x"
        from: 0
        to: -(marqueeText.implicitWidth + marquee.gap)
        // ~20 px a second.
        duration: (marqueeText.implicitWidth + marquee.gap) * 50
        easing.type: Easing.Linear
      }
    }
  }

  component IconButton: Item {
    id: iconButton
    property string icon: ""
    property real size: Style.font.title
    signal clicked()

    width: Math.max(glyph.implicitWidth, size) + Style.space(12)
    height: width
    opacity: enabled ? 1 : 0.35

    Rectangle {
      anchors.fill: parent
      radius: width / 2
      color: root.fg
      opacity: mouse.containsMouse && iconButton.enabled ? 0.12 : 0
    }
    Text {
      id: glyph
      anchors.centerIn: parent
      text: iconButton.icon
      color: root.fg
      font.family: root.font
      font.pixelSize: iconButton.size
    }
    MouseArea {
      id: mouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: iconButton.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
      onClicked: if (iconButton.enabled) iconButton.clicked()
    }
  }
}
