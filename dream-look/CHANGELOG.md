# Changelog

All notable changes to Dream Look are documented in this file.

## [1.0.0] — Release Candidate 1 (RC1)

### Added
- **Phase 1 — Foundation**: folder structure, Supabase connection, email auth (login/signup/forgot-password/logout), route guards, database schema (`users`, `services`, `bookings`, `payments`, `admin_profiles`) with RLS, every public/customer UI page (Home, About, Contact, Login, Signup, Forgot Password, Dashboard, Book Slot, Profile, Admin Login).
- **Phase 2 — Booking Engine & Queue**: live slot availability (shop hours, buffer time), automatic queue numbering, `create_booking`/`cancel_booking`/`reschedule_booking` RPCs, DB-level overlap prevention (`EXCLUDE` constraint), configurable shop settings, multi-barber architecture, holidays/weekly-off, no-show auto-expiry, audit log, Realtime slot refresh and queue updates.
- **Phase 3 — Admin Panel**: dashboard stats, queue management (call next / mark arrived / start service / complete / no-show), walk-in customers, service/barber CRUD, shop settings UI, customer search, reports (daily/weekly/monthly/revenue/popular services), read-only audit log, all Realtime.
- **Phase 4 — Payments, Notifications, Receipts**: Razorpay (card/UPI/netbanking) + Cash payments with server-side signature verification, unique transaction IDs, booking-success/receipt page with QR code and PDF/print, reviews (1–5 stars + admin reply), loyalty (points/visits/tiers), email/WhatsApp/SMS notification architecture via Edge Functions, 404/500 pages, offline banner.
- **Phase 5 — Google Auth, Multi-Service Booking, Smart Allocation, QR Poster**: one-click Google sign-in/sign-up; customers can select multiple services in one booking with automatic combined price/duration; booking creation now automatically reassigns to the next available barber/time slot if a race condition takes the requested one first, instead of simply rejecting; a permanent, printable QR poster (counter/wall sizes, PNG/SVG) linking straight to the booking page.

### Fixed
- **Critical**: two functions (`get_available_slots`, `create_booking`) had accumulated duplicate signatures across earlier migrations, which made PostgREST unable to resolve which to call — booking creation and slot lookups were unreachable until this was fixed (migration 007).
- **Critical (security)**: stored XSS — customer-controlled `full_name` was rendered unescaped in two admin-facing views (queue table, customer search), a genuine attack vector against the admin session. Fixed with a shared HTML-escaping helper applied everywhere user text renders via `innerHTML`.
- Revenue reporting previously assumed every completed booking was paid for (price × count); now reflects actual verified payments.
- Admin "Cancel" now goes through an audited RPC instead of a raw table update.
- Two SQL migrations (003, 004) that added new enum values were fragile if pasted as one script; split into their own standalone files (003a, 004a) so they can never fail on a straight copy-paste.
- Service-id array de-duplication bug (a harmless duplicate ID in a multi-service selection was incorrectly rejected).
- Payment-amount fallback bug that could misfire for a legitimately free (₹0) multi-service combination.
- Missing explicit privilege grant on a helper function (`is_barber_slot_free`), inconsistent with the project's least-privilege pattern.
- Dead-weight ~400KB of unused QR/PDF library loading on the dashboard page.
- Missing `noindex` tags on 8 authenticated/utility pages.
- Duplicate CSS (`status-badge` system existed in two files, was actually missing from two pages that needed it — booking-success and admin-scan — causing unstyled badges there).

### Removed (code cleanup, RC1)
- Unused `fetchActiveBarbers()` helper (no page ever called it).
- Unused CSS: `.notice-banner`, `.gold-divider`, `.text-gold`, and the entire unused skeleton-loading rule set.
- Duplicate `escapeHtml()` implementations (consolidated to one shared helper in `utils.js`).

### Security
- Every payment can only be marked "paid" by the `service_role`-only `verify-razorpay-payment` Edge Function after independently verifying Razorpay's cryptographic signature — never by the client.
- RLS enabled and reviewed on every table; every admin RPC self-checks `is_admin()`.
- Customer search filter hardened against malformed input.

### Migration Notes
Run all 11 files in `sql/` in the exact order listed in `README.md`. Two are standalone single-statement files (`003a`, `004a`) that must run as their own query, not pasted together with the surrounding migration — this is a hard PostgreSQL requirement (a new enum value can't be used in the same transaction that creates it), not a style preference.

### Breaking Changes
None for a fresh install. If you already ran migrations 002–007 in a prior environment before 008/009 existed, note that `create_booking` and `get_available_slots` changed from a single `service_id` parameter to a `service_id[]` array — any external code calling these RPCs directly (outside this project's own frontend) needs updating to pass an array.
