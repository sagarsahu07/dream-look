# Dream Look — Barber Shop Booking Website

**Version: v1.0.0 (Release Candidate 1)** — see `CHANGELOG.md` and `RELEASE_NOTES.md`.

A production-ready barber shop booking platform: authentication, a real
booking engine with live queue management, a full admin panel, payments
(Razorpay/Cash/UPI), notifications, reviews, loyalty, and receipts —
built as a plain HTML/CSS/vanilla-JS frontend on Supabase (Postgres + Auth +
Realtime + Edge Functions), deployable to Vercel with zero build step.

## Tech Stack

- **Frontend:** HTML5, CSS3, Vanilla JavaScript (no framework, no build step)
- **Backend:** Supabase (Auth, Postgres, Row Level Security, Realtime, Edge Functions)
- **Payments:** Razorpay (cards, UPI, netbanking) + Cash-at-shop
- **Notifications:** Email (Resend), WhatsApp (Meta Cloud API), SMS (Twilio — future-ready)
- **Hosting:** Vercel (static site) + Supabase Edge Functions (Deno)

## Folder Structure

```
dream-look/
├── index.html, about.html, contact.html          Public pages
├── login.html, signup.html, forgot-password.html Customer auth
├── admin-login.html, admin-dashboard.html         Admin auth + panel
├── admin-scan.html, admin-reviews.html             Standalone admin utilities (QR lookup, review replies)
├── dashboard.html, profile.html, book-slot.html    Customer area
├── booking-success.html                            Receipt / payment / QR page
├── 404.html, 500.html                              Status pages
├── vercel.json, .env.example, README.md
├── assets/
│   ├── css/            One stylesheet per page/concern (see below)
│   ├── js/              One script per page/concern (see below)
│   ├── images/, icons/
├── sql/                 Migrations, run in order (see Database Migrations)
└── supabase/functions/   Edge Functions for payments + notifications
```

### CSS files
`variables.css` (design tokens) → `reset.css` → `style.css` (global) are
loaded on every page, then a page-specific stylesheet: `navbar.css`,
`footer.css`, `home.css`, `auth.css`, `dashboard.css`, `book-slot.css`,
`profile.css`, `contact.css`, `about.css`, `admin-dashboard.css`,
`booking-success.css`, `reviews.css`, `feedback.css` (status pages,
skeletons, offline banner).

### JS files
Shared modules, loaded in this order before any page-specific script:
`config.js` → `supabaseClient.js` → `utils.js` → `auth.js` → `booking.js`
→ `receipt.js` (where needed) → `navbar.js` → `footer.js` →
`offline-banner.js` (where wired in) → the page's own script (`login.js`,
`dashboard.js`, `book-slot.js`, `booking-success.js`,
`admin-dashboard.js`, `admin-scan.js`, `admin-reviews.js`, etc).

### Edge Functions (`supabase/functions/`)
- `create-razorpay-order` — creates a Razorpay order server-side (holds the secret key)
- `verify-razorpay-payment` — verifies the payment signature; the ONLY path that can mark a payment paid
- `send-booking-email` — sends confirmation/cancellation/reschedule/reminder/payment emails
- `send-whatsapp`, `send-sms` — standalone future-ready notification senders
- `_shared/` — CORS headers, notification senders, email templates

## Database Migrations

Run these in **Supabase → SQL Editor**, in this exact order, each one fully
before starting the next — **each file must be run as its own separate
query**, not pasted all together, since a few steps (adding new enum
values) must commit on their own before later files can reference them:

| File | Adds |
|---|---|
| `sql/schema.sql` | Core tables (`users`, `services`, `bookings`, `payments`, `admin_profiles`), RLS, seed services |
| `sql/002_booking_engine.sql` | Booking engine: slot availability, queue numbering, buffer time, `create_booking`/`cancel_booking`/`reschedule_booking` RPCs |
| `sql/003a_add_enum_no_show.sql` | Adds the `no_show` status (own transaction — required before 003) |
| `sql/003_advanced_booking_features.sql` | Multi-barber architecture, `shop_settings`, configurable buffer/weekly-off/holidays, no-show auto-expiry, audit log, Realtime |
| `sql/004a_add_enum_arrived_in_service.sql` | Adds the `arrived`/`in_service` statuses (own transaction — required before 004) |
| `sql/004_admin_panel.sql` | Queue lifecycle, walk-in customers, admin dashboard/report RPCs |
| `sql/005_payments_reviews_loyalty.sql` | Payments (transaction IDs, Razorpay/Cash/UPI), reviews, loyalty points/tiers, notification dispatch infrastructure |
| `sql/006_production_audit_fixes.sql` | Audited bug fixes: admin cancel now audit-logged, revenue reporting now reflects real payments (not assumed price), added indexes |
| `sql/007_fix_function_overloads.sql` | **Critical fix** — removes obsolete duplicate function signatures (`get_available_slots`, `create_booking`) left behind by earlier migrations, which otherwise made booking creation and slot lookups fail |
| `sql/008_multi_service_smart_allocation.sql` | Multi-service bookings (`booking_services`), smart slot allocation with automatic reassignment + race-safe retry on conflict |
| `sql/009_phase5_audit_fixes.sql` | Audited fixes: explicit grant on `is_barber_slot_free`, service-id array de-duplication, corrected free-service (₹0) payment-amount edge case |

