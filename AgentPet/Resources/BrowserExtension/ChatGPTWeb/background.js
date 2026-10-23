"use strict";

const HOST_NAME = "com.agentpet.chatgpt";
const tabs = new Map();
const sequences = new Map();
const epochs = new Map();
const retiredSources = new Map();
const endedGenerations = new Set();
const endedOrder = [];
let nativePort = null;
let heartbeat = null;
let refreshing = false;

function isChatGPT(urlString) {
  try {
    const url = new URL(urlString);
    return url.protocol === "https:" && url.hostname === "chatgpt.com";
  } catch { return false; }
}

function cleanTabTitle(value) {
  if (typeof value !== "string") return null;

  const cleaned = value
    .replace(/[\u0000-\u001F\u007F]/g, " ")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, 120);

  if (!cleaned || /^ChatGPT$/i.test(cleaned)) return null;

  return cleaned;
}

function cleanConversationTitle(value) {
  const cleaned = cleanTabTitle(value);
  if (!cleaned || /^(ChatGPT|New chat)$/i.test(cleaned)) return null;
  return cleaned;
}

function cleanConversationURL(value) {
  if (typeof value !== "string") return null;

  try {
    const url = new URL(value);
    if (url.origin !== "https://chatgpt.com" || url.username || url.password ||
        !/^\/c\/[A-Za-z0-9-]+\/?$/.test(url.pathname)) {
      return null;
    }

    return url.origin + url.pathname.replace(/\/$/, "");
  } catch {
    return null;
  }
}

function validObservation(message) {
  return ["unknown", "idle", "generating"].includes(message.state) &&
    validPageMetadata(message) &&
    validGeneration(message.generationId) &&
    (message.state !== "generating" || typeof message.generationId === "string") &&
    validTime(message.observedAt);
}

function validPageMetadata(message) {
  return typeof message.pageEpoch === "string" && message.pageEpoch.length > 0 && message.pageEpoch.length <= 128 &&
    Number.isSafeInteger(message.routeRevision) && message.routeRevision >= 0 &&
    Number.isSafeInteger(message.sequence) && message.sequence > 0 && validTime(message.observedAt);
}

function validGeneration(id) {
  return id === null || (typeof id === "string" && id.length > 0 && id.length <= 128);
}

function validTime(value) {
  return Number.isSafeInteger(value) && Math.abs(Date.now() - value) < 300000;
}

function validGenerationStart(value) {
  return Number.isSafeInteger(value) && value > 0 && value <= Date.now() + 10000 &&
    Date.now() - value < 7 * 24 * 3600 * 1000;
}

function sendNative(message) {
  if (!nativePort || new TextEncoder().encode(JSON.stringify(message)).length > 65536) return;
  try { nativePort.postMessage(message); } catch { handleNativeDisconnect(nativePort); }
}

function publishSnapshot() {
  const now = Date.now();
  sendNative({version: 1, type: "snapshot", tabs: [...tabs.values()].map(tab => ({
    tabId: tab.tabId,
    state: now - tab.lastSeen < 30000 ? tab.state : "unknown",
    generationId: now - tab.lastSeen < 30000 ? tab.generationId : null,
    observedAt: now - tab.lastSeen < 30000 ? tab.lastSeen : now,
    generationStartedAt: now - tab.lastSeen < 30000 && tab.state === "generating"
      ? tab.generationStartedAt ?? null
      : null,
    title: tab.title ?? null
  }))});
}

function retired(tabId, token) {
  return retiredSources.get(tabId)?.includes(token) ?? false;
}

function retire(tabId, token) {
  if (!token) return;
  const sources = retiredSources.get(tabId) ?? [];
  if (sources.includes(token)) return;
  sources.push(token);
  if (sources.length > 16) sources.shift();
  retiredSources.set(tabId, sources);
}

