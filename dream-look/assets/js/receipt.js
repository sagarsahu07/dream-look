/**
 * Dream Look — Receipt Module
 * -----------------------------------------------------------------------
 * Shared between booking-success.html (right after booking) and
 * dashboard.html (re-downloading a past receipt). Depends on two CDN
 * libraries the host page must include before this script:
 *   - qrcode@1.5.3   (window.QRCode.toCanvas)
 *   - jspdf@2.5.1     (window.jspdf.jsPDF)
 * -----------------------------------------------------------------------
 */

window.dreamLook = window.dreamLook || {};

window.dreamLook.receipt = (function receiptModule() {
  /** Renders a QR code onto a <canvas>. Encodes a URL admin-scan.html can open directly. */
  async function renderQr(canvasEl, bookingId) {
    if (!window.QRCode) {
      console.error('QRCode library not loaded.');
      return;
    }
    const url = `${window.location.origin}/admin-scan.html?booking=${bookingId}`;
    await window.QRCode.toCanvas(canvasEl, url, {
      width: 180,
      margin: 1,
      color: { dark: '#0b0b0b', light: '#ffffff' },
    });
  }

  function statusLabel(status) {
    return status ? status.replace(/_/g, ' ') : '—';
  }

  /** Triggers the browser print dialog — the host page's print.css controls what's visible. */
  function printReceipt() {
    window.print();
  }

  /** Builds and downloads a branded one-page PDF invoice using jsPDF. */
  function downloadPdf(receipt) {
    if (!window.jspdf) {
      console.error('jsPDF library not loaded.');
      return;
    }

    const { jsPDF } = window.jspdf;
    const doc = new jsPDF({ unit: 'pt', format: 'a4' });
    const gold = [212, 175, 55];
    const black = [11, 11, 11];
    const gray = [107, 107, 107];
    let y = 60;

    doc.setFillColor(...black);
    doc.rect(0, 0, 595, 90, 'F');
    doc.setTextColor(255, 255, 255);
    doc.setFont('helvetica', 'bold');
    doc.setFontSize(20);
    doc.text('Dream Look', 40, 50);
    doc.setFontSize(10);
    doc.setTextColor(...gold);
    doc.text('PREMIUM BARBER STUDIO', 40, 68);

    y = 130;
    doc.setTextColor(...black);
    doc.setFontSize(16);
    doc.setFont('helvetica', 'bold');
    doc.text('Booking Receipt', 40, y);

    y += 10;
    doc.setDrawColor(...gold);
    doc.setLineWidth(1.5);
    doc.line(40, y, 130, y);

    y += 30;
    doc.setFont('helvetica', 'normal');
    doc.setFontSize(11);
    doc.setTextColor(...gray);

    const rows = [
      ['Booking ID', receipt.booking_id],
      ['Customer', receipt.customer_name || '—'],
      ['Service', receipt.service_name || '—'],
      ['Barber', receipt.barber_name || '—'],
      ['Date', window.dreamLook.booking.formatDate(receipt.booking_date)],
      ['Time', window.dreamLook.booking.formatTime12h(receipt.start_time)],
      ['Status', statusLabel(receipt.status)],
      ['Queue Number', receipt.queue_number ? `#${receipt.queue_number}` : '—'],
      ['Payment Status', statusLabel(receipt.payment_status)],
      ['Payment Method', receipt.payment_method || '—'],
      ['Transaction ID', receipt.transaction_id || '—'],
    ];

    rows.forEach(([label, value]) => {
      doc.setTextColor(...gray);
      doc.text(label, 40, y);
      doc.setTextColor(...black);
      doc.text(String(value), 250, y);
      y += 22;
    });

    y += 10;
    doc.setDrawColor(230, 230, 230);
    doc.line(40, y, 555, y);
    y += 30;

    doc.setFont('helvetica', 'bold');
    doc.setFontSize(13);
    doc.setTextColor(...black);
    doc.text('Amount', 40, y);
    doc.setTextColor(...gold);
    doc.text(`Rs. ${Number(receipt.amount || receipt.service_price || 0).toFixed(0)}`, 250, y);

    y += 60;
    doc.setFont('helvetica', 'normal');
    doc.setFontSize(9);
    doc.setTextColor(...gray);
    doc.text('Dream Look, 21 Marigold Street, Camp Area, Indore, Madhya Pradesh', 40, y);
    doc.text('This is a system-generated receipt.', 40, y + 14);

    doc.save(`dream-look-receipt-${receipt.booking_id}.pdf`);
  }

  return { renderQr, printReceipt, downloadPdf, statusLabel };
})();
