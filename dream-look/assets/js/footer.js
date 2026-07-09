/**
 * Dream Look — Footer Component
 * Renders into <div id="dl-footer"></div>, present at the bottom of every page.
 */

(function footerComponent() {
  function render() {
    const mount = document.getElementById('dl-footer');
    if (!mount) return;

    const year = new Date().getFullYear();

    mount.innerHTML = `
      <footer class="footer">
        <div class="footer__inner">
          <div class="footer__col">
            <div class="footer__brand">
              <span class="footer__brand-mark">DL</span>
              Dream Look
            </div>
            <p class="footer__tagline">A modern barber studio for precise cuts, sharp fades and honest grooming, in the heart of the city.</p>
          </div>

          <div class="footer__col">
            <h4>Explore</h4>
            <ul>
              <li><a href="index.html">Home</a></li>
              <li><a href="about.html">About</a></li>
              <li><a href="book-slot.html">Book Slot</a></li>
              <li><a href="contact.html">Contact</a></li>
            </ul>
          </div>

          <div class="footer__col">
            <h4>Account</h4>
            <ul>
              <li><a href="login.html">Login</a></li>
              <li><a href="signup.html">Sign Up</a></li>
              <li><a href="dashboard.html">Dashboard</a></li>
              <li><a href="admin-login.html">Admin</a></li>
            </ul>
          </div>

          <div class="footer__col">
            <h4>Visit Us</h4>
            <ul>
              <li>21 Marigold Street, Camp Area</li>
              <li>Indore, Madhya Pradesh</li>
              <li>+91 90000 00000</li>
              <li>hello@dreamlook.studio</li>
            </ul>
          </div>
        </div>

        <div class="container footer__bottom">
          <span>&copy; ${year} Dream Look. All rights reserved.</span>
          <span>Crafted with precision, styled with gold. · v1.0.0</span>
        </div>
      </footer>
    `;
  }

  document.addEventListener('DOMContentLoaded', render);
})();
