(() => {
  "use strict";

  const SELECTORS = {
    composer: [
      '#prompt-textarea',
      'textarea[name="prompt-textarea"]',
      'div[role="textbox"][aria-label="Ask ChatGPT"]'
    ],
    stop: [
      '[data-testid="stop-button"]',
      'button[aria-label="Stop generating"]',
      'button[aria-label="Stop"]'
    ]
  };
  const STATES = {UNKNOWN: "unknown", IDLE: "idle", GENERATING: "generating"};
  const pageEpoch = crypto.randomUUID();
  let state = STATES.UNKNOWN;
  let currentURL = location.href;
  let routeRevision = 0;
  let sequence = 0;
  let generationID = null;
  let generationStartedAt = 0;
  let manuallyStopped = false;
  let lastPublishedConversationTitle = null;
  let lastTitleScanAt = 0;
  let hasPublishedIdentity = false;
  let endTimer = null;
  let inspectTimer = null;
  const lifecycle = new AbortController();

  function cleanConversationLabel(value) {
    if (typeof value !== "string") return null;

    const cleaned = value
      .replace(/[\u0000-\u001F\u007F]/g, " ")
      .replace(/\s+/g, " ")
      .trim()
      .slice(0, 120);

    if (!cleaned || /^(ChatGPT|New chat)$/i.test(cleaned)) return null;
    return cleaned;
  }

  function readActiveConversationTitle() {
    const current = new URL(location.href);

    if (current.origin !== "https://chatgpt.com" || !/^\/c\/[^/]+\/?$/.test(current.pathname)) {
      return null;
    }

    for (const link of document.querySelectorAll('a[href*="/c/"]')) {
      const rawHref = link.getAttribute("href");
      if (!rawHref) continue;

      let target;
      try {
        target = new URL(rawHref, location.origin);
      } catch {
        continue;
      }

      if (target.origin !== current.origin ||
          target.pathname.replace(/\/$/, "") !== current.pathname.replace(/\/$/, "")) {
        continue;
      }

      for (const candidate of [
        link.textContent,
        link.getAttribute("title"),
        link.getAttribute("aria-label")
      ]) {
        const title = cleanConversationLabel(candidate);
        if (title) return title;
      }
    }

    return null;
  }

  function findVisible(selectors) {
    for (const selector of selectors) {
      for (const element of document.querySelectorAll(selector)) {
        if (element.getClientRects().length > 0 && getComputedStyle(element).visibility !== "hidden") {
          return element;
        }
      }
    }
    return null;
  }

  function hasComposer() {
    return SELECTORS.composer.some(selector => document.querySelector(selector) !== null);
  }

  function send(message) {
    if (lifecycle.signal.aborted) return;
    try {
      chrome.runtime.sendMessage(message).catch(() => {});
    } catch {
      // Reloading the extension invalidates content scripts in existing tabs.
      lifecycle.abort();
      observer.disconnect();
      cancelEnd();
      clearTimeout(inspectTimer);
      inspectTimer = null;
    }
  }

  function publish(type, payload = {}) {
    send({
      type,
      pageEpoch,
      routeRevision,
      sequence: ++sequence,
      observedAt: Date.now(),
      ...payload
    });
  }

  function emitState(nextState, force = false) {
    if (state === nextState && !force) return;

    state = nextState;
    publish("tab_state", {
      state,
      generationId: generationID,
      generationStartedAt:
        state === STATES.GENERATING && generationStartedAt > 0
          ? generationStartedAt
          : null,
      conversationTitle: lastPublishedConversationTitle
    });
    hasPublishedIdentity = true;
  }

  function publishConversationTitleIfChanged() {
    if (!hasPublishedIdentity) return;
    const now = Date.now();
    if (now - lastTitleScanAt < 1000) return;
    lastTitleScanAt = now;

    const conversationTitle = readActiveConversationTitle();
    if (conversationTitle === lastPublishedConversationTitle) return;

    lastPublishedConversationTitle = conversationTitle;
    publish("conversation_title", {
      state,
      generationId: generationID,
      conversationTitle
    });
  }

  function cancelEnd() {
    clearTimeout(endTimer);
    endTimer = null;
  }

  function resetNavigation() {
    const previous = new URL(currentURL);
    const next = new URL(location.href);
    const assigningNewChatURL =
      previous.origin === "https://chatgpt.com" &&
      next.origin === previous.origin &&
      previous.pathname === "/" &&
      /^\/c\/[A-Za-z0-9-]+\/?$/.test(next.pathname);
    const wasConfirmingEnd = endTimer !== null;

    const preserveGeneration =
      assigningNewChatURL &&
      state === STATES.GENERATING &&
      generationID !== null &&
      !manuallyStopped &&
      (
        wasConfirmingEnd ||
        findVisible(SELECTORS.stop) !== null
      );

    cancelEnd();

    routeRevision += 1;
    currentURL = location.href;

    lastPublishedConversationTitle = null;
    lastTitleScanAt = 0;
    hasPublishedIdentity = false;

    if (preserveGeneration) {
      emitState(STATES.GENERATING, true);
      return;
    }

    generationID = null;
    generationStartedAt = 0;
    manuallyStopped = false;
    emitState(STATES.UNKNOWN, true);
  }

  function scheduleInspection() {
    if (inspectTimer !== null) return;

    inspectTimer = setTimeout(() => {
      inspectTimer = null;
      inspectState();
      publishConversationTitleIfChanged();
    }, 150);
  }

  function inspectState() {
    if (lifecycle.signal.aborted) return;

    if (currentURL !== location.href) {
      resetNavigation();
      scheduleInspection();
      return;
    }

    if (findVisible(SELECTORS.stop)) {
      cancelEnd();

      if (state !== STATES.GENERATING) {
        generationID = `${Date.now()}-${++sequence}`;
        generationStartedAt = Date.now();
        manuallyStopped = false;
      }

      emitState(STATES.GENERATING);
      return;
    }

    if (!hasComposer()) {
      cancelEnd();
      generationID = null;
      generationStartedAt = 0;
      emitState(STATES.UNKNOWN);
      return;
    }

    if (state !== STATES.GENERATING || manuallyStopped) {
      cancelEnd();
      emitState(STATES.IDLE);
      return;
    }

    if (endTimer !== null) return;

    const endedGeneration = generationID;
    const endedURL = currentURL;
    const observedEnd = Date.now();

    endTimer = setTimeout(() => {
      if (currentURL !== location.href || endedURL !== location.href) {
        resetNavigation();
        scheduleInspection();
        return;
      }

      endTimer = null;

      if (!hasComposer()) {
        generationID = null;
        generationStartedAt = 0;
        emitState(STATES.UNKNOWN);
        return;
      }

      if (findVisible(SELECTORS.stop)) return;

      const confirmedEnd =
        generationID !== null &&
        generationID === endedGeneration &&
        generationStartedAt > 0 &&
        observedEnd >= generationStartedAt &&
        !manuallyStopped;

      if (confirmedEnd) {
        publish("generation_ended", {
          state: STATES.IDLE,
          generationId: endedGeneration,
          generationStartedAt,
          conversationTitle: readActiveConversationTitle(),
          conversationURL: currentConversationURL()
        });
      }

      emitState(STATES.IDLE);
    }, 1200);
  }

  function noteStop(event) {
    if (event.type === "keydown" && !["Enter", " "].includes(event.key)) return;
    if (event.target instanceof Element && event.target.closest(SELECTORS.stop.join(","))) {
      manuallyStopped = true;
    }
  }

  function currentConversationURL() {
    const url = new URL(location.href);

    if (url.origin !== "https://chatgpt.com" || !/^\/c\/[A-Za-z0-9-]+\/?$/.test(url.pathname)) {
      return null;
    }

    return url.origin + url.pathname.replace(/\/$/, "");
  }

  document.addEventListener("pointerdown", noteStop, {capture: true, signal: lifecycle.signal});
  document.addEventListener("click", noteStop, {capture: true, signal: lifecycle.signal});
  document.addEventListener("keydown", noteStop, {capture: true, signal: lifecycle.signal});

  const observer = new MutationObserver(() => {
    scheduleInspection();
  });
  const observationOptions = {
    childList: true, subtree: true, attributes: true, characterData: true,
    attributeFilter: ["data-testid", "aria-label", "style", "class", "disabled"]
  };
  observer.observe(document.documentElement, observationOptions);
  window.addEventListener("popstate", () => {
    scheduleInspection();
  }, {signal: lifecycle.signal});
  window.addEventListener("pagehide", () => {
    cancelEnd();
    clearTimeout(inspectTimer);
    inspectTimer = null;
    observer.disconnect();
    generationID = null;
    emitState(STATES.UNKNOWN);
  }, {signal: lifecycle.signal});
  window.addEventListener("pageshow", event => {
    if (event.persisted) {
      resetNavigation();
      observer.observe(document.documentElement, observationOptions);
      inspectState();
    }
  }, {signal: lifecycle.signal});
  chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
    if (message?.type === "probe") {
      inspectState();
      const observation = {
        state,
        generationId: generationID,
        generationStartedAt: state === STATES.GENERATING && generationStartedAt > 0
          ? generationStartedAt
          : null,
        conversationTitle: readActiveConversationTitle(),
        pageEpoch,
        routeRevision,
        observedAt: Date.now()
      };
      lastPublishedConversationTitle = observation.conversationTitle;
      hasPublishedIdentity = true;
      publish("tab_state", {
        state,
        generationId: generationID,
        generationStartedAt: observation.generationStartedAt,
        conversationTitle: observation.conversationTitle
      });
      sendResponse({type: "probe_result", ...observation});
    }
  });
  inspectState();
})();
