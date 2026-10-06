// YouTube Music Player bridge: runs on music.youtube.com. Reports the current
// song's like status, shuffle status and the queue to the bar, and carries out
// the bar's commands by clicking YouTube Music's own buttons.
(() => {
  const $ = (root, sel) => root ? root.querySelector(sel) : null
  const text = (el) => el ? (el.getAttribute("title") || el.textContent || "").trim() : ""

  function playerBar() { return document.querySelector("ytmusic-player-bar") }

  function likeRenderer() { return $(playerBar(), "ytmusic-like-button-renderer") }

  function likeStatus() {
    const r = likeRenderer()
    if (!r) return null
    const attr = r.getAttribute("like-status")
    if (attr) return attr
    // Fallback: read the pressed state of the buttons.
    const like = $(r, "#button-shape-like button, .like button, button.like")
    const dislike = $(r, "#button-shape-dislike button, .dislike button, button.dislike")
    if (like && like.getAttribute("aria-pressed") === "true") return "LIKE"
    if (dislike && dislike.getAttribute("aria-pressed") === "true") return "DISLIKE"
    return "INDIFFERENT"
  }

  function shuffleButton() { return $(playerBar(), ".shuffle, [aria-label*='huffle']") }

  // true / false when YouTube Music exposes it, null when it doesn't.
  function shuffleOn() {
    const bar = playerBar()
    if (!bar) return null
    if (bar.hasAttribute("shuffle-on")) return true
    const b = shuffleButton()
    if (!b) return null
    const pressed = b.getAttribute("aria-pressed") || ($(b, "button") || b).getAttribute("aria-pressed")
    if (pressed === "true") return true
    if (pressed === "false") return false
    // YouTube Music marks the player bar "shuffle-on" only while shuffle is on.
    return bar.hasAttribute("shuffle-on")
  }

  // The "Up next" queue; skip the alternate (song/video) counterpart entries.
  function queueItems() {
    const all = document.querySelectorAll("ytmusic-player-queue ytmusic-player-queue-item")
    return Array.from(all).filter((el) => !el.closest("#counterpart-renderer"))
  }

  // Cover thumbnail: the loaded <img>, else the link page.js read from the
  // row's data (rows YouTube Music hasn't scrolled to have no image yet).
  function coverOf(item) {
    const img = $(item, "yt-img-shadow img, img#img")
    const src = img ? (img.getAttribute("src") || "") : ""
    if (/^https:\/\//.test(src)) return src
    return item.getAttribute("data-ytp-art") || ""
  }

  function describe(item) {
    const state = item.getAttribute("play-button-state") || ""
    return {
      id: item.getAttribute("data-ytp-id") || "",
      art: coverOf(item),
      title: text($(item, ".song-title")),
      artist: text($(item, ".byline")),
      duration: text($(item, ".duration")),
      current: item.hasAttribute("selected") || state === "playing" || state === "paused"
    }
  }

  // ---- Health check: does the page still have every piece this bridge reads
  // or clicks? YouTube can change its page at any time. Checks that need a
  // song loaded are skipped until one is. Result goes to the bar as
  // state.health = { checked, failed: [names] }.
  function healthCheck() {
    const bar = playerBar()
    const failed = []
    if (!bar) {
      failed.push("player bar")
      return { checked: true, failed }
    }
    const songLoaded = text($(bar, ".title")) !== ""
    if (!songLoaded) return { checked: false, failed }
    const r = likeRenderer()
    if (!r) failed.push("like button")
    else if (!r.getAttribute("like-status")) failed.push("like status")
    if (!shuffleButton()) failed.push("shuffle button")
    if (!document.querySelector("ytmusic-player-queue")) failed.push("queue")
    const items = queueItems()
    if (items.length > 0) {
      const first = items[0]
      if (!text($(first, ".song-title"))) failed.push("queue song titles")
      if (!text($(first, ".byline"))) failed.push("queue artists")
      if (!$(first, "ytmusic-menu-renderer button")) failed.push("queue ⋮ menu (remove)")
      // page.js tags rows within a second or two of them appearing.
      if (!items.some((el) => el.hasAttribute("data-ytp-id"))) failed.push("queue track ids / covers")
    }
    if (document.documentElement.getAttribute("data-ytp-move") === "no") failed.push("reorder (MOVE_ITEM)")
    return { checked: true, failed }
  }

  // Re-checked every 30 s (cheap), so a change shows up soon after a page update.
  // The first check waits 5 s so page.js has had time to tag the queue.
  const startedAt = Date.now()
  let health = { checked: false, failed: [] }
  let healthAt = 0
  function currentHealth() {
    const now = Date.now()
    if (now - startedAt < 5000) return health
    if (!health.checked || now - healthAt > 30000) {
      health = healthCheck()
      healthAt = now
    }
    return health
  }

  // YouTube Music plays through a <video> element (audio-only for songs).
  // The page can hold more than one <video> (e.g. a preloaded or hidden one),
  // so prefer YouTube Music's main player, then whichever one is playing.
  function media() {
    const main = document.querySelector("#movie_player video.html5-main-video, #movie_player video")
    if (main) return main
    const all = Array.from(document.querySelectorAll("video"))
    return all.find((v) => !v.paused && !v.ended) || all.find((v) => v.currentSrc) || all[0] || null
  }
  function isPlaying() { const v = media(); return !!(v && !v.paused && !v.ended) }

  // Tell the extension when this tab starts playing, so it can pause the
  // others. Media events don't bubble; listening in the capture phase on the
  // document catches them even if YouTube swaps the <video> element.
  // Replace any copy left by an earlier injection (extension reload).
  if (window.__ytpPlayHandler) document.removeEventListener("play", window.__ytpPlayHandler, true)
  window.__ytpPlayHandler = () => {
      try { chrome.runtime.sendMessage({ type: "playing" }) } catch (e) {}
    }
  document.addEventListener("play", window.__ytpPlayHandler, true)

  // Cover of the song now playing: the player bar's image, else the current
  // queue row's cover.
  function nowCover(bar, queue) {
    const img = $(bar, "img.image, .thumbnail-image-wrapper img, .middle-controls img, img#img")
    const src = img ? (img.getAttribute("src") || "") : ""
    if (/^https:\/\//.test(src)) return src
    const cur = queue.find((q) => q.current)
    return cur ? cur.art : ""
  }

  // Search / library results from page.js → the bar (via background + host).
  // Replace any copy left by an earlier injection (extension reload).
  if (window.__ytpResultsHandler) document.removeEventListener("ytp-bridge-results", window.__ytpResultsHandler, true)
  window.__ytpResultsHandler = (e) => {
      let data = null
      try { data = JSON.parse(e.detail || "null") } catch (err) { return }
      try { chrome.runtime.sendMessage({ type: "results", data }) } catch (err) {}
    }
  document.addEventListener("ytp-bridge-results", window.__ytpResultsHandler, true)
  const apiCall = (detail) =>
    document.dispatchEvent(new CustomEvent("ytp-bridge-api", { detail: JSON.stringify(detail) }))

  function songTime() {
    const a = (document.documentElement.getAttribute("data-ytp-time") || "").split(",")
    if (a.length === 2 && a[1] !== "") return { cur: Math.floor(Number(a[0]) || 0), dur: Math.round(Number(a[1]) || 0) }
    const v = media()
    return { cur: v && isFinite(v.currentTime) ? Math.floor(v.currentTime) : 0,
             dur: v && isFinite(v.duration) ? Math.round(v.duration) : 0 }
  }

  // "3:21" / "1:02:03" → seconds (0 if it isn't a time).
  function parseDuration(text) {
    const parts = String(text || "").trim().split(":").map(Number)
    if (parts.length < 2 || parts.some((n) => !Number.isFinite(n))) return 0
    return parts.reduce((total, n) => total * 60 + n, 0)
  }

  function collect() {
    const bar = playerBar()
    const v = media()
    const queue = queueItems().map(describe)
    const time = songTime()
    return {
      health: currentHealth(),
      connected: true,
      playing: isPlaying(),
      // Whole seconds, so the state only changes (and is sent) once a second.
      // From the player's per-song clock (page.js); the shared <video>'s own
      // time runs on across songs, so it's only a last resort.
      position: time.cur,
      // Right after a song starts the player only reports what it has loaded
      // so far (~30 s, growing), so use the song's length from its queue entry.
      duration: parseDuration((queue.find((q) => q.current) || {}).duration) || time.dur,
      art: nowCover(bar, queue),
      title: text($(bar, ".title")),
      artist: text($(bar, ".byline")),
      like: likeStatus(),
      shuffle: shuffleOn(),
      // "NONE" | "ALL" | "ONE" (the player bar's own repeat-mode marker).
      repeat: (playerBar() && playerBar().getAttribute("repeat-mode")) || "",
      canMove: document.documentElement.getAttribute("data-ytp-move") === "yes",
      canEnqueue: document.documentElement.getAttribute("data-ytp-store") === "yes",
      // YouTube Music's own volume 0-100 (from page.js); -1 if unknown.
      volume: Number(document.documentElement.getAttribute("data-ytp-volume") || -1),
      queue
    }
  }

  let last = ""
  let lastSent = 0
  function report() {
    const state = collect()
    const json = JSON.stringify(state)
    const now = Date.now()
    // Send on change, plus a heartbeat so the bar knows the bridge is alive.
    if (json === last && now - lastSent < 4000) return
    last = json
    lastSent = now
    try { chrome.runtime.sendMessage({ type: "state", state }) } catch (e) {}
  }

  const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

  async function waitFor(fn, ms = 1500) {
    const end = Date.now() + ms
    while (Date.now() < end) {
      const v = fn()
      if (v) return v
      await sleep(50)
    }
    return null
  }

  // Find a queue item by index, double-checking the title the bar showed.
  function itemAt(index, title, id) {
    const items = queueItems()
    if (id) {
      const byId = items.find((el) => el.getAttribute("data-ytp-id") === id)
      if (byId) return byId
    }
    const item = items[index]
    if (!item) return null
    if (title && describe(item).title !== title) {
      return items.find((el) => describe(el).title === title) || null
    }
    return item
  }

  // A menu popup that is actually open on screen right now.
  function openPopup() {
    const dropdowns = document.querySelectorAll("tp-yt-iron-dropdown")
    for (const d of dropdowns) {
      if (d.getAttribute("aria-hidden") === "true") continue
      if (getComputedStyle(d).display === "none") continue
      const popup = $(d, "ytmusic-menu-popup-renderer")
      if (popup) return popup
    }
    return null
  }

  function closeMenus() {
    document.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", keyCode: 27, bubbles: true }))
  }

  async function removeItem(item) {
    // The real <button> inside the row's "⋮" menu (not the renderer around it).
    const menuButton = $(item, "ytmusic-menu-renderer yt-button-shape button, ytmusic-menu-renderer button")
    if (!menuButton) return false
    // Close any menu left open so we never act on another song's stale menu.
    if (openPopup()) { closeMenus(); await waitFor(() => !openPopup(), 600) }
    menuButton.click()
    const popup = await waitFor(openPopup)
    if (!popup) return false
    const entry = Array.from(popup.querySelectorAll(
      "ytmusic-menu-service-item-renderer, ytmusic-menu-navigation-item-renderer, [role='menuitem']"))
      .find((el) => /remove from queue/i.test(el.textContent || ""))
    if (!entry) { closeMenus(); return false }
    ($(entry, "tp-yt-paper-item, a") || entry).click()
    return true
  }

  // Remove via the queue's own REMOVE_ITEM (page.js); if the song is still
  // there a second later, fall back to its "⋮ > Remove from queue" menu.
  async function removeById(item) {
    const id = item.getAttribute("data-ytp-id")
    const index = queueItems().indexOf(item)
    if (index < 0) return
    document.dispatchEvent(new CustomEvent("ytp-bridge-remove", { detail: JSON.stringify({ index }) }))
    if (!id) return
    const gone = await waitFor(() => !queueItems().some((el) => el.getAttribute("data-ytp-id") === id), 1000)
    if (!gone) {
      const still = queueItems().find((el) => el.getAttribute("data-ytp-id") === id)
      if (still) await removeItem(still)
    }
  }

  function playItem(item) {
    const play = $(item, "ytmusic-play-button-renderer, .song-info")
    ;(play || item).click()
  }

  function clickLike(kind) {
    const r = likeRenderer()
    if (!r) return
    const sel = kind === "like"
      ? "#button-shape-like button, .like button, button.like, .like"
      : "#button-shape-dislike button, .dislike button, button.dislike, .dislike"
    const b = $(r, sel)
    if (b) b.click()
  }

  function clickShuffle() {
    const b = shuffleButton()
    if (b) ($(b, "button") || b).click()
  }

  // Debugging aid for the bar side: trimmed markup of the parts we read.
  function inspect() {
    const trim = (el) => el ? el.outerHTML.slice(0, 6000) : null
    const items = queueItems()
    try {
      chrome.runtime.sendMessage({ type: "inspect", data: {
        playerBar: trim(playerBar()),
        likeRenderer: trim(likeRenderer()),
        shuffleButton: trim(shuffleButton()),
        queueCount: items.length,
        firstQueueItem: trim(items[0]),
        queueRoot: trim(document.querySelector("ytmusic-player-queue")),
        // Where the page shows a "Speed dial" heading (if the Home tab is loaded).
        speedDial: (() => {
          const hit = Array.from(document.querySelectorAll("yt-formatted-string, h2, .title"))
            .find((el) => /^\s*speed dial\s*$/i.test(el.textContent || ""))
          if (!hit) return { found: false, url: location.pathname }
          let shelf = hit
          for (let i = 0; i < 12 && shelf.parentElement; i++) {
            shelf = shelf.parentElement
            if (/shelf|section/i.test(shelf.tagName)) break
          }
          return { found: true, url: location.pathname, shelfTag: shelf.tagName.toLowerCase(),
                   shelfStart: shelf.outerHTML.slice(0, 1500) }
        })()
      } })
    } catch (e) {}
  }

  chrome.runtime.onMessage.addListener((msg) => {
    if (!msg || !msg.cmd) return
    // ("play" with an index is "play this queue song"; resuming is "resume".)
    if (msg.cmd === "pause" || msg.cmd === "resume" || msg.cmd === "toggle") {
      // pause also comes from another YouTube Music tab / other audio starting.
      const v = media()
      if (!v) return
      if (msg.cmd === "pause" || (msg.cmd === "toggle" && !v.paused)) { if (!v.paused) v.pause() }
      else if (v.paused) v.play().catch(() => {})
      setTimeout(report, 200)
      return
    }
    if (msg.cmd === "volume") {
      document.dispatchEvent(new CustomEvent("ytp-bridge-volume", { detail: JSON.stringify({ to: msg.to }) }))
      setTimeout(report, 30)
      return
    }
    if (msg.cmd === "next" || msg.cmd === "previous") {
      const b = $(playerBar(), msg.cmd === "next" ? ".next-button" : ".previous-button")
      if (b) ($(b, "button") || b).click()
      setTimeout(report, 400)
      return
    }
    if (msg.cmd === "seek") {
      if (Number.isFinite(msg.to))
        document.dispatchEvent(new CustomEvent("ytp-bridge-seek", { detail: JSON.stringify({ to: Math.max(0, msg.to) }) }))
      setTimeout(report, 300)
      return
    }
    if (msg.cmd === "search") {
      apiCall({ op: "search", q: msg.q, chip: Number.isInteger(msg.chip) ? msg.chip : -1, chipLabel: msg.chipLabel || "" })
      return
    }
    if (msg.cmd === "artist") { apiCall({ op: "artist", list: msg.list, index: msg.index }); return }
    if (msg.cmd === "artistsongs") { apiCall({ op: "artistsongs" }); return }
    if (msg.cmd === "artistsongsplay") { apiCall({ op: "artistsongsplay", mode: msg.mode }); setTimeout(report, 800); return }
    if (msg.cmd === "artistplay") { apiCall({ op: "artistplay", mode: msg.mode }); setTimeout(report, 800); return }
    if (msg.cmd === "library") { apiCall({ op: "library" }); return }
    if (msg.cmd === "repeat") {
      // The repeat button cycles off → all → one.
      const b = $(playerBar(), ".repeat, [aria-label*='epeat']")
      if (b) ($(b, "button") || b).click()
      setTimeout(report, 300)
      return
    }
    if (msg.cmd === "radio") { apiCall({ op: "radio" }); setTimeout(report, 800); return }
    if (msg.cmd === "lyrics") { apiCall({ op: "lyrics" }); return }
    if (msg.cmd === "saveto") { apiCall({ op: "saveto" }); return }
    if (msg.cmd === "saveadd") { apiCall({ op: "saveadd", playlistId: msg.playlistId, title: msg.title || "" }); return }
    if (msg.cmd === "speeddial") { apiCall({ op: "speeddial" }); return }
    if (msg.cmd === "pickid") {
      apiCall({ op: "pickid", playlistId: msg.playlistId || "", videoId: msg.videoId || "", title: msg.title || "",
                action: msg.action || "play", shuffle: shuffleOn() === true })
      setTimeout(report, 800)
      return
    }
    if (msg.cmd === "pick") {
      // Pass along whether YouTube Music's shuffle is on, so albums / playlists start shuffled.
      apiCall({ op: "pick", list: msg.list, index: msg.index, action: msg.action || "play", shuffle: shuffleOn() === true })
      setTimeout(report, 800)
      return
    }
    if (msg.cmd === "like" || msg.cmd === "dislike") clickLike(msg.cmd)
    else if (msg.cmd === "shuffle") clickShuffle()
    else if (msg.cmd === "inspect") inspect()
    else if (msg.cmd === "move") {
      // Index of the song being moved, re-found by id in case the queue shifted.
      const items = queueItems()
      let from = msg.index
      if (msg.id) {
        const found = items.findIndex((el) => el.getAttribute("data-ytp-id") === msg.id)
        if (found >= 0) from = found
      }
      if (from >= 0 && from < items.length && Number.isInteger(msg.to) && msg.to >= 0 && msg.to < items.length)
        document.dispatchEvent(new CustomEvent("ytp-bridge-move", { detail: JSON.stringify({ from, to: msg.to }) }))
    }
    else if (msg.cmd === "play" || msg.cmd === "remove") {
      const item = itemAt(msg.index, msg.title, msg.id)
      if (!item) return
      if (msg.cmd === "play") playItem(item)
      else removeById(item)
    }
    setTimeout(report, 300)
  })

  // After a self-reload this script is injected again; stop the old copy's timer.
  if (window.__ytpBridgeTimer) clearInterval(window.__ytpBridgeTimer)
  window.__ytpBridgeTimer = setInterval(report, 1000)
  report()
})()
