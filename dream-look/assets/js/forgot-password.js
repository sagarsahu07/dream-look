/**
 * Dream Look — Forgot Password Page Logic
 * -----------------------------------------------------------------------
 * This single page handles two steps:
 *  1. Request step  — visitor enters their email, we send a reset link.
 *  2. Recovery step — visitor arrives back here via the emailed link,
 *     Supabase opens a temporary "recovery" session, and we show a
 *     "set new password" form instead.
 * -----------------------------------------------------------------------
 */

(function forgotPasswordPage() {
  document.addEventListener('DOMContentLoaded', () => {
    const requestStep = document.getElementById('request-step');
    const recoveryStep = document.getElementById('recovery-step');

    const requestForm = document.getElementById('forgot-form');
    const requestAlert = document.getElementById('forgot-alert');
    const requestSubmit = document.getElementById('forgot-submit');

    const recoveryForm = document.getElementById('recovery-form');
    const recoveryAlert = document.getElementById('recovery-alert');
    const recoverySubmit = document.getElementById('recovery-submit');

    // Supabase fires PASSWORD_RECOVERY when the visitor lands here via the
    // reset-password email link, which contains a recovery token.
    window.dreamLook.supabase.auth.onAuthStateChange((event) => {
      if (event === 'PASSWORD_RECOVERY') {
        requestStep.style.display = 'none';
        recoveryStep.style.display = 'block';
      }
    });

    requestForm.addEventListener('submit', async (e) => {
      e.preventDefault();
      window.dreamLook.clearFormErrors(requestForm);
      requestAlert.classList.remove('is-visible');

      const email = document.getElementById('forgot-email').value.trim();

      if (!window.dreamLook.isValidEmail(email)) {
        window.dreamLook.setFieldError('forgot-email', 'Enter a valid email address.');
        return;
      }

      window.dreamLook.setButtonLoading(requestSubmit, true, 'Sending link…');
      const { error } = await window.dreamLook.auth.sendPasswordReset(email);
      window.dreamLook.setButtonLoading(requestSubmit, false);

      if (error) {
        requestAlert.classList.remove('form-alert--success');
        requestAlert.classList.add('form-alert--error', 'is-visible');
        requestAlert.textContent = error.message || 'Unable to send reset link. Please try again.';
        return;
      }

      requestAlert.classList.remove('form-alert--error');
      requestAlert.classList.add('form-alert--success', 'is-visible');
      requestAlert.textContent = 'Reset link sent. Check your inbox for further instructions.';
      requestForm.reset();
    });

    recoveryForm.addEventListener('submit', async (e) => {
      e.preventDefault();
      window.dreamLook.clearFormErrors(recoveryForm);
      recoveryAlert.classList.remove('is-visible');

      const newPassword = document.getElementById('recovery-password').value;
      const confirmPassword = document.getElementById('recovery-confirm-password').value;

      let hasError = false;

      if (newPassword.length < 8) {
        window.dreamLook.setFieldError('recovery-password', 'Password must be at least 8 characters.');
        hasError = true;
      }

      if (confirmPassword !== newPassword) {
        window.dreamLook.setFieldError('recovery-confirm-password', 'Passwords do not match.');
        hasError = true;
      }

      if (hasError) return;

      window.dreamLook.setButtonLoading(recoverySubmit, true, 'Updating…');
      const { error } = await window.dreamLook.auth.updatePassword(newPassword);
      window.dreamLook.setButtonLoading(recoverySubmit, false);

      if (error) {
        recoveryAlert.classList.remove('form-alert--success');
        recoveryAlert.classList.add('form-alert--error', 'is-visible');
        recoveryAlert.textContent = error.message || 'Unable to update password. Please try again.';
        return;
      }

      window.dreamLook.showToast('Password updated. Please log in.', 'success');
      window.location.href = 'login.html';
    });
  });
})();
