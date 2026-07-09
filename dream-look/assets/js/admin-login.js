/**
 * Dream Look — Admin Login Page Logic
 * Signs the user in, then confirms public.users.role = 'admin' before
 * granting access. Non-admins are signed back out immediately.
 */

(function adminLoginPage() {
  document.addEventListener('DOMContentLoaded', () => {
    const form = document.getElementById('admin-login-form');
    const alertBox = document.getElementById('admin-login-alert');
    const submitBtn = document.getElementById('admin-login-submit');

    form.addEventListener('submit', async (e) => {
      e.preventDefault();
      window.dreamLook.clearFormErrors(form);
      alertBox.classList.remove('is-visible');

      const email = document.getElementById('admin-email').value.trim();
      const password = document.getElementById('admin-password').value;

      let hasError = false;

      if (!window.dreamLook.isValidEmail(email)) {
        window.dreamLook.setFieldError('admin-email', 'Enter a valid email address.');
        hasError = true;
      }

      if (!password) {
        window.dreamLook.setFieldError('admin-password', 'Enter your password.');
        hasError = true;
      }

      if (hasError) return;

      window.dreamLook.setButtonLoading(submitBtn, true, 'Verifying…');

      const { error: signInError } = await window.dreamLook.auth.signIn({ email, password });

      if (signInError) {
        window.dreamLook.setButtonLoading(submitBtn, false);
        alertBox.textContent = signInError.message || 'Unable to log in. Please try again.';
        alertBox.classList.add('is-visible');
        return;
      }

      const { data: profile, error: profileError } = await window.dreamLook.auth.getCurrentUserProfile();

      window.dreamLook.setButtonLoading(submitBtn, false);

      if (profileError || !profile || profile.role !== 'admin') {
        await window.dreamLook.auth.signOut();
        alertBox.textContent = 'This account does not have admin access.';
        alertBox.classList.add('is-visible');
        return;
      }

      window.dreamLook.showToast('Welcome back, admin.', 'success');
      window.location.href = 'admin-dashboard.html';
    });
  });
})();
