/**
 * Dream Look — Login Page Logic
 */

(function loginPage() {
  document.addEventListener('DOMContentLoaded', async () => {
    await window.dreamLook.auth.requireGuest();

    const form = document.getElementById('login-form');
    const alertBox = document.getElementById('login-alert');
    const submitBtn = document.getElementById('login-submit');
    const googleBtn = document.getElementById('google-login-btn');

    googleBtn.addEventListener('click', async () => {
      window.dreamLook.setButtonLoading(googleBtn, true, 'Redirecting to Google…');
      const { error } = await window.dreamLook.auth.signInWithGoogle();
      if (error) {
        window.dreamLook.setButtonLoading(googleBtn, false);
        alertBox.textContent = error.message || 'Could not start Google sign-in.';
        alertBox.classList.add('is-visible');
      }
      // On success the browser navigates away to Google — nothing else to do here.
    });

    form.addEventListener('submit', async (e) => {
      e.preventDefault();
      window.dreamLook.clearFormErrors(form);
      alertBox.classList.remove('is-visible');

      const email = document.getElementById('login-email').value.trim();
      const password = document.getElementById('login-password').value;

      let hasError = false;

      if (!window.dreamLook.isValidEmail(email)) {
        window.dreamLook.setFieldError('login-email', 'Enter a valid email address.');
        hasError = true;
      }

      if (!password) {
        window.dreamLook.setFieldError('login-password', 'Enter your password.');
        hasError = true;
      }

      if (hasError) return;

      window.dreamLook.setButtonLoading(submitBtn, true, 'Logging in…');

      const { error } = await window.dreamLook.auth.signIn({ email, password });

      window.dreamLook.setButtonLoading(submitBtn, false);

      if (error) {
        alertBox.textContent = error.message || 'Unable to log in. Please try again.';
        alertBox.classList.add('is-visible');
        return;
      }

      window.dreamLook.showToast('Welcome back!', 'success');
      window.location.href = 'dashboard.html';
    });
  });
})();
