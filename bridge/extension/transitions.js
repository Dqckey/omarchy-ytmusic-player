// YouTube Music Player bridge: song transitions. Runs in the page's own
// JavaScript world (needs the player and queue objects, like page.js).
//
// Modes (from the bar's settings, settings.json "music.transition", sent here by
// host.py → background.js → content.js as a "ytp-bridge-transition" event):
//   off        nothing is touched
//   fade       the song fades out over its last `out` seconds; after an automatic
//              song change the next one fades in over its first `in` seconds
//   crossfade  the same fades, but the next song starts while this one fades out:
//              it plays in a hidden YouTube player (an embed) until YouTube Music
//              reaches it, then the real player jumps to the same spot and takes over.
//
// Fades go through a Web Audio gain node on YouTube Music's own <video>, so
// YouTube Music's volume (and the bar's volume slider) is never changed.
// Anything unexpected (embed blocked, ad, slow load, pause, seek, a different
// next song) falls back to a plain fade instead.
(() => {
  const TICK_MS = 100
  const PRELOAD = 12   // load the hidden player this many seconds before the fade starts
  const SEEK_LEAD = 0.5 // the real player is first sent this far ahead of the embed (seek takes time)
  const END_EARLY = 1   // YouTube Music ends songs about this much before their listed length

  // Replace any copy left by an earlier injection (extension reload).
  if (window.__ytpXfTimer) clearInterval(window.__ytpXfTimer)
  if (window.__ytpXfCfgHandler) document.removeEventListener("ytp-bridge-transition", window.__ytpXfCfgHandler, true)
  if (window.__ytpXfMsgHandler) window.removeEventListener("message", window.__ytpXfMsgHandler)
  // A reload mid-crossfade: let the old copy put the hidden player's volume back first.
  if (window.__ytpXfDrop) { try { window.__ytpXfDrop() } catch (e) {} }
  if (!window.__ytpXfDrop) document.querySelectorAll("iframe[data-ytp-xf]").forEach((f) => f.remove())

  let cfg = window.__ytpXfCfg || { mode: "off", out: 5, in: 3 }

  // Kept on window so a re-injection reuses the same audio graph: a <video> can
  // only ever be connected to Web Audio once.
  const A = window.__ytpXfAudio || (window.__ytpXfAudio = {
    ctx: null, gain: null, sources: new WeakMap(), el: null, starting: false, target: 1 })

  const T = {
    id: "",         // video id of the song playing
    lastCur: 0,
    lastRem: 1e9,
    auto: false,    // this song came from an automatic change: fade it in
    xf: null,       // the hidden next-song player
    hand: null,     // handover from the embed to the real player in progress
    note: ""
  }

  const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
  const clamp01 = (x) => x <= 0 ? 0 : x >= 1 ? 1 : x
  // Equal-power curves: the overlap keeps a steady loudness.
  const curveIn = (x) => Math.sin(clamp01(x) * Math.PI / 2)
  const curveOut = (x) => Math.cos(clamp01(x) * Math.PI / 2)

  function player() {
    const p = document.querySelector("#movie_player")
    return p && typeof p.getCurrentTime === "function" && typeof p.getPlayerState === "function" ? p : null
  }
  function mainVideo() { return document.querySelector("#movie_player video.html5-main-video, #movie_player video") }

  function publish(phase) {
    T.note = phase
    document.documentElement.setAttribute("data-ytp-xf", cfg.mode + ":" + phase)
  }

  // ---- Audio: route the page's <video> through a gain node. Only once the
  // AudioContext is actually running, otherwise the page would go silent.
  async function ensureAudio() {
    const v = mainVideo()
    if (!v || A.starting) return
    if (A.ctx && A.el === v && A.ctx.state === "running") return
    A.starting = true
    try {
      if (!A.ctx) {
        A.ctx = new AudioContext()
        A.gain = A.ctx.createGain()
        A.gain.connect(A.ctx.destination)
      }
      if (A.ctx.state !== "running") await Promise.race([A.ctx.resume(), sleep(1000)])
      if (A.ctx.state !== "running") return
      if (A.el !== v) {
        let src = A.sources.get(v)
        if (!src) { src = A.ctx.createMediaElementSource(v); A.sources.set(v, src) }
        src.connect(A.gain)
        A.el = v
      }
    } catch (e) {
      publish("audio-error")
    } finally { A.starting = false }
  }
  const audioReady = () => !!(A.ctx && A.ctx.state === "running" && A.el && A.el === mainVideo())

  function setGain(target, tau = 0.04) {
    if (!A.gain) return
    target = clamp01(target)
    if (Math.abs(target - A.target) < 0.002) return
    A.target = target
    const now = A.ctx.currentTime
    A.gain.gain.cancelScheduledValues(now)
    A.gain.gain.setTargetAtTime(target, now, tau)
  }

  // ---- Queue: the song playing, its length and the song that comes next.
  function queueState() {
    const q = document.querySelector("ytmusic-player-queue#queue, #queue")
    const st = q && q.queue && q.queue.store && q.queue.store.store
    const s = st && typeof st.getState === "function" ? st.getState() : null
    return s && s.queue ? s.queue : null
  }
  // A queue row's song and (for songs with a music video) its counterpart.
  function sides(item) {
    if (!item) return []
    const w = item.playlistPanelVideoWrapperRenderer
    const prim = w ? w.primaryRenderer && w.primaryRenderer.playlistPanelVideoRenderer : item.playlistPanelVideoRenderer
    const cp = w && w.counterpart && w.counterpart[0] && w.counterpart[0].counterpartRenderer
      && w.counterpart[0].counterpartRenderer.playlistPanelVideoRenderer
    return [prim, cp].filter(Boolean)
  }
  function lengthOf(r) {
    const t = r && r.lengthText ? (r.lengthText.simpleText || (r.lengthText.runs || []).map((x) => x.text).join("")) : ""
    const parts = String(t).trim().split(":").map(Number)
    if (parts.length < 2 || parts.some((n) => !Number.isFinite(n))) return 0
    return parts.reduce((total, n) => total * 60 + n, 0)
  }
  function upcoming(curId) {
    const q = queueState()
    if (!q) return { dur: 0, next: null }
    const items = q.items || []
    // The row of the song the player has (the queue's "selected" row can move
    // on a moment before the player does at a song change).
    const isCur = (it) => sides(it).some((r) => r.videoId === curId)
    let idx = items.findIndex((it) => isCur(it) && sides(it).some((r) => r.selected))
    if (idx < 0) idx = items.findIndex(isCur)
    if (idx < 0) return { dur: 0, next: null }
    const cur = sides(items[idx])
    // Song or music-video side: the next one plays the same kind.
    const side = Math.max(0, cur.findIndex((r) => r.videoId === curId))
    const repeat = String(q.repeatMode || "")
    let nextItem = null
    // "NONE" | "ALL" | "ONE" (match whole words: "NONE" contains "ONE").
    if (/(^|_)ONE$/.test(repeat)) nextItem = items[idx]
    else if (items[idx + 1]) nextItem = items[idx + 1]
    else if (/(^|_)ALL$/.test(repeat)) nextItem = items[0]
    else if (Array.isArray(q.automixItems) && q.automixItems.length) nextItem = q.automixItems[0]
    const ns = sides(nextItem)
    const nr = ns[side] || ns[0]
    return { dur: lengthOf(cur[side] || cur[0]), next: nr && nr.videoId ? nr.videoId : null }
  }

  // ---- The hidden next-song player (www.youtube.com embed, IFrame API by postMessage).
  function post(xf, func, args) {
    try {
      xf.frame.contentWindow.postMessage(JSON.stringify({ event: "command", func, args: args || [], id: 1, channel: "widget" }), "https://www.youtube.com")
    } catch (e) {}
  }
  function embedTime(xf) {
    return xf.state === 1 ? xf.t + (performance.now() - xf.tAt) / 1000 : xf.t
  }
  function preload(id) {
    dropXf()
    const f = document.createElement("iframe")
    f.setAttribute("data-ytp-xf", id)
    f.allow = "autoplay; encrypted-media"
    f.tabIndex = -1
    f.setAttribute("aria-hidden", "true")
    // Tiny and off screen: lowest video quality, nothing visible.
    f.style.cssText = "position:fixed;left:-400px;top:0;width:200px;height:120px;opacity:0;pointer-events:none;border:0"
    f.src = "https://www.youtube.com/embed/" + encodeURIComponent(id) +
      "?enablejsapi=1&autoplay=0&controls=0&disablekb=1&fs=0&rel=0&playsinline=1&origin=" + encodeURIComponent(location.origin)
    const xf = { id, frame: f, ready: false, playing: false, failed: false, t: 0, tAt: 0, state: -1,
                 muted: false, vol: -1, savedVol: null, savedMuted: null, listen: null }
    // The IFrame API only talks once it's been told someone is listening.
    f.addEventListener("load", () => {
      let n = 0
      xf.listen = setInterval(() => {
        if (xf.ready || ++n > 40) { clearInterval(xf.listen); return }
        try { f.contentWindow.postMessage(JSON.stringify({ event: "listening", id: 1, channel: "widget" }), "https://www.youtube.com") } catch (e) {}
      }, 250)
    })
    document.body.appendChild(f)
    T.xf = xf
    publish("preload")
  }
  // Stop it and put back the volume it had: youtube.com remembers the player's
  // volume, and it must not keep the fade's level.
  function dropXf() {
    const xf = T.xf
    if (!xf) return
    T.xf = null
    clearInterval(xf.listen)
    post(xf, "pauseVideo")
    if (xf.savedVol !== null) post(xf, "setVolume", [xf.savedVol])
    if (xf.savedMuted !== null) post(xf, xf.savedMuted ? "mute" : "unMute")
    setTimeout(() => xf.frame.remove(), 400)
  }
  window.__ytpXfDrop = dropXf

  window.__ytpXfMsgHandler = (e) => {
    const xf = T.xf
    if (!xf || e.source !== xf.frame.contentWindow) return
    let d = null
    try { d = typeof e.data === "string" ? JSON.parse(e.data) : e.data } catch (err) { return }
    if (!d || typeof d !== "object") return
    if (d.event === "onReady" || d.event === "initialDelivery") xf.ready = true
    if (d.event === "onError") { xf.failed = true; publish("embed-error " + d.info) }
    if (d.event === "onStateChange" && typeof d.info === "number") { xf.state = d.info; if (d.info === 1) xf.tAt = performance.now() }
    const info = d.info
    if ((d.event === "infoDelivery" || d.event === "initialDelivery") && info && typeof info === "object") {
      xf.ready = true
      if (xf.savedVol === null && typeof info.volume === "number") xf.savedVol = info.volume
      if (xf.savedMuted === null && typeof info.muted === "boolean") xf.savedMuted = info.muted
      if (typeof info.muted === "boolean") xf.muted = info.muted
      if (typeof info.playerState === "number") xf.state = info.playerState
      if (typeof info.currentTime === "number") { xf.t = info.currentTime; xf.tAt = performance.now() }
      const vid = info.videoData && info.videoData.video_id
      if (vid && vid !== xf.id) { xf.failed = true; publish("embed-other-video") }
    }
  }
  window.addEventListener("message", window.__ytpXfMsgHandler)

  function baseVolume(p) {
    try { return p.isMuted() ? 0 : Math.round(p.getVolume()) } catch (e) { return 100 }
  }
  // The embed's level follows the next song's fade-in (by its own clock, so an
  // ad or a slow start stays silent).
  function embedVolume(p) {
    const xf = T.xf
    if (!xf || !xf.playing) return
    const g = cfg.in > 0 ? curveIn(embedTime(xf) / cfg.in) : 1
    const v = Math.round(baseVolume(p) * g)
    if (v !== xf.vol) { xf.vol = v; post(xf, "setVolume", [v]) }
  }

  // ---- A new song started in the real player.
  function onNewSong(id, auto, p) {
    const xf = T.xf
    T.auto = auto
    T.hand = null
    if (xf && xf.id === id && xf.playing && !xf.failed) {
      const tE = embedTime(xf)
      if (xf.muted || xf.state !== 1 || tE < 0.3) {
        // The embed never really got going: plain fade-in from the start.
        dropXf()
        T.auto = true
        publish("fallback")
        return
      }
      setGain(0, 0.01)
      T.hand = { target: tE + SEEK_LEAD, lead: SEEK_LEAD, tries: 0, since: performance.now() }
      p.seekTo(T.hand.target, true)
      publish("handover")
      return
    }
    dropXf()
    publish(auto ? "fade-in" : "idle")
  }

  // Wait for the real player to be playing at the embed's spot, then swap.
  function handover(p, cur, state) {
    const h = T.hand
    const xf = T.xf
    embedVolume(p)
    if (!xf || performance.now() - h.since > 8000) {
      T.hand = null
      dropXf()
      T.auto = true
      publish("handover-timeout")
      return
    }
    if (state !== 1 || cur < h.target - 0.1) { setGain(0, 0.01); return }
    const lag = embedTime(xf) - cur
    if (Math.abs(lag) > 0.15 && h.tries < 2) {
      // Correct the lead by how far off this seek landed.
      h.tries++
      h.lead = Math.max(0, h.lead + lag)
      h.target = embedTime(xf) + h.lead
      p.seekTo(h.target, true)
      return
    }
    // Swap: the real player comes up to the fade-in level as the embed stops.
    T.hand = null
    T.auto = true
    setGain(cfg.in > 0 ? curveIn(cur / cfg.in) : 1, 0.03)
    dropXf()
    publish("crossfaded")
  }

  function tick() {
    const p = player()
    if (cfg.mode === "off" || !p) {
      setGain(1)
      dropXf()
      T.hand = null
      T.id = ""
      publish("off")
      return
    }
    let id = ""
    try { id = (p.getVideoData() || {}).video_id || "" } catch (e) {}
    const state = p.getPlayerState() // 1 playing, 2 paused, 3 buffering, 0 ended, -1 unstarted
    const cur = Number(p.getCurrentTime()) || 0
    const info = upcoming(id)
    const pd = Number(p.getDuration()) || 0
    // The queue's length is exact to the second; the player's is exact once
    // loaded, but only covers what's buffered early in a song.
    const dur = info.dur && Math.abs(pd - info.dur) < 3 ? pd : (info.dur || pd)
    const rem = dur > 0 ? dur - END_EARLY - cur : 1e9

    if (A.ctx && A.ctx.state === "suspended" && A.el) A.ctx.resume().catch(() => {})
    if (state === 1 && !audioReady()) ensureAudio()

    // A new song (or the same one again with repeat-one).
    if (id && (id !== T.id || (T.lastRem <= cfg.out + 1.5 && cur < 3 && cur + 3 < T.lastCur))) {
      const auto = T.id !== "" && T.lastRem <= cfg.out + 1.5
      T.id = id
      onNewSong(id, auto, p)
    }
    T.lastCur = cur
    T.lastRem = rem

    if (T.hand) { handover(p, cur, state); return }
    if (!audioReady()) return

    // Paused or sent back from the end: no crossfade this time.
    if (T.xf && (state === 2 || rem > cfg.out + PRELOAD + 2 || (rem > 1.5 && info.next && info.next !== T.xf.id))) {
      dropXf()
      publish("cancelled")
    }

    if (cfg.mode === "crossfade" && info.next && state === 1 && rem > 0.5) {
      if (!T.xf && rem <= cfg.out + PRELOAD) preload(info.next)
      const xf = T.xf
      if (xf && xf.ready && !xf.playing && !xf.failed && rem <= cfg.out) {
        xf.playing = true
        xf.vol = 0
        post(xf, "setVolume", [0])
        post(xf, "unMute")
        post(xf, "playVideo")
        publish("crossfading")
      }
    }
    if (T.xf && T.xf.failed && T.xf.playing) { dropXf(); publish("fallback") }
    embedVolume(p)

    let g = 1
    if (T.auto) {
      g = cfg.in > 0 ? curveIn(cur / cfg.in) : 1
      if (cur >= cfg.in) T.auto = false
    }
    // Fade out only into another song (the end of the queue just ends).
    if (info.next && rem <= cfg.out) g = Math.min(g, curveOut(1 - rem / cfg.out))
    setGain(g)
  }

  window.__ytpXfCfgHandler = (e) => {
    let d = {}
    try { d = JSON.parse(e.detail || "{}") } catch (err) { return }
    const mode = d.mode === "fade" || d.mode === "crossfade" ? d.mode : "off"
    const num = (v, lo, hi, def) => Number.isFinite(v) ? Math.min(hi, Math.max(lo, v)) : def
    cfg = { mode, out: num(d.out, 0.5, 12, 5), in: num(d.in, 0, 12, 3) }
    window.__ytpXfCfg = cfg
    if (mode !== "crossfade") dropXf()
    publish("config")
  }
  document.addEventListener("ytp-bridge-transition", window.__ytpXfCfgHandler, true)

  window.__ytpXfTimer = setInterval(tick, TICK_MS)
})()
