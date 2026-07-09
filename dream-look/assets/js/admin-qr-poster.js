/**
 * Dream Look — Admin QR Poster Logic
 * -----------------------------------------------------------------------
 * The QR always encodes the permanent booking URL (book-slot.html), not a
 * specific booking — this is the "walk in without the link" QR, distinct
 * from the per-booking QR on booking-success.html (which opens
 * admin-scan.html for that one appointment).
 * -----------------------------------------------------------------------
 */

(function adminQrPosterPage() {
  const BOOKING_URL = `${window.location.origin}/book-slot.html`;

  document.addEventListener('DOMContentLoaded', async () => {
    const admin = await window.dreamLook.auth.requireAdmin();
    if (!admin) return;

    document.getElementById('qr-url-label').textContent = BOOKING_URL.replace(/^https?:\/\//, '');

    await renderQrCanvas(220);

    document.getElementById('size-counter-btn').addEventListener('click', () => setSize('counter'));
    document.getElementById('size-wall-btn').addEventListener('click', () => setSize('wall'));
    document.getElementById('print-poster-btn').addEventListener('click', () => window.print());
    document.getElementById('download-png-btn').addEventListener('click', downloadPng);
    document.getElementById('download-svg-btn').addEventListener('click', downloadSvg);
  });

  async function renderQrCanvas(pixelSize) {
    const canvas = document.getElementById('qr-canvas');
    // High resolution: render well above display size so print/PNG stay crisp.
    await window.QRCode.toCanvas(canvas, BOOKING_URL, {
      width: pixelSize,
      margin: 1,
      color: { dark: '#0b0b0b', light: '#ffffff' },
    });
  }

  function setSize(size) {
    const poster = document.getElementById('qr-poster');
    const counterBtn = document.getElementById('size-counter-btn');
    const wallBtn = document.getElementById('size-wall-btn');

    if (size === 'wall') {
      poster.classList.add('qr-poster--wall');
      wallBtn.classList.replace('btn--outline-dark', 'btn--dark');
      counterBtn.classList.replace('btn--dark', 'btn--outline-dark');
      renderQrCanvas(320);
    } else {
      poster.classList.remove('qr-poster--wall');
      counterBtn.classList.replace('btn--outline-dark', 'btn--dark');
      wallBtn.classList.replace('btn--dark', 'btn--outline-dark');
      renderQrCanvas(220);
    }
  }

  function downloadPng() {
    const canvas = document.getElementById('qr-canvas');
    const link = document.createElement('a');
    link.download = 'dream-look-booking-qr.png';
    link.href = canvas.toDataURL('image/png');
    link.click();
  }

  async function downloadSvg() {
    const svgString = await window.QRCode.toString(BOOKING_URL, {
      type: 'svg',
      margin: 1,
      color: { dark: '#0b0b0b', light: '#ffffff' },
    });

    const blob = new Blob([svgString], { type: 'image/svg+xml' });
    const url = URL.createObjectURL(blob);
    const link = document.createElement('a');
    link.download = 'dream-look-booking-qr.svg';
    link.href = url;
    link.click();
    URL.revokeObjectURL(url);
  }
})();
