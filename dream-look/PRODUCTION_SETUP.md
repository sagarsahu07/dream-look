# Dream Look — Production Setup & Pre-Launch Checklist

Run through this before pointing real customers at the site.

## 1. Database

- [ ] All 11 SQL files in `sql/` run, in order (see README's Database Migrations table), with no errors
- [ ] `select * from shop_settings;` returns your real opening/closing hours,
      buffer, grace period, weekly-off days (not the defaults)
- [ ] At least one row in `barbers` with `is_active = true`
- [ ] At least one row in `services` with `is_active = true` and a real price
- [ ] Your own account promoted to `role = 'admin'` (see README)
- [ ] `pg_cron` + `pg_net` extensions enabled if you want auto no-show
      expiry and reminder emails (Database → Extensions)

## 2. Edge Functions

- [ ] All 5 functions deployed (`supabase functions deploy <name>`)
- [ ] `RAZORPAY_KEY_ID` / `RAZORPAY_KEY_SECRET` set as secrets
- [ ] A real test payment completed end-to-end in Razorpay **test mode**
      before switching to live keys
- [ ] `RESEND_API_KEY` set, and a test booking confirmation email actually
      arrives in an inbox (check spam folder too)
- [ ] `INTERNAL_WEBHOOK_SECRET` set as an Edge Function secret AND saved
      into `notification_settings.internal_secret` (must match exactly)
- [ ] `notification_settings.edge_function_base_url` points at your real
      project's functions URL

## 3. Frontend Config

- [ ] `assets/js/config.js` has your real `SUPABASE_URL` / `SUPABASE_ANON_KEY`
      (not the placeholder values)
- [ ] Supabase **Site URL** and **Redirect URLs** point at your real deployed
      domain, not `localhost`

## 4. Security Review (from the audit)

- [ ] `service_role` key exists ONLY in Edge Function secrets — grep your
      repo for it before pushing to confirm it's nowhere in `assets/js/`
- [ ] `mark_payment_paid` / `mark_payment_failed` are NOT callable by
      `authenticated` — confirm with: `select has_function_privilege('authenticated', 'mark_payment_paid(uuid,text,text)', 'execute');` should return `false`
- [ ] RLS is enabled on every table (`select relrowsecurity from pg_class where relname = 'bookings';` → `t`, repeat for `payments`, `reviews`, etc.)
- [ ] Edge Functions currently allow `Access-Control-Allow-Origin: *` for
      simplicity — consider restricting this to your real domain once it's
      known, in `supabase/functions/_shared/cors.ts`

## 5. Smoke Test (5 minutes)

1. Sign up a new customer account → confirm email if required → log in.
2. Book a slot → land on `booking-success.html` → see queue number + QR.
3. Pay with a Razorpay **test card** → confirm status flips to Paid.
4. As admin, open the Queue tab → Mark Arrived → Start Service → Complete.
5. As the customer, leave a 5-star review on the now-completed booking.
6. As admin, reply to that review from `admin-reviews.html`.
7. Cancel a different booking as the customer → confirm it disappears from
   the admin queue and the audit log shows `booking_cancelled`.

If all seven succeed, the core paid-booking loop is production-ready.

See `TESTING_CHECKLIST.md` for the full, exhaustive test plan.
