# Dream Look — v1.0.0 Release Candidate 1 (RC1)

A complete, production-ready barber shop booking platform: authentication
(including Google sign-in), a real booking engine with live queue
management and smart slot allocation, a full admin panel, payments,
receipts, reviews, loyalty, and notifications — running on plain HTML/CSS/
vanilla JS and Supabase, deployable to Vercel with zero build step.

## What's in this release

**For customers**
- Sign up or log in with email, or one click with Google
- Book one or more services in a single appointment — price and duration
  total automatically
- See only genuinely open time slots (shop hours, buffer time, holidays,
  and every barber's real schedule all accounted for)
- If two people click the same slot at nearly the same moment, the system
  automatically moves one of them to the next open time instead of
  failing the booking
- Live queue position and estimated wait time, updating without a refresh
- Cancel or reschedule anytime before your appointment
- Pay online (card/UPI/netbanking via Razorpay) or in cash at the shop
- A branded receipt with a QR code, downloadable as PDF or printable
- Leave a 1–5 star review after your visit; see the shop's reply
- Automatic loyalty points, visit count, and membership tier

**For the shop**
- A live dashboard: today's bookings, current queue, walk-ins, revenue,
  completed/cancelled/no-show counts, registered customers
- Full queue control: call the next customer, mark arrived, start
  service, complete, or mark no-show
- Add a walk-in customer with one click — the system finds their next
  open slot and queue number automatically
- Manage services, barbers, and shop hours/holidays/buffer time — every
  change takes effect for customers immediately
- Search any customer's booking history
- Daily/weekly/monthly/custom reports, including revenue and most
  popular services
- A permanent, printable QR poster for the counter or wall, so walk-in
  customers can book without ever needing the website link
- A read-only audit log of every booking-affecting action, filterable by
  date and action type
- Reply to customer reviews

## Known limitations in this release
- Cash payment reconciliation is manual (no dedicated "mark cash
  received" button in the admin UI yet)
- WhatsApp/SMS notifications need a real Business/Twilio account
  configured before they'll actually send (the code is fully functional
  and will work the moment real credentials are set)
- A live, real-world concurrency load test (many simultaneous bookings
  hitting the same slot) has not been run against a production database —
  the underlying mechanism (a PostgreSQL `EXCLUDE` constraint plus a
  bounded retry loop) is sound by design and was verified through careful
  code review, but hasn't been stress-tested with real traffic

## Upgrading from an earlier phase's database
Run any SQL files in `sql/` you haven't run yet, strictly in the numeric
order shown in `README.md`. Nothing in this release drops or renames data
from a previous phase — every migration is additive or a same-signature
`CREATE OR REPLACE`.

## Deployment
See `README.md` (Supabase setup, environment variables, Edge Function
deployment) and `PRODUCTION_SETUP.md` (pre-launch checklist) for full
instructions. Short version:

1. Run all 11 SQL files in order.
2. Enable the Google OAuth provider in Supabase.
3. Set `assets/js/config.js` with your project's URL/anon key.
4. Deploy the 5 Edge Functions and set their secrets.
5. Push to GitHub, import into Vercel (no build command needed).
6. Work through `TESTING_CHECKLIST.md` before opening to real customers.
