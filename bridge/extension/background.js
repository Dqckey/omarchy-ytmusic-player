// YouTube Music Player bridge: relays between the YouTube Music page
// (content.js) and the native host (host.py), which talks to the bar.
// The "reload" command restarts the extension so edited scripts take effect,
// then re-injects them into open YouTube Music tabs (no page refresh, so the
// music keeps playing).
// With several YouTube Music tabs/windows open, the one that most recently
// started playing wins: the others are paused, and only its state reaches the bar.
let port = null
let musicTab = null      // the YouTube Music tab the bar follows
let lastPlaying = false  // whether that tab was playing at its last report

function connect() {
  if (port) return port
  port = chrome.runtime.connectNative("ytmusic_player.bridge")
  port.onMessage.addListener((msg) => {
    if (msg && msg.cmd === "reload") {
      chrome.runtime.reload()
      return
    }
    if (musicTab !== null) chrome.tabs.sendMessage(musicTab, msg).catch(() => {})
  })
  port.onDisconnect.addListener(() => { port = null })
  return port
}

// Pause every other YouTube Music tab.
async function pauseOthers(tabId) {
  const tabs = await chrome.tabs.query({ url: "https://music.youtube.com/*" })
  for (const tab of tabs) {
    if (tab.id !== tabId) chrome.tabs.sendMessage(tab.id, { cmd: "pause" }).catch(() => {})
  }
}

// Put the current scripts into YouTube Music tabs that are already open
// (Chromium only injects declared content scripts on page load).
async function injectOpenTabs() {
  const tabs = await chrome.tabs.query({ url: "https://music.youtube.com/*" })
  for (const tab of tabs) {
    try {
      await chrome.scripting.executeScript({ target: { tabId: tab.id }, files: ["page.js"], world: "MAIN" })
      await chrome.scripting.executeScript({ target: { tabId: tab.id }, files: ["content.js"] })
    } catch (e) {}
  }
}

chrome.runtime.onMessage.addListener((msg, sender) => {
  if (!sender.tab || !msg) return
  const tabId = sender.tab.id
  if (msg.type === "other-playing") {
    // A YouTube video (not YouTube Music) started; the bar decides whether
    // to pause the music.
    try { connect().postMessage({ type: "other" }) } catch (e) { port = null }
    return
  }
  if (msg.type === "playing") {
    // This tab just started playing: it takes over.
    musicTab = tabId
    pauseOthers(tabId)
    return
  }
  if (msg.type !== "state" && msg.type !== "inspect" && msg.type !== "results") return
  // Adopt the first tab we hear from, or a tab that's playing while ours isn't.
  if (musicTab === null || (msg.type === "state" && msg.state && msg.state.playing && tabId !== musicTab && !lastPlaying))
    musicTab = tabId
  if (tabId !== musicTab) return
  if (msg.type === "state") lastPlaying = !!(msg.state && msg.state.playing)
  try { connect().postMessage(msg) } catch (e) { port = null }
})

chrome.tabs.onRemoved.addListener((tabId) => {
  if (tabId === musicTab) { musicTab = null; lastPlaying = false }
})

chrome.runtime.onStartup.addListener(connect)
chrome.runtime.onInstalled.addListener((details) => {
  connect()
  if (details.reason === "update" || details.reason === "install") injectOpenTabs()
})
