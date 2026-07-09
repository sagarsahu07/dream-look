/**
 * Dream Look — Profile Page Logic
 */

(function profilePage() {
  document.addEventListener('DOMContentLoaded', async () => {
    const session = await window.dreamLook.auth.requireAuth();
    if (!session) return;

    const form = document.getElementById('profile-form');
    const alertBox = document.getElementById('profile-alert');
    const submitBtn = document.getElementById('profile-submit');
    const logoutBtn = document.getElementById('profile-logout');

    const avatarEl = document.getElementById('profile-avatar');
    const nameHeaderEl = document.getElementById('profile-name-header');
    const emailHeaderEl = document.getElementById('profile-email-header');

    const nameInput = document.getElementById('profile-name');
    const emailInput = document.getElementById('profile-email');
    const phoneInput = document.getElementById('profile-phone');

    const { data: profile, error } = await window.dreamLook.auth.getCurrentUserProfile();

    if (error) {
      window.dreamLook.showToast('Could not load your profile.', 'error');
    }

    const fullName = profile ? profile.full_name : '';
    const email = profile ? profile.email : session.user.email;
    const phone = profile ? profile.phone : '';

    nameInput.value = fullName || '';
    emailInput.value = email || '';
    phoneInput.value = phone || '';

    nameHeaderEl.textContent = fullName || 'Your Profile';
    emailHeaderEl.textContent = email || '';
    avatarEl.textContent = (fullName || email || '?').trim().charAt(0).toUpperCase();

    if (profile) {
      document.getElementById('loyalty-card').style.display = 'block';
      document.getElementById('loyalty-tier').textContent = profile.membership_tier || 'standard';
      document.getElementById('loyalty-points').textContent = profile.loyalty_points || 0;
      document.getElementById('loyalty-visits').textContent = profile.visit_count || 0;
    }

    form.addEventListener('submit', async (e) => {
      e.preventDefault();
      window.dreamLook.clearFormErrors(form);
      alertBox.classList.remove('is-visible');

      const newName = nameInput.value.trim();
      const newPhone = phoneInput.value.trim();

      let hasError = false;

      if (newName.length < 2) {
        window.dreamLook.setFieldError('profile-name', 'Enter your full name.');
        hasError = true;
      }

      if (newPhone && !window.dreamLook.isValidPhone(newPhone)) {
        window.dreamLook.setFieldError('profile-phone', 'Enter a valid phone number.');
        hasError = true;
      }

      if (hasError) return;

      window.dreamLook.setButtonLoading(submitBtn, true, 'Saving…');

      const { error: updateError } = await window.dreamLook.supabase
        .from('users')
        .update({ full_name: newName, phone: newPhone || null })
        .eq('id', session.user.id);

      window.dreamLook.setButtonLoading(submitBtn, false);

      if (updateError) {
        alertBox.textContent = updateError.message || 'Unable to save changes. Please try again.';
        alertBox.classList.add('is-visible');
        return;
      }

      nameHeaderEl.textContent = newName;
      avatarEl.textContent = newName.charAt(0).toUpperCase();
      window.dreamLook.showToast('Profile updated.', 'success');
    });

    logoutBtn.addEventListener('click', async () => {
      await window.dreamLook.auth.signOut();
      window.location.href = 'index.html';
    });
  });
})();
