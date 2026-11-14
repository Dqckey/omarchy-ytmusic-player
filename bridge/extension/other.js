// YouTube Music Player bridge, on youtube.com: when a video starts playing,
// tell the extension so the bar can pause YouTube Music ("audio focus").
// Hover previews (the inline player on thumbnails) don't count: only a video
// you've opened (watch page, Shorts, miniplayer) pauses YouTube Music.
// It reads nothing from the page and changes nothing.
(() => {
  // The hover-preview player and the thumbnails / result cards it plays in.
  const PREVIEW = "ytd-video-preview, #video-preview, #inline-preview-player, #inline-player, ytd-thumbnail, ytd-rich-grid-media, ytd-video-renderer, yt-lockup-view-model"

  const isPreview = el => {
    try { return !!el.closest(PREVIEW) } catch (e) { return false }
  }

  // Replace any copy left by an earlier injection (extension reload).
  if (window.__ytpOtherHandler) document.removeEventListener("play", window.__ytpOtherHandler, true)
  window.__ytpOtherHandler = ev => {
    const el = ev.target
    if (!(el instanceof HTMLMediaElement) || isPreview(el)) return
    try { chrome.runtime.sendMessage({ type: "other-playing" }) } catch (e) {}
  }
  document.addEventListener("play", window.__ytpOtherHandler, true)
})()