function pageIdentity(tabId, message, sender) {
  if (!validPageMetadata(message)) return null;
  const documentId = typeof sender.documentId === "string" ? sender.documentId : null;
  const previous = sequences.get(tabId);
  const sameDocument = previous && (previous.documentId !== null && documentId !== null
    ? previous.documentId === documentId
    : previous.pageEpoch === message.pageEpoch);
  const samePage = Boolean(sameDocument && previous.pageEpoch === message.pageEpoch);

  if (retired(tabId, `page:${message.pageEpoch}`) ||
      (documentId !== null && retired(tabId, `document:${documentId}`))) return null;

  if (previous && samePage) {
    if (message.routeRevision < previous.routeRevision || message.sequence <= previous.sequence) return null;
  }

  return {documentId, previous, sameDocument: Boolean(sameDocument), samePage, message};
}

function acceptPageIdentity(tabId, identity) {
  const {documentId, previous, samePage, sameDocument, message} = identity;
  if (previous && !samePage) {
    retire(tabId, `page:${previous.pageEpoch}`);
    if (!sameDocument && previous.documentId !== null) retire(tabId, `document:${previous.documentId}`);
  }
  sequences.set(tabId, {
    documentId,
    pageEpoch: message.pageEpoch,
    routeRevision: message.routeRevision,
    sequence: message.sequence
  });
}

function applyObservation(tabId, message, sender, chromeTab) {
  if (!validObservation(message)) return;
  const identity = pageIdentity(tabId, message, sender);
  if (!identity) return;
  acceptPageIdentity(tabId, identity);
  const acceptedPage = sequences.get(tabId);
  const previous = tabs.get(tabId);
  const sameRoute = previous?.pageEpoch === message.pageEpoch &&
    previous?.routeRevision === message.routeRevision;
  const sameGeneration = previous?.state === "generating" &&
    previous.generationId === message.generationId &&
    previous.pageEpoch === acceptedPage.pageEpoch &&
    previous.routeRevision === acceptedPage.routeRevision;
  const generationStartedAt = message.state === "generating"
    ? (validGenerationStart(message.generationStartedAt)
      ? message.generationStartedAt
      : sameGeneration ? previous.generationStartedAt ?? null : null)
    : null;
  const conversationTitle = cleanConversationTitle(message.conversationTitle);
  const browserTitle = cleanTabTitle(chromeTab?.title);
  const retainedConversationTitle =
    sameRoute && previous?.titleSource === "conversation"
      ? previous.title
      : null;
  const title = conversationTitle ?? retainedConversationTitle ?? browserTitle ??
    (sameRoute ? previous?.title ?? null : null);
  const titleSource = conversationTitle || retainedConversationTitle
    ? "conversation"
    : browserTitle
      ? "tab"
      : sameRoute
        ? previous?.titleSource ?? null
        : null;
  const record = {tabId, state: message.state, generationId: message.generationId,
    generationStartedAt, lastSeen: Date.now(), pageEpoch: acceptedPage.pageEpoch,
    routeRevision: acceptedPage.routeRevision, title, titleSource};
  tabs.set(tabId, record);
  sendNative({version: 1, type: "tab_state", tabId, state: record.state,
    generationId: record.generationId, generationStartedAt: record.generationStartedAt,
    observedAt: record.lastSeen, title: record.title});
}

function updateTrackedTitle(tabId, rawTitle) {
  const record = tabs.get(tabId);
  if (!record) return;
  if (record.titleSource === "conversation") return;

  const title = cleanTabTitle(rawTitle);

  const titleSource = title ? "tab" : null;
  if (record.title === title && record.titleSource === titleSource) return;

  tabs.set(tabId, {
    ...record,
    title,
    titleSource
  });

  sendNative({
    version: 1,
    type: "tab_title",
    tabId,
    title
  });
}

