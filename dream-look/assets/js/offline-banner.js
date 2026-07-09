/**
 * Dream Look — Offline Banner
 * Drop this script tag onto any page to get a bottom banner that appears
 * when the browser goes offline and disappears when connectivity returns.
 * No dependencies, no configuration.
 */

(function offlineBanner() {
  function ensureBanner() {
    let el = document.getElementById('dl-offline-banner');
    if (!el) {
      el = document.createElement('div');
      el.id = 'dl-offline-banner';
      el.className = 'offline-banner';
      el.textContent = "You're offline — some actions may not work until your connection returns.";
      document.body.appendChild(el);
    }
    return el;
  }

  function updateState() {
    const el = ensureBanner();
    el.classList.toggle('is-visible', !navigator.onLine);
  }

  document.addEventListener('DOMContentLoaded', updateState);
  window.addEventListener('online', updateState);
  window.addEventListener('offline', updateState);
})();
