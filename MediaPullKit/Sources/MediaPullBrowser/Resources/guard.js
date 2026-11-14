// MediaPull read-only guard (SPEC R-508): pages in the browser pane can never receive files from
// this Mac through paste or drop. Runs in every frame before page scripts.
(() => {
  if (window.__mediapullGuardInstalled) return;
  window.__mediapullGuardInstalled = true;
  const carriesFiles = (transfer) => {
    if (!transfer) return false;
    if (transfer.files && transfer.files.length) return true;
    const types = Array.from(transfer.types || []);
    return types.includes("Files") || types.includes("application/x-moz-file");
  };
  const block = (event) => {
    if (carriesFiles(event.clipboardData || event.dataTransfer)) {
      event.preventDefault();
      event.stopImmediatePropagation();
      if (event.dataTransfer) event.dataTransfer.dropEffect = "none";
    }
  };
  for (const name of ["paste", "drop", "dragenter", "dragover"]) window.addEventListener(name, block, true);
})();