async function probe(tabId) {
  if (!epochs.has(tabId)) epochs.set(tabId, 0);
  const epoch = epochs.get(tabId);
  let reachable = false;
  try {
    const response = await chrome.tabs.sendMessage(tabId, {type: "probe"}, {frameId: 0});
    if (epochs.get(tabId) !== epoch) return;
    reachable = response?.type === "probe_result";
  } catch {}
  if (reachable || epochs.get(tabId) !== epoch) return;
  const current = await chrome.tabs.get(tabId).catch(() => null);
  if (epochs.get(tabId) === epoch && isChatGPT(current?.url)) {
    const previous = tabs.get(tabId);

    if (previous?.state === "generating" && Date.now() - previous.lastSeen < 30000) {
      return;
    }

    const title = cleanTabTitle(current?.title);
    const record = {tabId, state: "unknown", generationId: null, lastSeen: Date.now(),
      generationStartedAt: null, title, titleSource: title ? "tab" : null,
      pageEpoch: null, routeRevision: null};
    tabs.set(tabId, record);
    sendNative({version: 1, type: "tab_state", tabId, state: "unknown", generationId: null,
      generationStartedAt: null, observedAt: record.lastSeen, title: record.title});
  }
}

async function refreshTabs() {
  if (refreshing) return;
  refreshing = true;
  try {
    const existing = await chrome.tabs.query({url: "https://chatgpt.com/*"});
    const live = new Set(existing.map(tab => tab.id));
    for (const id of tabs.keys()) if (!live.has(id)) clearTab(id);
    await Promise.all(existing.filter(tab => Number.isInteger(tab.id)).map(async tab => {
      updateTrackedTitle(tab.id, tab.title);
      await probe(tab.id);
    }));
  } finally { refreshing = false; }
}

function connectNative() {
  if (nativePort) return;
  try {
    const port = chrome.runtime.connectNative(HOST_NAME);
    nativePort = port;
    port.onMessage.addListener(handleNativeMessage);
    port.onDisconnect.addListener(() => handleNativeDisconnect(port));
    sendNative({version: 1, type: "hello", source: "chatgpt_web"});
    publishSnapshot();
    clearInterval(heartbeat);
    heartbeat = setInterval(() => { refreshTabs().catch(() => {}); }, 15000);
    refreshTabs().catch(() => {});
  } catch { nativePort = null; }
}

function handleNativeDisconnect(port) {
  void chrome.runtime.lastError;
  if (nativePort !== port) return;
  nativePort = null;
  clearInterval(heartbeat);
  heartbeat = null;
  for (const tab of tabs.values()) {
    tab.state = "unknown";
    tab.generationId = null;
    tab.generationStartedAt = null;
    tab.lastSeen = 0;
  }
  // End events are never replayed; reconnect reconstructs only current observations.
}

function handleNativeMessage(message) {
  if (message?.version === 1 && message.type === "open_tab" && Number.isSafeInteger(message.tabId) && message.tabId >= 0) {
    openChatGPTTab(message.tabId);
  }
}

async function openChatGPTTab(tabId) {
  if (!Number.isSafeInteger(tabId) || tabId < 0) return;
  try {
    const tab = await chrome.tabs.get(tabId);
    if (!isChatGPT(tab?.url)) return;
    await chrome.tabs.update(tabId, {active: true});
    if (Number.isInteger(tab.windowId)) await chrome.windows.update(tab.windowId, {focused: true});
  } catch { /* The tab no longer exists. */ }
}

function clearTab(tabId) {
  const wasTracked = tabs.has(tabId) || sequences.has(tabId);
  tabs.delete(tabId);
  sequences.delete(tabId);
  retiredSources.delete(tabId);
  epochs.delete(tabId);
  if (wasTracked) sendNative({version: 1, type: "tab_closed", tabId});
}

