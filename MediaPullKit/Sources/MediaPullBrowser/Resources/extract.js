// MediaPull media extraction (SPEC section 9, message schema in Appendix B).
// Runs in an isolated content world in every frame, from document start. It only reads the page.
(() => {
  if (window.__mediapullExtractInstalled) return;
  window.__mediapullExtractInstalled = true;
  const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.mediapull;
  if (!handler) return;

  const MEDIA_EXT = /\.(jpe?g|jfif|png|apng|gif|webp|avif|heic|heif|jxl|bmp|tiff?|svg|ico|mp4|m4v|mov|webm|mkv|m3u8|mpd|mp3|m4a|aac|oga|ogg|opus|wav|flac)(?:[?#]|$)/i;
  const AV_EXT = /\.(mp4|m4v|mov|webm|mkv|m3u8|mpd|mp3|m4a|aac|oga|ogg|opus|wav|flac)(?:[?#]|$)/i;
  const SEGMENT_EXT = /\.(m4s|ts|cmfv|cmfa|aac|vtt|webvtt|key)(?:[?#]|$)/i;
  const PDF_EXT = /\.pdf(?:[?#]|$)/i;
  const LAZY_ATTRS = [
    "data-src", "data-srcset", "data-lazy", "data-lazy-src", "data-lazy-srcset", "data-original", "data-full",
    "data-full-src", "data-zoom-image", "data-large_image", "data-hires", "data-bg", "data-background",
    "data-background-image", "data-image", "data-img", "data-fullsize", "data-large", "data-highres", "data-orig-file",
    "data-large-file", "data-src-retina", "data-pin-media",
  ];
  const MAX_DATA_URI = 8 * 1024 * 1024;
  const MAX_ITEMS = 500;
  const MAX_BYTES = 256 * 1024;

  let queue = [];
  let queueBytes = 0;
  let seq = 0;
  let timer = null;
  let flushedOnce = false;
  let lastFlush = 0;
  let total = 0;
  const seen = new Map();
  const groups = new WeakMap();
  // Group ids start at a random point in each document, so a reloaded page's groups never join the
  // groups the previous load of the same address sent (the session keeps items across loads).
  let nextGroup = Math.floor(Math.random() * 2 ** 30) * 2 ** 20 + 1;

  const idle = window.requestIdleCallback
    ? (fn) => window.requestIdleCallback(fn, { timeout: 400 })
    : (fn) => setTimeout(() => fn({ timeRemaining: () => 12, didTimeout: false }), 30);

  function groupOf(element) {
    let id = groups.get(element);
    if (!id) {
      id = nextGroup++;
      groups.set(element, id);
    }
    return id;
  }

  function absolute(value) {
    try {
      return new URL(value, document.baseURI).href;
    } catch (error) {
      return null;
    }
  }

  function push(raw, kind, extra) {
    if (!raw || typeof raw !== "string") return;
    let url = raw.trim();
    if (!url || /^(javascript|about|mailto|tel):/i.test(url)) return;
    if (/^data:/i.test(url)) {
      if (url.length < 4096 || url.length > MAX_DATA_URI || !/^data:(image|video|audio)\//i.test(url)) return;
    } else if (!/^blob:/i.test(url)) {
      url = absolute(url);
      if (!url || !/^https?:/i.test(url)) return;
    }
    const info = extra || {};
    const key = (url.length > 600 ? url.slice(0, 600) + "#" + url.length : url) + "|" + kind + "|" + (info.g || 0);
    const signature = [info.w || 0, info.h || 0, info.dw || 0, info.dur || 0, info.drm ? 1 : 0].join(",");
    if (seen.get(key) === signature) return;
    seen.set(key, signature);
    const item = { u: url, k: kind };
    for (const field of ["d", "w", "h", "dw", "dh", "alt", "g", "t", "drm", "dur"]) {
      const value = info[field];
      if (value !== undefined && value !== null && value !== "" && value !== 0 && value !== false) item[field] = value;
    }
    queue.push(item);
    queueBytes += url.length + 80;
    total++;
    schedule();
  }

  function schedule() {
    if (queue.length >= MAX_ITEMS || queueBytes >= MAX_BYTES) {
      flush();
      return;
    }
    if (timer) return;
    const delay = flushedOnce ? Math.max(0, 300 - (Date.now() - lastFlush)) : 50;
    timer = setTimeout(flush, delay);
  }

  function flush() {
    if (timer) {
      clearTimeout(timer);
      timer = null;
    }
    while (queue.length) {
      const batch = [];
      let bytes = 0;
      while (queue.length && batch.length < MAX_ITEMS && bytes < MAX_BYTES) {
        const item = queue.shift();
        bytes += item.u.length + 80;
        batch.push(item);
      }
      seq++;
      try {
        handler.postMessage(JSON.stringify({ v: 1, seq, page: location.href, title: document.title || "", items: batch }));
      } catch (error) {}
    }
    queueBytes = 0;
    flushedOnce = true;
    lastFlush = Date.now();
  }

  // Parses srcset per the HTML standard, so commas inside URLs (Cloudinary, imgix) survive.
  function parseSrcset(input) {
    const results = [];
    if (!input) return results;
    let i = 0;
    const n = input.length;
    while (i < n) {
      while (i < n && /[\s,]/.test(input[i])) i++;
      if (i >= n) break;
      const start = i;
      while (i < n && !/\s/.test(input[i])) i++;
      let url = input.slice(start, i);
      let descriptor = "";
      if (/,$/.test(url)) {
        url = url.replace(/,+$/, "");
      } else {
        while (i < n && /\s/.test(input[i])) i++;
        const descriptorStart = i;
        let inParens = false;
        while (i < n) {
          const c = input[i];
          if (c === "(") inParens = true;
          else if (c === ")") inParens = false;
          else if (c === "," && !inParens) break;
          i++;
        }
        descriptor = input.slice(descriptorStart, i).trim().split(/\s+/)[0] || "";
        i++;
      }
      if (url) results.push({ url, d: descriptor });
    }
    return results;
  }

  function cssURLs(value) {
    const urls = [];
    if (!value || value === "none" || value.indexOf("url(") < 0) return urls;
    const pattern = /url\(\s*(['"]?)(.*?)\1\s*\)/g;
    let match;
    while ((match = pattern.exec(value))) {
      if (match[2]) urls.push(match[2]);
    }
    return urls;
  }

  function caption(element) {
    const figure = element.closest && element.closest("figure");
    if (!figure) return "";
    const figcaption = figure.querySelector("figcaption");
    return figcaption ? (figcaption.textContent || "").trim().slice(0, 500) : "";
  }

  function textFor(element) {
    const alt = (element.getAttribute && (element.getAttribute("alt") || element.getAttribute("aria-label") || element.getAttribute("title"))) || "";
    return (alt.trim() || caption(element)).slice(0, 500);
  }

  function looksLikeMedia(url) {
    return !!url && MEDIA_EXT.test(url) && !SEGMENT_EXT.test(url);
  }

  function processImage(img) {
    const g = groupOf(img);
    const alt = textFor(img);
    const current = img.currentSrc || img.src;
    if (current) {
      push(current, "img", {
        w: img.naturalWidth || undefined, h: img.naturalHeight || undefined,
        dw: img.clientWidth || undefined, dh: img.clientHeight || undefined, alt, g,
      });
    }
    if (img.srcset) for (const c of parseSrcset(img.srcset)) push(c.url, "srcset", { d: c.d, alt, g });
    processLazy(img, g, alt);
    const parent = img.parentElement;
    if (parent && parent.tagName === "PICTURE") {
      for (const source of parent.querySelectorAll("source")) {
        const set = source.srcset || source.getAttribute("data-srcset") || "";
        for (const c of parseSrcset(set)) push(c.url, "picture", { d: c.d, t: source.type || undefined, alt, g });
      }
    }
    const link = img.closest && img.closest("a[href]");
    if (link && looksLikeMedia(link.href)) push(link.href, "link", { alt, g });
  }

  // Lightbox links that open the large image from script: onclick="show('photos/large.jpg')".
  const LIGHTBOX = /['"]([^'"\s]+\.(?:jpe?g|png|gif|webp|avif|mp4|m4v|mov)(?:\?[^'"\s]*)?)['"]/gi;
  function processLightbox(element) {
    const script = element.getAttribute("onclick");
    if (!script || script.length > 2000) return;
    const inner = element.querySelector("img");
    const g = inner ? groupOf(inner) : undefined;
    for (const match of script.matchAll(LIGHTBOX)) push(match[1], "link", { alt: textFor(element), g });
  }

  function processLazy(element, g, alt) {
    const mediaElement = /^(IMG|SOURCE|VIDEO|AUDIO|PICTURE)$/.test(element.tagName);
    if (/^(IFRAME|SCRIPT|LINK|STYLE|EMBED|OBJECT)$/.test(element.tagName)) return;
    for (const name of LAZY_ATTRS) {
      const value = element.getAttribute(name);
      if (!value) continue;
      if (/srcset/i.test(name) || /\s\d+[wx](,|$)/.test(value)) {
        for (const c of parseSrcset(value)) push(c.url, "lazy", { d: c.d, alt, g });
      } else if (value.indexOf("url(") >= 0) {
        for (const url of cssURLs(value)) push(url, "css", { g, alt });
      } else if (mediaElement ? (/^(https?:|\/|\.\/|[\w-]+\/)/i.test(value) || looksLikeMedia(value)) : looksLikeMedia(value)) {
        push(value, "lazy", { alt, g });
      }
    }
  }

  function processMediaElement(element) {
    const g = groupOf(element);
    const kind = element.tagName === "AUDIO" ? "audio" : "video";
    const drm = !!element.mediaKeys;
    const duration = isFinite(element.duration) && element.duration > 0 ? Math.round(element.duration * 1000) / 1000 : undefined;
    const size = kind === "video" ? { w: element.videoWidth || undefined, h: element.videoHeight || undefined } : {};
    const src = element.currentSrc || element.src || element.getAttribute("src");
    if (src) push(src, kind, Object.assign({ g, drm, dur: duration }, size));
    for (const source of element.querySelectorAll("source")) {
      const value = source.src || source.getAttribute("src") || source.getAttribute("data-src");
      if (value) push(value, kind, Object.assign({ g, drm, dur: duration, t: source.type || undefined }, size));
    }
    const poster = element.poster || element.getAttribute("data-poster");
    if (poster) push(poster, "poster", { alt: textFor(element) });
    processLazy(element, g, "");
  }

  function processHead(element) {
    if (element.tagName === "META") {
      const name = (element.getAttribute("property") || element.getAttribute("name") || "").toLowerCase();
      const content = element.getAttribute("content");
      if (!content) return;
      if (/^(og:image|og:image:url|og:image:secure_url|twitter:image|twitter:image:src|thumbnail|image)$/.test(name)) push(content, "meta", {});
      else if (/^(og:video|og:video:url|og:video:secure_url|twitter:player:stream)$/.test(name)) push(content, "meta", { t: element.getAttribute("type") || undefined });
    } else if (element.tagName === "LINK") {
      const rel = (element.getAttribute("rel") || "").toLowerCase();
      const href = element.getAttribute("href");
      if (!href) return;
      if (/icon/.test(rel)) push(href, "icon", {});
      else if (rel === "image_src") push(href, "meta", {});
      else if (rel === "preload" && (element.getAttribute("as") || "") === "image") {
        push(href, "meta", {});
        const set = element.getAttribute("imagesrcset");
        if (set) for (const c of parseSrcset(set)) push(c.url, "srcset", { d: c.d });
      }
    }
  }

  function processBackground(element) {
    let style;
    try {
      style = getComputedStyle(element);
    } catch (error) {
      return;
    }
    const value = style.backgroundImage;
    if (!value || value === "none" || value.indexOf("url(") < 0) return;
    const g = groupOf(element);
    for (const url of cssURLs(value)) push(url, "css", { g, alt: textFor(element) });
  }

  function process(element) {
    if (!element || element.nodeType !== 1) return;
    const tag = element.tagName;
    switch (tag) {
      case "IMG":
        processImage(element);
        break;
      case "VIDEO":
      case "AUDIO":
        processMediaElement(element);
        break;
      case "SOURCE": {
        const parent = element.parentElement;
        if (parent && (parent.tagName === "VIDEO" || parent.tagName === "AUDIO")) processMediaElement(parent);
        else if (parent && parent.tagName === "PICTURE") {
          const img = parent.querySelector("img");
          if (img) processImage(img);
        }
        break;
      }
      case "META":
      case "LINK":
        processHead(element);
        break;
      case "A":
        if (PDF_EXT.test(element.href || "") || /\/pdf\//i.test(element.pathname || "")
            || (/^\s*(view|download|get|open)?\s*pdf\b/i.test(element.textContent || "") && (element.textContent || "").length < 40)) {
          push(element.href, "document", {});
        }
        else if (looksLikeMedia(element.href) && !element.querySelector("img")) push(element.href, "link", { alt: textFor(element) });
        processLightbox(element);
        break;
      case "IFRAME":
      case "EMBED":
      case "OBJECT": {
        const target = element.getAttribute("src") || element.getAttribute("data") || "";
        if (PDF_EXT.test(target)) push(target, "document", {});
        break;
      }
      case "IMAGE":
      case "image": {
        const href = element.getAttribute("href") || element.getAttribute("xlink:href");
        if (href) push(href, "img", { g: groupOf(element) });
        break;
      }
      case "SCRIPT":
      case "STYLE":
      case "NOSCRIPT":
      case "TEMPLATE":
        return;
      default:
        if (element.hasAttributes && element.hasAttributes()) {
          for (const name of LAZY_ATTRS) {
            if (element.hasAttribute(name)) {
              processLazy(element, groupOf(element), textFor(element));
              break;
            }
          }
        }
    }
    processBackground(element);
    if (element.shadowRoot) scanTree(element.shadowRoot);
  }

  // Walks a tree in idle-time chunks so large pages never freeze.
  const work = [];
  let working = false;

  function scanTree(root) {
    if (!root || !root.querySelectorAll) return;
    if (root.nodeType === 1) work.push(root);
    const all = root.querySelectorAll("*");
    for (let i = 0; i < all.length; i++) work.push(all[i]);
    run();
  }

  function run() {
    if (working) return;
    working = true;
    idle(function step(deadline) {
      let count = 0;
      while (work.length && count < 2000 && (count < 200 || (deadline && deadline.timeRemaining && deadline.timeRemaining() > 2))) {
        // One odd element must not stop the scanner for the rest of the document.
        try { process(work.shift()); } catch (e) {}
        count++;
      }
      if (work.length) {
        idle(step);
      } else {
        working = false;
        flush();
      }
    });
  }

  // Added subtrees are scanned in full; an attribute change only rescans its own element, so pages
  // that restyle containers every frame (carousels, parallax) do not keep the scanner busy.
  const pending = new Set();
  const pendingSingles = new Set();
  let pendingScheduled = false;

  function schedulePending() {
    if (pendingScheduled) return;
    pendingScheduled = true;
    idle(() => {
      pendingScheduled = false;
      for (const node of pendingSingles) if (node.isConnected && !pending.has(node)) work.push(node);
      pendingSingles.clear();
      const nodes = Array.from(pending);
      pending.clear();
      for (const node of nodes) {
        if (!node.isConnected) continue;
        work.push(node);
        if (node.querySelectorAll) {
          const descendants = node.querySelectorAll("*");
          const limit = Math.min(descendants.length, 5000);
          for (let i = 0; i < limit; i++) work.push(descendants[i]);
        }
      }
      run();
    });
  }

  function observe() {
    const target = document.documentElement || document;
    const observer = new MutationObserver((mutations) => {
      for (const mutation of mutations) {
        if (mutation.type === "childList") {
          for (const node of mutation.addedNodes) if (node.nodeType === 1) pending.add(node);
        } else if (mutation.type === "attributes" && mutation.target.nodeType === 1) {
          pendingSingles.add(mutation.target);
        }
      }
      if (pending.size || pendingSingles.size) schedulePending();
    });
    observer.observe(target, {
      childList: true, subtree: true, attributes: true,
      attributeFilter: ["src", "srcset", "style", "class", "poster", "href", "content", "data-poster"].concat(LAZY_ATTRS),
    });
  }

  // Natural sizes arrive when images load; durations when media metadata loads.
  document.addEventListener("load", (event) => {
    const target = event.target;
    if (target && target.tagName === "IMG") processImage(target);
  }, true);
  document.addEventListener("loadedmetadata", (event) => {
    const target = event.target;
    if (target && (target.tagName === "VIDEO" || target.tagName === "AUDIO")) processMediaElement(target);
  }, true);
  document.addEventListener("encrypted", (event) => {
    const target = event.target;
    if (target && target.tagName === "VIDEO") processMediaElement(target);
  }, true);

  // Media the page fetched itself, including stream manifests.
  try {
    const performanceObserver = new PerformanceObserver((list) => {
      for (const entry of list.getEntries()) {
        const url = entry.name;
        if (!url || !/^https?:/i.test(url) || SEGMENT_EXT.test(url)) continue;
        const initiator = entry.initiatorType || "";
        if (/\.(m3u8|mpd)(?:[?#]|$)/i.test(url)) push(url, "network", {});
        else if (AV_EXT.test(url)) push(url, "network", {});
        else if (MEDIA_EXT.test(url) && /^(img|css|link|video|audio|other|image)$/.test(initiator)) push(url, "network", {});
      }
    });
    performanceObserver.observe({ type: "resource", buffered: true });
  } catch (error) {}

  function start() {
    scanTree(document.documentElement);
    observe();
  }

  if (document.documentElement) {
    if (document.readyState === "loading") {
      document.addEventListener("DOMContentLoaded", () => scanTree(document.documentElement), { once: true });
      observe();
    } else {
      start();
    }
  } else {
    document.addEventListener("DOMContentLoaded", start, { once: true });
  }
  window.addEventListener("load", () => scanTree(document.documentElement), { once: true });

  // Called from the app.
  window.__mediapullRescan = () => {
    seen.clear();
    scanTree(document.documentElement);
    return true;
  };
  window.__mediapullCount = () => total;
  window.__mediapullScrollStep = () => {
    const before = window.scrollY;
    const height = Math.max(document.documentElement.scrollHeight, document.body ? document.body.scrollHeight : 0);
    window.scrollBy({ top: Math.round(window.innerHeight * 0.85), behavior: "instant" });
    return { moved: window.scrollY !== before, atBottom: window.scrollY + window.innerHeight >= height - 4, total };
  };
  window.__mediapullReadBlob = async (url) => {
    const response = await fetch(url);
    const blob = await response.blob();
    if (blob.size > 25 * 1024 * 1024) return null;
    const buffer = await blob.arrayBuffer();
    const bytes = new Uint8Array(buffer);
    let binary = "";
    for (let i = 0; i < bytes.length; i += 0x8000) binary += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
    return btoa(binary);
  };
})();
