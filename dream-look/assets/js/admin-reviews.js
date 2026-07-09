/**
 * Dream Look — Admin Reviews Logic
 */

(function adminReviewsPage() {
  document.addEventListener('DOMContentLoaded', async () => {
    const admin = await window.dreamLook.auth.requireAdmin();
    if (!admin) return;
    await loadReviews();
  });

  async function loadReviews() {
    const listEl = document.getElementById('reviews-list');
    const { data, error } = await window.dreamLook.supabase
      .from('reviews')
      .select('id, rating, comment, admin_reply, admin_reply_at, created_at, bookings(booking_date, services(name), users(full_name))')
      .order('created_at', { ascending: false });

    if (error) {
      listEl.innerHTML = '<p class="field-hint">Could not load reviews.</p>';
      return;
    }

    if (!data || data.length === 0) {
      listEl.innerHTML = '<p class="field-hint">No reviews yet.</p>';
      return;
    }

    listEl.innerHTML = data.map((r) => `
      <div class="review-card" data-review-id="${r.id}">
        <div class="review-card__header">
          <div>
            <div class="review-stars">${'★'.repeat(r.rating)}${'☆'.repeat(5 - r.rating)}</div>
            <div class="review-card__meta">
              ${r.bookings?.users?.full_name || 'Customer'} · ${r.bookings?.services?.name || ''} · ${new Date(r.created_at).toLocaleDateString('en-IN')}
            </div>
          </div>
        </div>
        ${r.comment ? `<div class="review-card__comment">"${window.dreamLook.escapeHtml(r.comment)}"</div>` : ''}
        ${r.admin_reply ? `
          <div class="review-reply">
            <div class="review-reply__label">Owner Reply</div>
            ${window.dreamLook.escapeHtml(r.admin_reply)}
          </div>
        ` : `
          <div class="review-reply-form">
            <textarea placeholder="Write a reply…" id="reply-input-${r.id}"></textarea>
            <button type="button" class="btn btn--dark btn--sm" data-reply-btn="${r.id}">Reply</button>
          </div>
        `}
      </div>
    `).join('');

    listEl.querySelectorAll('[data-reply-btn]').forEach((btn) => {
      btn.addEventListener('click', () => submitReply(btn.dataset.replyBtn));
    });
  }

  async function submitReply(reviewId) {
    const input = document.getElementById(`reply-input-${reviewId}`);
    const btn = document.querySelector(`[data-reply-btn="${reviewId}"]`);
    const text = input.value.trim();

    if (text.length < 2) {
      window.dreamLook.showToast('Write a reply first.', 'error');
      return;
    }

    window.dreamLook.setButtonLoading(btn, true, 'Saving…');
    const { error } = await window.dreamLook.supabase.rpc('admin_reply_review', {
      p_review_id: reviewId,
      p_reply: text,
    });
    window.dreamLook.setButtonLoading(btn, false);

    if (error) {
      window.dreamLook.showToast(error.message || 'Could not save reply.', 'error');
      return;
    }

    window.dreamLook.showToast('Reply posted.', 'success');
    await loadReviews();
  }
})();