chrome.runtime.onMessage.addListener((message, sender) => {
  const tabId = sender.tab?.id;
  if (!Number.isSafeInteger(tabId) || tabId < 0 || sender.frameId !== 0 ||
      !isChatGPT(sender.url) || (sender.tab?.url && !isChatGPT(sender.tab.url))) return;

  const current = sender.tab;
  if (message?.type === "tab_state") {
    applyObservation(tabId, message, sender, current);
  } else if (message?.type === "conversation_title") {
    const tab = tabs.get(tabId);
    const source = sequences.get(tabId);
    const title = cleanConversationTitle(message.conversationTitle);

    if (!tab || !source || !title || !validPageMetadata(message) ||
        tab.pageEpoch !== message.pageEpoch || tab.routeRevision !== message.routeRevision ||
        source.pageEpoch !== message.pageEpoch || source.routeRevision !== message.routeRevision ||
        (source.documentId !== null && typeof sender.documentId === "string" &&
          sender.documentId !== source.documentId)) {
      return;
    }

    if (tab.title === title && tab.titleSource === "conversation") return;

    tabs.set(tabId, {
      ...tab,
      title,
      titleSource: "conversation"
    });
    sendNative({version: 1, type: "tab_title", tabId, title});
  } else if (message?.type === "generation_ended" && message.state === "idle" &&
             validObservation(message) && typeof message.generationId === "string") {
    const tab = tabs.get(tabId);
    const identity = pageIdentity(tabId, message, sender);
    const currentSource = sequences.get(tabId);
    if (!identity?.samePage || currentSource?.routeRevision !== message.routeRevision ||
        !["generating", "idle"].includes(tab?.state) || tab.pageEpoch !== message.pageEpoch ||
        tab.routeRevision !== message.routeRevision || tab.generationId !== message.generationId ||
        Date.now() - tab.lastSeen >= 30000) return;
    const key = `${tabId}:${message.generationId}`;
    if (endedGenerations.has(key)) return;
    acceptPageIdentity(tabId, identity);
    endedGenerations.add(key);
    endedOrder.push(key);
    if (endedOrder.length > 256) endedGenerations.delete(endedOrder.shift());
    const conversationTitle = cleanConversationTitle(message.conversationTitle);
    const routeMatches = tab.pageEpoch === message.pageEpoch &&
      tab.routeRevision === message.routeRevision;
    const browserTitle = cleanTabTitle(current?.title);
    const completedTitle = conversationTitle ??
      (routeMatches ? tab.title : null) ?? browserTitle;
    const titleSource = conversationTitle ? "conversation" :
      routeMatches && tab.title ? tab.titleSource ?? "tab" : browserTitle ? "tab" : null;
    const completedURL = cleanConversationURL(message.conversationURL);
    const completedStart = validGenerationStart(message.generationStartedAt)
      ? message.generationStartedAt
      : validGenerationStart(tab.generationStartedAt)
        ? tab.generationStartedAt
        : null;
    tabs.set(tabId, {...tab, state: "idle", generationId: message.generationId,
      generationStartedAt: null, lastSeen: Date.now(), title: completedTitle, titleSource});
    sendNative({version: 1, type: "generation_ended", tabId,
      generationId: message.generationId, observedAt: message.observedAt,
      generationStartedAt: completedStart, title: completedTitle, conversationURL: completedURL});
  }
});
chrome.tabs.onRemoved.addListener(tabId => {
  clearTab(tabId);
});
chrome.tabs.onUpdated.addListener((tabId, change, tab) => {
  const url = change.url ?? tab.url;

  if (!isChatGPT(url)) {
    if (tabs.has(tabId) || sequences.has(tabId)) clearTab(tabId);
    return;
  }

  if (change.url) epochs.set(tabId, (epochs.get(tabId) ?? 0) + 1);

  if (typeof change.title === "string") {
    updateTrackedTitle(tabId, change.title);
  }

  if (change.url || change.status === "complete") {
    probe(tabId).catch(() => {});
  }
});
chrome.alarms.onAlarm.addListener(alarm => {
  if (alarm.name === "agentpet-reconnect" && !nativePort) connectNative();
});
chrome.runtime.onStartup.addListener(connectNative);
chrome.runtime.onInstalled.addListener(() => { connectNative(); refreshTabs().catch(() => {}); });
chrome.alarms.create("agentpet-reconnect", {periodInMinutes: 0.5});
connectNative();
