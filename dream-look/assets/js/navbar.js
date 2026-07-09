/**
 * Dream Look — Navbar Component
 * -----------------------------------------------------------------------
 * Renders the navbar into <div id="dl-navbar"></div>, which must exist at
 * the top of <body> on every page. Keeping the navbar in one JS file means
 * a nav-link change only has to be made once across the whole site.
 *
 * The current page is read from <body data-page="home"> so the matching
 * link can get the `is-active` class.
 * -----------------------------------------------------------------------
 */

(function navbarComponent() {
  const NAV_LINKS = [
    { page: 'home', label: 'Home', href: 'index.html' },
    { page: 'about', label: 'About', href: 'about.html' },
    { page: 'contact', label: 'Contact', href: 'contact.html' },
  ];

  function linkMarkup(currentPage) {
    return NAV_LINKS.map((link) => {
      const activeClass = link.page === currentPage ? ' is-active' : '';
      return `<a href="${link.href}" class="${activeClass.trim()}">${link.label}</a>`;
    }).join('');
  }

  function render(currentPage) {
    const mount = document.getElementById('dl-navbar');
    if (!mount) return;

    mount.innerHTML = `
      <nav class="navbar">
        <div class="navbar__inner">
          <a href="index.html" class="navbar__logo">
            <span class="navbar__logo-mark">DL</span>
            Dream Look
          </a>

          <button class="navbar__toggle" id="dl-nav-toggle" aria-label="Toggle menu" aria-expanded="false">
            <span></span><span></span><span></span>
          </button>

          <div class="navbar__links" id="dl-nav-links">
            ${linkMarkup(currentPage)}
            <a href="book-slot.html" class="${currentPage === 'book-slot' ? 'is-active' : ''}">Book Slot</a>
            <div class="navbar__cta" id="dl-nav-cta">
              <a href="login.html" class="btn btn--primary btn--sm">Login</a>
            </div>
          </div>
        </div>
      </nav>
      <div class="navbar__overlay" id="dl-nav-overlay"></div>
    `;

    wireMobileToggle();
    wireAuthState();
  }

  function wireMobileToggle() {
    const toggle = document.getElementById('dl-nav-toggle');
    const links = document.getElementById('dl-nav-links');
    const overlay = document.getElementById('dl-nav-overlay');

    function close() {
      toggle.classList.remove('is-open');
      links.classList.remove('is-open');
      overlay.classList.remove('is-open');
      toggle.setAttribute('aria-expanded', 'false');
    }

    function open() {
      toggle.classList.add('is-open');
      links.classList.add('is-open');
      overlay.classList.add('is-open');
      toggle.setAttribute('aria-expanded', 'true');
    }

    toggle.addEventListener('click', () => {
      const isOpen = links.classList.contains('is-open');
      isOpen ? close() : open();
    });

    overlay.addEventListener('click', close);
    links.querySelectorAll('a').forEach((a) => a.addEventListener('click', close));
  }

  /** Swaps the "Login" CTA for "Dashboard / Logout" when a session exists. */
  async function wireAuthState() {
    if (!window.dreamLook || !window.dreamLook.auth) return;

    const { session } = await window.dreamLook.auth.getSession();
    const cta = document.getElementById('dl-nav-cta');
    if (!cta) return;

    if (session) {
      cta.innerHTML = `
        <a href="dashboard.html" class="btn btn--outline btn--sm">Dashboard</a>
        <button id="dl-logout-btn" class="btn btn--primary btn--sm">Logout</button>
      `;
      document.getElementById('dl-logout-btn').addEventListener('click', async () => {
        await window.dreamLook.auth.signOut();
        window.location.href = 'index.html';
      });
    }
  }

  document.addEventListener('DOMContentLoaded', () => {
    const currentPage = document.body.dataset.page || '';
    render(currentPage);
  });
})();
