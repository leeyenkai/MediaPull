// MediaPull read-only guard, page side (SPEC R-508): navigator.clipboard.read hands a page images and files from the
// clipboard without a paste event, so guard.js (in MediaPull's own script world) cannot see it. Reading text stays.
(() => {
  try {
    const refuse = () => Promise.reject(new DOMException("Reading files from the clipboard is turned off.", "NotAllowedError"));
    if (window.Clipboard && Clipboard.prototype.read) {
      Object.defineProperty(Clipboard.prototype, "read", { value: refuse, writable: false, configurable: false });
    }
  } catch (error) {}
})();
