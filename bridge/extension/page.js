// YouTube Music Player bridge, page side. Runs in the page's own JavaScript
// world so it can read the data YouTube Music keeps on each queue row (cover
// link, video id) even before the row has been scrolled into view and its
// image loaded. It only copies those two values onto the row as attributes
// (data-ytp-art / data-ytp-id) for content.js to read; it changes nothing else.
(() => {
  function findThumbs(obj, depth) {
    if (!obj || typeof obj !== "object" || depth > 5) return null
    if (Array.isArray(obj.thumbnails) && obj.thumbnails.length && obj.thumbnails[0].url) return obj.thumbnails
    for (const key of Object.keys(obj)) {
      const found = findThumbs(obj[key], depth + 1)
      if (found) return found
    }
    return null
  }

  function tag() {
    reportApi()
    reportVolume()
    const items = document.querySelectorAll("ytmusic-player-queue ytmusic-player-queue-item")
    for (const el of items) {
      const data = el.data || (el.__data && el.__data.data) || null
      if (!data) continue
      if (data.videoId && el.getAttribute("data-ytp-id") !== data.videoId) {
        el.setAttribute("data-ytp-id", data.videoId)
        el.removeAttribute("data-ytp-art")
      }
      if (!el.hasAttribute("data-ytp-art")) {
        const thumbs = findThumbs(data.thumbnail || data, 0)
        // Smallest one that's at least 60px wide is plenty for a 32px cover.
        const pick = thumbs && (thumbs.find((t) => (t.width || 0) >= 60) || thumbs[thumbs.length - 1])
        if (pick && /^https:\/\//.test(pick.url)) el.setAttribute("data-ytp-art", pick.url)
      }
    }
  }

  // Reordering: YouTube Music's queue element (#queue) has a dispatch() for its
  // own queue actions; MOVE_ITEM is what its drag-and-drop uses. content.js asks
  // for a move with a "ytp-bridge-move" event ({from, to} queue indexes).
  function queueEl() { return document.querySelector("ytmusic-player-queue#queue, #queue") }

  function reportApi() {
    const q = queueEl()
    document.documentElement.setAttribute("data-ytp-move",
      q && typeof q.dispatch === "function" ? "yes" : "no")
    document.documentElement.setAttribute("data-ytp-store", queueStore() ? "yes" : "no")
  }

  // Remove: the queue's own REMOVE_ITEM action (payload = queue index). No
  // menus or clicks, so nothing can start playing the song by accident.
  // Replace any copy left by an earlier injection (extension reload).
  if (window.__ytpRemoveHandler) document.removeEventListener("ytp-bridge-remove", window.__ytpRemoveHandler, true)
  window.__ytpRemoveHandler = (e) => {
      let detail = {}
      try { detail = JSON.parse(e.detail || "{}") } catch (err) { return }
      if (!Number.isInteger(detail.index) || detail.index < 0) return
      const q = queueEl()
      if (!q || typeof q.dispatch !== "function") return
      q.dispatch({ type: "REMOVE_ITEM", payload: detail.index })
    }
  document.addEventListener("ytp-bridge-remove", window.__ytpRemoveHandler, true)

  // Replace any copy left by an earlier injection (extension reload).
  if (window.__ytpMoveHandler) document.removeEventListener("ytp-bridge-move", window.__ytpMoveHandler, true)
  window.__ytpMoveHandler = (e) => {
      let detail = {}
      try { detail = JSON.parse(e.detail || "{}") } catch (err) { return }
      const from = detail.from, to = detail.to
      if (!Number.isInteger(from) || !Number.isInteger(to) || from === to) return
      const q = queueEl()
      if (!q || typeof q.dispatch !== "function") return
      q.dispatch({ type: "MOVE_ITEM", payload: { fromIndex: from, toIndex: to } })
    }
  document.addEventListener("ytp-bridge-move", window.__ytpMoveHandler, true)

  // ---- Volume: YouTube Music's own player volume (0-100, the page's slider),
  // so the bar's volume keys / slider don't touch other Chromium tabs.
  // Published as data-ytp-volume for content.js; set via "ytp-bridge-volume".
  function moviePlayer() {
    const p = document.querySelector("#movie_player")
    return p && typeof p.getVolume === "function" ? p : null
  }
  function reportVolume() {
    const p = moviePlayer()
    const v = p ? (p.isMuted() ? 0 : Math.round(p.getVolume())) : -1
    document.documentElement.setAttribute("data-ytp-volume", String(v))
  }
  // Replace any copies left by an earlier injection (extension reload).
  if (window.__ytpVolumeChangeHandler) document.removeEventListener("volumechange", window.__ytpVolumeChangeHandler, true)
  window.__ytpVolumeChangeHandler = () => setTimeout(reportVolume, 0)
  document.addEventListener("volumechange", window.__ytpVolumeChangeHandler, true)
  if (window.__ytpVolumeSetHandler) document.removeEventListener("ytp-bridge-volume", window.__ytpVolumeSetHandler, true)
  {
    window.__ytpVolumeSetHandler = (e) => {
      let detail = {}
      try { detail = JSON.parse(e.detail || "{}") } catch (err) { return }
      const to = detail.to
      if (!Number.isInteger(to) || to < 0 || to > 100) return
      const p = moviePlayer()
      if (!p) return
      p.setVolume(to)
      if (to > 0 && p.isMuted()) p.unMute()
      // Keep the page's own slider in step.
      const slider = document.querySelector("ytmusic-player-bar #volume-slider")
      if (slider) slider.value = to
      reportVolume()
    }
    document.addEventListener("ytp-bridge-volume", window.__ytpVolumeSetHandler, true)
  }

  // ---- Song time: YouTube Music reuses one <video> across songs, so its clock
  // keeps running from earlier tracks. The player's own getCurrentTime() /
  // getDuration() are per song; publish them for content.js twice a second.
  function songPlayer() {
    const p = document.querySelector("#movie_player")
    return p && typeof p.getCurrentTime === "function" ? p : null
  }
  function publishTime() {
    const p = songPlayer()
    if (!p) return
    const cur = Number(p.getCurrentTime()) || 0
    const dur = Number(p.getDuration()) || 0
    document.documentElement.setAttribute("data-ytp-time", cur.toFixed(2) + "," + dur.toFixed(2))
  }
  if (window.__ytpTimeTimer) clearInterval(window.__ytpTimeTimer)
  window.__ytpTimeTimer = setInterval(publishTime, 500)

  // Seek within the current song (the player's seekTo, not the shared <video>).
  if (window.__ytpSeekHandler) document.removeEventListener("ytp-bridge-seek", window.__ytpSeekHandler, true)
  window.__ytpSeekHandler = (e) => {
    let d = {}
    try { d = JSON.parse(e.detail || "{}") } catch (err) { return }
    const p = songPlayer()
    if (p && Number.isFinite(d.to) && d.to >= 0) { p.seekTo(d.to, true); publishTime() }
  }
  document.addEventListener("ytp-bridge-seek", window.__ytpSeekHandler, true)

  // ---- Search / library (for the bar player's Search and Library views).
  // Uses the same internal API requests YouTube Music's own page makes, with
  // your signed-in session, then starts playback the way an in-app link does.
  // Results go back to content.js as a "ytp-bridge-results" event; the last
  // list is kept here so the bar only sends back "play item N".
  const lists = { search: [], library: [], artist: [], artistsongs: [], speeddial: [] }
  let artistSongsBrowse = null  // the open artist's "Songs › Show all" page
  let artistSongsPlay = {}      // { play, shuffle } endpoints for that whole list
  let lastChips = []          // filter chips from the latest search ({label, params, selected})
  const chipParams = {}       // chip label -> search params, learned from every search
  let artistHeader = {}       // the open artist's Shuffle / Radio endpoints

  async function sha1Hex(text) {
    const buf = await crypto.subtle.digest("SHA-1", new TextEncoder().encode(text))
    return Array.from(new Uint8Array(buf)).map((b) => b.toString(16).padStart(2, "0")).join("")
  }

  function cookie(name) {
    const m = document.cookie.match(new RegExp("(?:^|; )" + name.replace(/[$.]/g, "\\$&") + "=([^;]*)"))
    return m ? decodeURIComponent(m[1]) : ""
  }

  async function api(endpoint, body) {
    const cfg = window.ytcfg
    const key = cfg.get("INNERTUBE_API_KEY")
    const headers = { "Content-Type": "application/json", "X-Origin": location.origin }
    const sapisid = cookie("SAPISID") || cookie("__Secure-3PAPISID")
    if (sapisid) {
      const ts = Math.floor(Date.now() / 1000)
      headers["Authorization"] = "SAPISIDHASH " + ts + "_" + await sha1Hex(ts + " " + sapisid + " " + location.origin)
      headers["X-Goog-AuthUser"] = String(cfg.get("SESSION_INDEX") || 0)
    }
    if (cfg.get("VISITOR_DATA")) headers["X-Goog-Visitor-Id"] = cfg.get("VISITOR_DATA")
    const res = await fetch("/youtubei/v1/" + endpoint + "?prettyPrint=false" + (key ? "&key=" + key : ""), {
      method: "POST", credentials: "include", headers,
      body: JSON.stringify(Object.assign({ context: cfg.get("INNERTUBE_CONTEXT") }, body))
    })
    if (!res.ok) throw new Error("HTTP " + res.status)
    return res.json()
  }

  const runsText = (t) => t ? (t.simpleText || (t.runs || []).map((r) => r.text).join("")) : ""

  function bestThumb(obj) {
    const t = findThumbs(obj, 0)
    if (!t) return ""
    const pick = t.find((x) => (x.width || 0) >= 90) || t[t.length - 1]
    return pick && /^https:\/\//.test(pick.url) ? pick.url : ""
  }

  // An album / playlist's own "Shuffle play" menu entry (its endpoint), if any.
  function findShuffle(renderer) {
    let found = null
    const walk = (n, depth) => {
      if (found || !n || typeof n !== "object" || depth > 8) return
      const nav = n.menuNavigationItemRenderer
      if (nav) {
        const icon = String(nav.icon?.iconType || "")
        if ((/SHUFFLE/.test(icon) || /shuffle/i.test(runsText(nav.text))) && nav.navigationEndpoint) {
          found = nav.navigationEndpoint
          return
        }
      }
      for (const k of Object.keys(n)) walk(n[k], depth + 1)
    }
    walk(renderer && renderer.menu, 0)
    return found
  }

  // Walk a response and pull out every playable list item / card, keeping the
  // title of the shelf it sits on ("Songs", "Community playlists", …).
  function collectItems(node, shelf, out) {
    if (!node || typeof node !== "object") return
    if (Array.isArray(node)) { node.forEach((n) => collectItems(n, shelf, out)); return }
    if (node.musicShelfRenderer) shelf = runsText(node.musicShelfRenderer.title) || shelf
    if (node.musicCardShelfRenderer) shelf = "Top result"
    if (node.musicCarouselShelfRenderer)
      shelf = runsText(node.musicCarouselShelfRenderer.header?.musicCarouselShelfBasicHeaderRenderer?.title) || shelf
    const li = node.musicResponsiveListItemRenderer
    const card = node.musicTwoRowItemRenderer
    const top = node.musicCardShelfRenderer
    if (li || card || top) {
      let title, subtitle, play, browse
      if (li) {
        const cols = (li.flexColumns || []).map((c) => runsText(c.musicResponsiveListItemFlexColumnRenderer?.text))
        title = cols[0] || ""
        subtitle = cols.slice(1).filter(Boolean).join(" • ")
        play = li.overlay?.musicItemThumbnailOverlayRenderer?.content?.musicPlayButtonRenderer?.playNavigationEndpoint
        if (!play && li.playlistItemData?.videoId) play = { watchEndpoint: { videoId: li.playlistItemData.videoId } }
        browse = li.navigationEndpoint
      } else if (card) {
        title = runsText(card.title)
        subtitle = runsText(card.subtitle)
        play = card.thumbnailOverlay?.musicItemThumbnailOverlayRenderer?.content?.musicPlayButtonRenderer?.playNavigationEndpoint
        browse = card.navigationEndpoint
      } else {
        title = runsText(top.title)
        subtitle = runsText(top.subtitle)
        play = top.thumbnailOverlay?.musicItemThumbnailOverlayRenderer?.content?.musicPlayButtonRenderer?.playNavigationEndpoint
        browse = top.title?.runs?.[0]?.navigationEndpoint
      }
      let endpoint = play || (browse && (browse.watchEndpoint || browse.watchPlaylistEndpoint) ? browse : null)
      const pageType = browse?.browseEndpoint?.browseEndpointContextSupportedConfigs?.browseEndpointContextMusicConfig?.pageType || ""
      const isArtist = !play && pageType === "MUSIC_PAGE_TYPE_ARTIST" && browse.browseEndpoint.browseId
      if (isArtist) endpoint = browse
      if (title && endpoint) {
        // A song played from an artist / album page also carries a playlistId;
        // anything with a videoId is still a song.
        // Album / playlist cards play their first track (a videoId), so their
        // own page type is what says "album".
        const isCollection = /MUSIC_PAGE_TYPE_(ALBUM|PLAYLIST|AUDIOBOOK)/.test(pageType)
        const kind = isArtist ? "artist"
          : isCollection ? "playlist"
          : endpoint.watchPlaylistEndpoint ? "playlist"
          : endpoint.watchEndpoint?.videoId ? "song"
          : endpoint.watchEndpoint?.playlistId ? "playlist" : "song"
        const shuffleEndpoint = kind === "playlist" ? findShuffle(li || card || top) : null
        const ids = idsOf(endpoint)
        out.push({ shelf: shelf || "", title, subtitle, art: bestThumb(li || card || top), kind, endpoint,
                   shuffleEndpoint, canShuffle: !!shuffleEndpoint,
                   playlistId: ids.playlistId, videoId: ids.videoId })
      }
      if (!top) return
    }
    for (const k of Object.keys(node)) collectItems(node[k], shelf, out)
  }

  function send(detail) {
    document.dispatchEvent(new CustomEvent("ytp-bridge-results", { detail: JSON.stringify(detail) }))
  }

  // The filter chips YouTube Music shows above search results (Songs, Albums,
  // Artists, …), each with the params for that filtered search.
  function findChips(data) {
    const chips = []
    const walk = (n, depth) => {
      if (!n || typeof n !== "object" || depth > 12) return
      const c = n.chipCloudChipRenderer
      if (c) {
        const label = runsText(c.text)
        const params = c.navigationEndpoint?.searchEndpoint?.params || ""
        if (label) chips.push({ label, params, selected: !!c.isSelected })
        return
      }
      for (const k of Object.keys(n)) walk(n[k], depth + 1)
    }
    walk(data.contents, 0)
    return chips
  }

  const strip = (items) => items.map(({ endpoint, shuffleEndpoint, ...rest }) => rest)

  function learnChips(data) {
    const chips = findChips(data)
    for (const c of chips) if (c.params && !c.selected) chipParams[c.label] = c.params
    if (chips.length) lastChips = chips
  }

  // chipLabel: a filter by name ("Songs", "Albums", …; "" = all). A chip's params
  // are learned from search responses; the first time a label is unknown, do a
  // plain search to learn it, then the filtered one.
  async function runSearch(q, chip, chipLabel) {
    try {
      let label = typeof chipLabel === "string" ? chipLabel : ""
      if (!label && Number.isInteger(chip) && chip >= 0 && lastChips[chip]) label = lastChips[chip].label
      if (label && !chipParams[label]) learnChips(await api("search", { query: q }))
      const body = { query: q }
      if (label && chipParams[label]) body.params = chipParams[label]
      const data = await api("search", body)
      learnChips(data)
      const items = []
      collectItems(data.contents, "", items)
      lists.search = items.slice(0, 60)
      send({ list: "search", query: q, chipLabel: label,
             chips: lastChips.map(({ label, selected }) => ({ label, selected })), items: strip(lists.search) })
    } catch (e) { send({ list: "search", query: q, chipLabel: chipLabel || "", error: String(e.message || e), items: [] }) }
  }

  // The open artist's full song list (their "Songs › Show all" page), following
  // continuation pages up to a few hundred songs.
  function continuationToken(obj) {
    let token = null
    const walk = (n, depth) => {
      if (token || !n || typeof n !== "object" || depth > 14) return
      token = n.nextContinuationData?.continuation || n.continuationCommand?.token || null
      if (token) return
      for (const k of Object.keys(n)) walk(n[k], depth + 1)
    }
    walk(obj, 0)
    return token
  }
  async function runArtistSongs() {
    if (!artistSongsBrowse) { send({ list: "artistsongs", error: "no song list for this artist", items: [] }); return }
    try {
      const body = { browseId: artistSongsBrowse.browseId }
      if (artistSongsBrowse.params) body.params = artistSongsBrowse.params
      let data = await api("browse", body)
      const items = []
      collectItems(data.contents, "", items)
      let token = continuationToken(data.contents)
      for (let page = 0; token && page < 5 && items.length < 500; page++) {
        data = await api("browse", { continuation: token })
        const before = items.length
        collectItems(data, "", items)
        if (items.length === before) break
        token = continuationToken(data.continuationContents || data.onResponseReceivedActions || data)
      }
      // Play-all / shuffle-all for the whole list: it's a playlist ("VL" + id);
      // prefer the page's own shuffle link, else YouTube Music's shuffle params.
      const pid = String(artistSongsBrowse.browseId || "").replace(/^VL/, "")
      let shuffleLink = null
      const findShuffleLink = (n, depth) => {
        if (shuffleLink || !n || typeof n !== "object" || depth > 14) return
        const w = n.watchPlaylistEndpoint
        if (w && w.params && (!pid || w.playlistId === pid)) { shuffleLink = n; return }
        for (const k of Object.keys(n)) if (k !== "contents") findShuffleLink(n[k], depth + 1)
      }
      findShuffleLink(data, 0)
      artistSongsPlay = pid ? {
        play: { watchPlaylistEndpoint: { playlistId: pid } },
        shuffle: shuffleLink || { watchPlaylistEndpoint: { playlistId: pid, params: "wAEB8gECKAE%3D" } }
      } : {}
      // Only the songs, and each once.
      const seen = new Set()
      lists.artistsongs = items.filter((x) => x.kind === "song" && x.videoId && !seen.has(x.videoId) && seen.add(x.videoId))
      send({ list: "artistsongs", items: strip(lists.artistsongs), canPlayAll: !!artistSongsPlay.play })
    } catch (e) { send({ list: "artistsongs", error: String(e.message || e), items: [] }) }
  }

  // An artist's page: top songs, albums, singles…, plus its Shuffle / Radio buttons.
  async function runArtist(item) {
    const browseId = item?.endpoint?.browseEndpoint?.browseId
    if (!browseId) return
    try {
      const data = await api("browse", { browseId })
      const items = []
      collectItems(data.contents, "", items)
      // No "Fans might also like" / similar artists on an artist's page.
      lists.artist = items.filter((x) => x.kind !== "artist").slice(0, 80)
      artistHeader = {}
      const walk = (n, depth) => {
        if (!n || typeof n !== "object" || depth > 10) return
        if (n.playButton?.buttonRenderer?.navigationEndpoint) artistHeader.shuffle = n.playButton.buttonRenderer.navigationEndpoint
        if (n.startRadioButton?.buttonRenderer?.navigationEndpoint) artistHeader.radio = n.startRadioButton.buttonRenderer.navigationEndpoint
        for (const k of Object.keys(n)) walk(n[k], depth + 1)
      }
      walk(data.header, 0)
      // The songs shelf's "Show all" link (its bottom button, or its title link).
      artistSongsBrowse = null
      lists.artistsongs = []
      const findSongs = (n, depth) => {
        if (artistSongsBrowse || !n || typeof n !== "object" || depth > 12) return
        const shelf = n.musicShelfRenderer
        if (shelf && /songs/i.test(runsText(shelf.title))) {
          artistSongsBrowse = shelf.bottomEndpoint?.browseEndpoint
            || shelf.title?.runs?.[0]?.navigationEndpoint?.browseEndpoint || null
          if (artistSongsBrowse) return
        }
        for (const k of Object.keys(n)) findSongs(n[k], depth + 1)
      }
      findSongs(data.contents, 0)
      const hdr = data.header && (data.header.musicImmersiveHeaderRenderer || data.header.musicVisualHeaderRenderer || {})
      send({ list: "artist", title: runsText(hdr.title) || item.title, art: item.art || "",
             hasShuffle: !!artistHeader.shuffle, hasRadio: !!artistHeader.radio,
             hasAllSongs: !!artistSongsBrowse, items: strip(lists.artist) })
    } catch (e) { send({ list: "artist", title: item.title, error: String(e.message || e), items: [] }) }
  }

  // Your library: playlists and saved albums (YouTube Music keeps them on two
  // pages); each item is tagged with which one it came from.
  async function runLibrary() {
    try {
      const pages = [["Playlists", "FEmusic_liked_playlists"], ["Albums", "FEmusic_liked_albums"]]
      const results = await Promise.all(pages.map(([, id]) => api("browse", { browseId: id }).catch(() => null)))
      const items = []
      pages.forEach(([label], i) => {
        if (!results[i]) return
        const found = []
        collectItems(results[i].contents, "", found)
        for (const x of found.slice(0, 150)) { x.shelf = label; items.push(x) }
      })
      if (!results[0] && !results[1]) throw new Error("couldn't load your library")
      lists.library = items
      send({ list: "library", items: strip(lists.library) })
    } catch (e) { send({ list: "library", error: String(e.message || e), items: [] }) }
  }

  // Speed dial: the quick-access shelf at the top of YouTube Music's home page.
  async function runSpeedDial() {
    try {
      const data = await api("browse", { browseId: "FEmusic_home" })
      // The phone app calls it "Speed dial"; on the web the same quick-access
      // shelf is "Listen again". Use Speed dial if YouTube sends one, else that.
      let shelf = null, shelfTitle = ""
      const findShelf = (re) => {
        const walk = (n, depth) => {
          if (shelf || !n || typeof n !== "object" || depth > 14) return
          for (const k of Object.keys(n)) {
            if (/ShelfRenderer$/.test(k) && n[k] && typeof n[k] === "object") {
              const r = n[k]
              const title = runsText(r.title) || runsText(r.header?.musicCarouselShelfBasicHeaderRenderer?.title)
                || runsText(r.header?.musicGridHeaderRenderer?.title) || ""
              if (re.test(title)) { shelf = r; shelfTitle = title; return }
            }
          }
          for (const k of Object.keys(n)) walk(n[k], depth + 1)
        }
        walk(data.contents, 0)
      }
      findShelf(/speed dial/i)
      if (!shelf) findShelf(/listen again/i)
      if (!shelf) {
        // Say which shelves the home page does have (helps if YouTube renames it).
        const titles = []
        const list = (n, depth) => {
          if (!n || typeof n !== "object" || depth > 14) return
          for (const k of Object.keys(n)) {
            if (/ShelfRenderer$/.test(k) && n[k] && typeof n[k] === "object") {
              const r = n[k]
              const t = runsText(r.title) || runsText(r.header?.musicCarouselShelfBasicHeaderRenderer?.title)
                || runsText(r.header?.musicGridHeaderRenderer?.title) || runsText(r.header?.musicCarouselShelfBasicHeaderRenderer?.strapline)
              titles.push(k.replace("Renderer", "") + ":" + (t || "?"))
            }
          }
          for (const k of Object.keys(n)) list(n[k], depth + 1)
        }
        list(data.contents, 0)
        // And where (if anywhere) the words "Speed dial" appear in the response.
        const paths = []
        const find = (n, path, depth) => {
          if (!n || typeof n !== "object" || depth > 30 || paths.length >= 5) return
          for (const k of Object.keys(n)) {
            const v = n[k]
            if (typeof v === "string" && /speed dial/i.test(v)) paths.push(path.concat(k).join("."))
            else if (v && typeof v === "object") find(v, path.concat(Array.isArray(n) ? "[" + k + "]" : k), depth + 1)
          }
        }
        find(data, [], 0)
        lists.speeddial = []
        send({ list: "speeddial", error: "no Speed dial or Listen again on your home page", shelves: titles.slice(0, 20), paths, items: [] })
        return
      }
      const items = []
      collectItems(shelf.contents || shelf.items || shelf, shelfTitle, items)
      lists.speeddial = items.slice(0, 60)
      send({ list: "speeddial", title: shelfTitle, items: strip(lists.speeddial) })
    } catch (e) { send({ list: "speeddial", error: String(e.message || e), items: [] }) }
  }

  // ---- Play next / add to queue (what YouTube Music's own item menus do):
  // ask for the item's queue entries (music/get_queue), then insert them with
  // the queue's ADD_ITEMS action, after the current song or at the end.
  function queueStore() {
    const q = queueEl()
    const st = q && q.queue && q.queue.store && q.queue.store.store
    return st && typeof st.getState === "function" ? st : null
  }

  function idsOf(endpoint) {
    const w = endpoint.watchEndpoint || {}
    const wp = endpoint.watchPlaylistEndpoint || {}
    return { videoId: w.videoId || "", playlistId: wp.playlistId || w.playlistId || "" }
  }

  async function enqueue(item, position) {
    const q = queueEl()
    const st = queueStore()
    if (!q || !st) throw new Error("queue not reachable")
    const { videoId, playlistId } = idsOf(item.endpoint)
    const ctx = st.getState().queue?.queueContextParams
    const ids = videoId && item.kind === "song" ? { videoIds: [videoId] }
      : playlistId ? { playlistId } : videoId ? { videoIds: [videoId] } : null
    if (!ids) throw new Error("nothing to queue")
    // The server is picky about which fields it wants; try the shapes YouTube
    // Music's own menus have been seen to send, plainest first.
    const attempts = [
      ids,
      Object.assign({}, ids, ctx ? { queueContextParams: ctx } : {}),
      Object.assign({}, ids, { queueInsertPosition: position }),
      Object.assign({}, ids, { queueInsertPosition: position }, ctx ? { queueContextParams: ctx } : {})
    ]
    let items = [], res = null, used = -1
    for (let a = 0; a < attempts.length && !items.length; a++) {
      res = await api("music/get_queue", attempts[a])
      items = (res.queueDatas || []).map((d) => d && d.content).filter(Boolean)
      if (items.length) used = a
    }
    window.__ytpQueueAttempt = used
    if (!items.length) {
      const keys = Object.keys(res || {}).join(",")
      throw new Error("no songs returned (response: " + keys + ")")
    }
    const state = st.getState().queue
    let index = state.items.length
    if (position === "INSERT_AFTER_CURRENT_VIDEO") {
      const cur = state.items.findIndex((it) =>
        (it.playlistPanelVideoRenderer || it.playlistPanelVideoWrapperRenderer?.primaryRenderer?.playlistPanelVideoRenderer)?.selected)
      index = cur >= 0 ? cur + 1 : 0
    }
    q.dispatch({ type: "ADD_ITEMS", payload: {
      nextQueueItemId: state.nextQueueItemId, index, items, shuffleEnabled: false, shouldAssignIds: true } })
    return items.length
  }

  // Play now / play next / add to queue for one result or pinned item.
  function runPick(item, d) {
    if (d.action === "next" || d.action === "queue") {
      const pos = d.action === "next" ? "INSERT_AFTER_CURRENT_VIDEO" : "INSERT_AT_END"
      enqueue(item, pos)
        .then((n) => send({ list: "added", action: d.action, title: item.title, count: n, attempt: window.__ytpQueueAttempt }))
        .catch((err) => send({ list: "added", action: d.action, title: item.title, error: String(err.message || err) }))
    } else {
      // Shuffle is on: start albums / playlists with their own "Shuffle play".
      playEndpoint(d.shuffle && item.shuffleEndpoint ? item.shuffleEndpoint : item.endpoint)
    }
  }

  // ---- Current song helpers: radio, save to playlist, lyrics.
  function currentVideoId() {
    const p = songPlayer()
    const v = p && typeof p.getVideoData === "function" ? p.getVideoData() : null
    return (v && v.video_id) || ""
  }

  // Start radio: YouTube Music's own "Start radio" playlist for the song.
  function startRadio() {
    const videoId = currentVideoId()
    if (!videoId) return
    playEndpoint({ watchEndpoint: { videoId, playlistId: "RDAMVM" + videoId, params: "wAEB" } })
  }

  // Your playlists the current song can be saved to (and whether it's in them).
  async function saveTargets() {
    const videoId = currentVideoId()
    try {
      if (!videoId) throw new Error("nothing playing")
      const data = await api("playlist/get_add_to_playlist", { videoIds: [videoId] })
      const out = []
      const walk = (n, depth) => {
        if (!n || typeof n !== "object" || depth > 12) return
        const o = n.playlistAddToOptionRenderer
        if (o && o.playlistId) {
          out.push({ playlistId: o.playlistId, title: runsText(o.title), contains: o.containsSelectedVideos === "ALL" })
          return
        }
        for (const k of Object.keys(n)) walk(n[k], depth + 1)
      }
      walk(data, 0)
      send({ list: "saveto", videoId, items: out })
    } catch (e) { send({ list: "saveto", error: String(e.message || e), items: [] }) }
  }

  async function saveTo(playlistId, title) {
    const videoId = currentVideoId()
    try {
      if (!videoId) throw new Error("nothing playing")
      await api("browse/edit_playlist", { playlistId, actions: [
        { action: "ACTION_ADD_VIDEO", addedVideoId: videoId, dedupeOption: "DEDUPE_OPTION_SKIP" }] })
      send({ list: "saved", playlistId, title: title || "" })
    } catch (e) { send({ list: "saved", playlistId, title: title || "", error: String(e.message || e) }) }
  }

  // Lyrics: the song's "Lyrics" tab (from the watch-next data), then its text,
  // shown in the bar player the way YouTube Music's own Lyrics tab shows it.
  async function lyrics() {
    const videoId = currentVideoId()
    try {
      if (!videoId) throw new Error("nothing playing")
      const next = await api("next", { videoId })
      let browseId = ""
      const walk = (n, depth) => {
        if (browseId || !n || typeof n !== "object" || depth > 16) return
        const id = n.browseEndpoint?.browseId
        if (typeof id === "string" && id.startsWith("MPLY")) { browseId = id; return }
        for (const k of Object.keys(n)) walk(n[k], depth + 1)
      }
      walk(next, 0)
      if (!browseId) { send({ list: "lyrics", videoId, text: "", note: "No lyrics for this song." }); return }
      const data = await api("browse", { browseId })
      let text = "", source = ""
      const find = (n, depth) => {
        if (text || !n || typeof n !== "object" || depth > 16) return
        const shelf = n.musicDescriptionShelfRenderer
        if (shelf) { text = runsText(shelf.description); source = runsText(shelf.footer); return }
        for (const k of Object.keys(n)) find(n[k], depth + 1)
      }
      find(data, 0)
      send({ list: "lyrics", videoId, text, source, note: text ? "" : "No lyrics for this song." })
    } catch (e) { send({ list: "lyrics", videoId, text: "", error: String(e.message || e) }) }
  }

  // Start playback the way an in-app link does (no page reload).
  function playEndpoint(endpoint) {
    const app = document.querySelector("ytmusic-app")
    if (!app || !endpoint) return
    app.dispatchEvent(new CustomEvent("yt-navigate", { bubbles: true, composed: true, detail: { endpoint } }))
  }

  // Replace any copy left by an earlier injection (extension reload).
  if (window.__ytpApiHandler) document.removeEventListener("ytp-bridge-api", window.__ytpApiHandler, true)
  window.__ytpApiHandler = (e) => {
      let d = {}
      try { d = JSON.parse(e.detail || "{}") } catch (err) { return }
      if (d.op === "search" && typeof d.q === "string" && d.q.trim()) runSearch(d.q.trim().slice(0, 200), d.chip, d.chipLabel)
      else if (d.op === "artist" && lists[d.list] && Number.isInteger(d.index)) runArtist(lists[d.list][d.index])
      else if (d.op === "artistsongs") runArtistSongs()
      else if (d.op === "artistsongsplay" && (d.mode === "play" || d.mode === "shuffle")) {
        if (artistSongsPlay[d.mode]) playEndpoint(artistSongsPlay[d.mode])
      }
      else if (d.op === "artistplay" && (d.mode === "shuffle" || d.mode === "radio")) {
        if (artistHeader[d.mode]) playEndpoint(artistHeader[d.mode])
      }
      else if (d.op === "library") runLibrary()
      else if (d.op === "speeddial") runSpeedDial()
      else if (d.op === "radio") startRadio()
      else if (d.op === "lyrics") lyrics()
      else if (d.op === "saveto") saveTargets()
      else if (d.op === "saveadd" && typeof d.playlistId === "string" && /^[\w-]{2,80}$/.test(d.playlistId)) saveTo(d.playlistId, d.title)
      else if (d.op === "pickid" && (d.playlistId || d.videoId)) {
        // Pinned item: reuse the full result if it's in a current list, else
        // build the endpoints from its id ("wAEB8gECKAE%3D" = YouTube Music's shuffle-play params).
        const all = lists.search.concat(lists.library)
        let item = all.find((x) => (d.playlistId && x.playlistId === d.playlistId) || (!d.playlistId && d.videoId && x.videoId === d.videoId))
        if (!item) {
          item = d.playlistId
            ? { title: d.title || "", kind: "playlist", endpoint: { watchPlaylistEndpoint: { playlistId: d.playlistId } },
                shuffleEndpoint: { watchPlaylistEndpoint: { playlistId: d.playlistId, params: "wAEB8gECKAE%3D" } } }
            : { title: d.title || "", kind: "song", endpoint: { watchEndpoint: { videoId: d.videoId } }, shuffleEndpoint: null }
        }
        runPick(item, d)
      }
      else if (d.op === "pick" && lists[d.list] && Number.isInteger(d.index)) {
        const item = lists[d.list][d.index]
        if (!item) return
        runPick(item, d)
      }
    }
  document.addEventListener("ytp-bridge-api", window.__ytpApiHandler, true)

  // After a self-reload this script is injected again; stop the old copy's timer.
  if (window.__ytpPageTimer) clearInterval(window.__ytpPageTimer)
  window.__ytpPageTimer = setInterval(tag, 1000)
  tag()
})()
