// YouTube Music Player bridge, on youtube.com: when a video starts playing,
// tell the extension so the bar can pause YouTube Music ("audio focus").
// It reads nothing from the page and changes nothing.
(() => {
  // Replace any copy left by an earlier injection (extension reload).
  if (window.__ytpOtherHandler) document.removeEventListener("play", window.__ytpOtherHandler, true)
  window.__ytpOtherHandler = () => {
    try { chrome.runtime.sendMessage({ type: "other-playing" }) } catch (e) {}
  }
  document.addEventListener("play", window.__ytpOtherHandler, true)
})()
