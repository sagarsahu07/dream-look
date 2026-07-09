/**
 * Dream Look — Signup Page Logic
 */

(function signupPage() {
  document.addEventListener('DOMContentLoaded', async () => {
    await window.dreamLook.auth.requireGuest();

    const form = document.getElementById('signup-form');
    const alertBox = document.getElementById('signup-alert');
    const submitBtn = document.getElementById('signup-submit');
    const googleBtn = document.getElementById('google-signup-btn');

    googleBtn.addEventListener('click', async () => {
      window.dreamLook.setButtonLoading(googleBtn, true, 'Redirecting to Google…');
      const { error } = await window.dreamLook.auth.signInWithGoogle();
      if (error) {
        window.dreamLook.setButtonLoading(googleBtn, false);
        alertBox.textContent = error.message || 'Could not start Google sign-up.';
        alertBox.classList.add('is-visible');
      }
    });

    form.addEventListener('submit', async (e) => {
      e.preventDefault();
      window.dreamLook.clearFormErrors(form);
      alertBox.classList.remove('is-visible');

      const fullName = document.getElementById('signup-name').value.trim();
      const email = document.getElementById('signup-email').value.trim();
      const phone = document.getElementById('signup-phone').value.trim();
      const password = document.getElementById('signup-password').value;
      const confirmPassword = document.getElementById('signup-confirm-password').value;

      let hasError = false;

      if (fullName.length < 2) {
        window.dreamLook.setFieldError('signup-name', 'Enter your full name.');
        hasError = true;
      }

      if (!window.dreamLook.isValidEmail(email)) {
        window.dreamLook.setFieldError('signup-email', 'Enter a valid email address.');
        hasError = true;
      }

      if (phone && !window.dreamLook.isValidPhone(phone)) {
        window.dreamLook.setFieldError('signup-phone', 'Enter a valid phone number.');
        hasError = true;
      }

      if (password.length < 8) {
        window.dreamLook.setFieldError('signup-password', 'Password must be at least 8 characters.');
        hasError = true;
      }

      if (confirmPassword !== password) {
        window.dreamLook.setFieldError('signup-confirm-password', 'Passwords do not match.');
        hasError = true;
      }

      if (hasError) return;

      window.dreamLook.setButtonLoading(submitBtn, true, 'Creating account…');

      const { data, error } = await window.dreamLook.auth.signUp({
        fullName,
        email,
        phone,
        password,
      });

      window.dreamLook.setButtonLoading(submitBtn, false);

      if (error) {
        alertBox.textContent = error.message || 'Unable to create your account. Please try again.';
        alertBox.classList.add('is-visible');
        return;
      }

      if (data && data.user && !data.session) {
        alertBox.classList.remove('form-alert--error');
        alertBox.classList.add('form-alert--success', 'is-visible');
        alertBox.textContent = 'Account created! Check your email to confirm your address before logging in.';
        form.reset();
        return;
      }

      window.dreamLook.showToast('Account created successfully!', 'success');
      window.location.href = 'dashboard.html';
    });
  });
})();
