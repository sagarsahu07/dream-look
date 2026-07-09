/**
 * Dream Look — Shared Utilities
 * -----------------------------------------------------------------------
 * Small, dependency-free helpers reused across every page: toasts, form
 * validation, and the initial page-loader fade-out.
 * -----------------------------------------------------------------------
 */

window.dreamLook = window.dreamLook || {};

/**
 * Show a transient toast message in the top-right corner.
 * @param {string} message
 * @param {'success'|'error'} type
 */
window.dreamLook.showToast = function showToast(message, type = 'success') {
  let toast = document.getElementById('dl-toast');

  if (!toast) {
    toast = document.createElement('div');
    toast.id = 'dl-toast';
    document.body.appendChild(toast);
  }

  toast.textContent = message;
  toast.className = `toast toast--${type}`;

  // Force reflow so the transition re-triggers on repeated calls.
  void toast.offsetWidth;
  toast.classList.add('is-visible');

  clearTimeout(toast._hideTimer);
  toast._hideTimer = setTimeout(() => {
    toast.classList.remove('is-visible');
  }, 3800);
};

/**
 * Display or clear an inline error message under a form field.
 * Expects markup: <div class="field"><input id="X">...<span class="field-error" data-for="X"></span></div>
 * @param {string} fieldId
 * @param {string} message  Pass '' to clear the error.
 */
window.dreamLook.setFieldError = function setFieldError(fieldId, message) {
  const input = document.getElementById(fieldId);
  if (!input) return;

  const wrapper = input.closest('.field');
  const errorEl = wrapper ? wrapper.querySelector('.field-error') : null;

  if (message) {
    if (wrapper) wrapper.classList.add('has-error');
    if (errorEl) errorEl.textContent = message;
  } else {
    if (wrapper) wrapper.classList.remove('has-error');
    if (errorEl) errorEl.textContent = '';
  }
};

/** Clears every field-error in a given form element. */
window.dreamLook.clearFormErrors = function clearFormErrors(formEl) {
  formEl.querySelectorAll('.field.has-error').forEach((field) => {
    field.classList.remove('has-error');
    const errorEl = field.querySelector('.field-error');
    if (errorEl) errorEl.textContent = '';
  });
};

window.dreamLook.isValidEmail = function isValidEmail(value) {
  return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(value.trim());
};

/**
 * Escapes a string for safe interpolation into innerHTML template
 * literals. ANY user-controlled text (names, comments, replies, notes)
 * that gets rendered via innerHTML must go through this first — data set
 * by one person (e.g. a customer's full_name at signup) is often rendered
 * in a DIFFERENT person's browser session (e.g. an admin viewing the
 * queue or customer search), so an unescaped value is a stored-XSS
 * vector against that other session, not just a self-inflicted risk.
 */
window.dreamLook.escapeHtml = function escapeHtml(str) {
  if (str === null || str === undefined) return '';
  const div = document.createElement('div');
  div.textContent = String(str);
  return div.innerHTML;
};

window.dreamLook.isValidPhone = function isValidPhone(value) {
  return /^[0-9+()\-\s]{7,15}$/.test(value.trim());
};

/**
 * Toggle a submit button into/out of a "loading" state.
 * @param {HTMLButtonElement} btn
 * @param {boolean} isLoading
 * @param {string} loadingText
 */
window.dreamLook.setButtonLoading = function setButtonLoading(btn, isLoading, loadingText = 'Please wait…') {
  if (!btn) return;

  if (isLoading) {
    btn.dataset.originalText = btn.dataset.originalText || btn.textContent;
    btn.textContent = loadingText;
    btn.disabled = true;
  } else {
    btn.textContent = btn.dataset.originalText || btn.textContent;
    btn.disabled = false;
  }
};

/** Fades out the full-page loader once the page is ready. */
window.dreamLook.hidePageLoader = function hidePageLoader() {
  const loader = document.getElementById('dl-page-loader');
  if (!loader) return;
  loader.classList.add('is-hidden');
  setTimeout(() => loader.remove(), 300);
};

document.addEventListener('DOMContentLoaded', () => {
  window.dreamLook.hidePageLoader();
});
