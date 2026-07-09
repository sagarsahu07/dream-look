/**
 * Dream Look — Contact Page Logic
 * -----------------------------------------------------------------------
 * Validates the form client-side. This phase's schema does not include a
 * messages/enquiries table, so submissions are not yet persisted — wiring
 * this form to Supabase is a natural addition in a later phase.
 * -----------------------------------------------------------------------
 */

(function contactPage() {
  document.addEventListener('DOMContentLoaded', () => {
    const form = document.getElementById('contact-form');
    if (!form) return;

    const submitBtn = document.getElementById('contact-submit');

    form.addEventListener('submit', (e) => {
      e.preventDefault();
      window.dreamLook.clearFormErrors(form);

      const name = document.getElementById('contact-name').value.trim();
      const email = document.getElementById('contact-email').value.trim();
      const message = document.getElementById('contact-message').value.trim();

      let hasError = false;

      if (name.length < 2) {
        window.dreamLook.setFieldError('contact-name', 'Enter your name.');
        hasError = true;
      }

      if (!window.dreamLook.isValidEmail(email)) {
        window.dreamLook.setFieldError('contact-email', 'Enter a valid email address.');
        hasError = true;
      }

      if (message.length < 10) {
        window.dreamLook.setFieldError('contact-message', 'Message should be at least 10 characters.');
        hasError = true;
      }

      if (hasError) return;

      window.dreamLook.setButtonLoading(submitBtn, true, 'Sending…');

      setTimeout(() => {
        window.dreamLook.setButtonLoading(submitBtn, false);
        window.dreamLook.showToast('Message sent. We will get back to you soon.', 'success');
        form.reset();
      }, 600);
    });
  });
})();