Each file's own header comment repeats exactly where it sits in this order.

## 1. Supabase Setup

1. Create a project at [supabase.com](https://supabase.com).
2. Run every file in `sql/` in the order above.
3. **Authentication → Providers** → confirm Email is enabled.
4. **Authentication → URL Configuration** → set **Site URL** and **Redirect
   URLs** to your deployed domain (and `http://localhost:3000` for local dev),
   including `/forgot-password.html`.
5. **Project Settings → API** → copy the **Project URL** and **anon** key.
6. **Database → Extensions** → enable `pg_cron` and `pg_net` if you want
   automatic no-show expiry and appointment reminders (both features degrade
   gracefully to "manual/disabled" if you skip this — nothing breaks).

### Enabling Google Sign-In

1. [Google Cloud Console](https://console.cloud.google.com) → create an OAuth 2.0 Client ID (type: Web application).
2. Add authorized redirect URI: `https://YOUR-PROJECT-REF.supabase.co/auth/v1/callback`.
3. Supabase Dashboard → **Authentication → Providers → Google** → paste the Client ID and Client Secret → enable.
4. That's it — `login.html`/`signup.html` already have a working "Continue with Google" button; no frontend config needed. First-time Google sign-ins get a profile automatically via the same `handle_new_user` trigger email signups use.
5. (Optional) Facebook sign-in: `assets/js/auth.js` already has a `signInWithFacebook()` method ready to wire to a button if you enable the Facebook provider the same way — no button ships by default, to keep the login screen simple.

### Creating your first admin account

Sign up normally at `signup.html` once, then in the SQL Editor:

```sql
update public.users set role = 'admin' where email = 'owner@dreamlook.studio';
insert into public.admin_profiles (user_id, designation)
select id, 'Owner' from public.users where email = 'owner@dreamlook.studio';
```

Log in at `admin-login.html` — you'll land on `admin-dashboard.html`.

## 2. Environment Variables

**Frontend** (no build step, so no `.env` is read by the browser) — edit
`assets/js/config.js` directly:

```js
const DREAM_LOOK_CONFIG = {
  SUPABASE_URL: 'https://YOUR-PROJECT-REF.supabase.co',
  SUPABASE_ANON_KEY: 'YOUR-SUPABASE-ANON-PUBLIC-KEY',
};
```

**Edge Functions** (server-side secrets, never put these in `config.js`) —
set via `supabase secrets set KEY=value` or the Dashboard's Edge Function
secrets UI:

| Secret | Used by | Required for |
|---|---|---|
| `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY` | all functions | Auto-provided by Supabase at deploy time |
| `RAZORPAY_KEY_ID`, `RAZORPAY_KEY_SECRET` | create/verify-razorpay-payment | Card/UPI/netbanking payments |
| `RESEND_API_KEY`, `RESEND_FROM` | send-booking-email | Transactional emails |
| `WHATSAPP_TOKEN`, `WHATSAPP_PHONE_NUMBER_ID` | notify helpers | WhatsApp messages |
| `TWILIO_ACCOUNT_SID`, `TWILIO_AUTH_TOKEN`, `TWILIO_FROM_NUMBER` | notify helpers | SMS (future-ready, optional) |
| `INTERNAL_WEBHOOK_SECRET` | send-booking-email, send-whatsapp, send-sms | Rejects calls that don't carry this shared secret |

Every one of these degrades gracefully if unset — the app never crashes
because a notification provider isn't configured yet, it just skips that
notification and logs why.

See `.env.example` for the frontend values and a note on why the `anon` key
is safe to ship client-side.

## 3. Payment Setup (Razorpay)

1. Create a [Razorpay](https://razorpay.com) account, grab your **Key ID**
   and **Key Secret** from Settings → API Keys.
2. Set them as Edge Function secrets (table above).
3. Deploy the two payment functions (see Edge Function Deployment below).
4. That's it — `booking-success.html` already has the full flow: pick
   Card/UPI/Netbanking or Cash, and Razorpay Checkout opens for the former.
   A payment is only ever marked "Paid" after `verify-razorpay-payment`
   independently verifies Razorpay's cryptographic signature server-side —
   the browser can never set its own payment to Paid.

## 4. Edge Function Deployment

Requires the [Supabase CLI](https://supabase.com/docs/guides/cli).

```bash
supabase login
supabase link --project-ref YOUR-PROJECT-REF

supabase functions deploy create-razorpay-order
supabase functions deploy verify-razorpay-payment
supabase functions deploy send-booking-email
supabase functions deploy send-whatsapp
supabase functions deploy send-sms

supabase secrets set RAZORPAY_KEY_ID=... RAZORPAY_KEY_SECRET=...
supabase secrets set RESEND_API_KEY=... RESEND_FROM="Dream Look <no-reply@yourdomain.com>"
supabase secrets set INTERNAL_WEBHOOK_SECRET=some-long-random-string
```

Then, to turn on automatic emails for booking created/cancelled/rescheduled/
reminder, tell the database where your functions live (SQL Editor):

```sql
update public.notification_settings
set edge_function_base_url = 'https://YOUR-PROJECT-REF.supabase.co/functions/v1',
    internal_secret = 'same-long-random-string-as-INTERNAL_WEBHOOK_SECRET'
where id = 1;
```

Until you run that update, notifications silently no-op — nothing else in
the app depends on them being configured.

## 5. Run Locally

```bash
npx serve .
# or
python3 -m http.server 3000
```

Then open `http://localhost:3000`. (Edge Functions can be run locally with
`supabase functions serve`, or just point `config.js` at your live Supabase
project during development.)

## 6. Production Deployment (Vercel)

1. Push this project to a GitHub repository.
2. [vercel.com](https://vercel.com) → **Add New Project** → import the repo.
3. Framework preset: **Other** — no build command, output directory `.`.
4. Deploy.
5. Back in Supabase, set **Site URL** / **Redirect URLs** to the live domain.
6. Deploy your Edge Functions and set their secrets (steps above) — do this
   before real customers start booking, so payments/emails work from day one.
7. Redeploy on Vercel whenever `assets/js/config.js` changes.

See `PRODUCTION_SETUP.md` for the full pre-launch checklist and
`TESTING_CHECKLIST.md` for a page-by-page, scenario-by-scenario test plan.

## Features Implemented

- **Auth** — email login/signup/forgot-password, Google OAuth (one-click sign-in/up, auto-provisions a profile), route guards, admin role gate
- **Booking Engine** — multi-service selection (checkboxes, combined price/duration), live slot availability (buffer time, shop hours, weekly-off, holidays, per-barber), Smart Slot Allocation (automatic reassignment to the next open barber/time if a race condition takes the requested slot first), no double-booking (DB-level `EXCLUDE` constraint)
- **Queue Management** — automatic queue numbers, live estimated wait,
  full lifecycle (confirmed → arrived → in service → completed/no-show)
- **Customer Dashboard** — upcoming-appointment hero card with a visual
  timeline, live queue/wait via Realtime, cancel/reschedule, booking
  history, receipts, reviews
- **Admin Panel** — dashboard stats, queue management (call next/mark
  arrived/start/complete/no-show), walk-in customers, service/barber CRUD,
  shop settings, customer search, reports (daily/weekly/monthly/custom,
  revenue, popular services), audit log — all Realtime
- **Payments** — Razorpay (card/UPI/netbanking) + Cash, unique transaction
  IDs, payment status (pending/paid/failed/refunded), signature-verified
  server-side before ever marking Paid
- **Receipts** — booking-success page with all details, QR code (admin
  scans it to open `admin-scan.html` straight to that booking), print and
  branded PDF download
- **QR Booking Poster** — `admin-qr-poster.html` generates a permanent, high-resolution QR (counter or wall-poster size) pointing at `book-slot.html`, downloadable as PNG/SVG or printable directly
- **Reviews** — 1–5 stars + comment on completed bookings, admin replies
- **Loyalty** — points, visit count, membership tier (standard → silver →
  gold → platinum), shown on the customer's profile
- **Notifications** — booking confirmation/cancellation/reschedule/
  reminder emails, WhatsApp support, SMS architecture (future-ready) — all
  fire-and-forget, never block a booking/payment action
- **Production features** — 404/500 pages, skeleton loading states, offline
  banner, toast notifications throughout, accessible modals

## Known Limitations / Future Enhancements

- Cash/UPI-at-counter payments still require an admin to reconcile them
  manually (mark refunded via `mark_payment_refunded`); there's no
  dedicated "record cash received" button in the admin UI yet.
- WhatsApp/SMS require a real Business/Twilio account to activate — the
  code is production-shaped and will work the moment real credentials are
  set, but no message sends until then.
- `pg_cron`/`pg_net` (no-show auto-expiry, reminders, notification
  webhooks) require those extensions enabled on your Supabase project —
  optional, and safe to leave off.
