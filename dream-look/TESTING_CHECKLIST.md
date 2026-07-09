# Dream Look — Testing Checklist

## Google OAuth

- [ ] "Continue with Google" on `login.html`/`signup.html` redirects to Google, then back to `dashboard.html` with a session already active
- [ ] First-time Google sign-in creates a `public.users` row automatically (same `handle_new_user` trigger as email signup)
- [ ] An existing Google user logging in again does NOT create a duplicate profile row
- [ ] Email/password login still works unaffected

## Multi-Service Booking

- [ ] Selecting multiple services on `book-slot.html` sums price and duration correctly in the summary
- [ ] Available slots shrink appropriately as more services (more combined duration) are selected
- [ ] The resulting booking's receipt, dashboard row, and admin queue table all show every selected service, not just one
- [ ] `booking_services` has one row per selected service with the price/duration snapshotted at booking time

## Smart Slot Allocation

- [ ] Two browser tabs both loading the same open slot, submitting within ~1 second of each other — exactly one succeeds at the requested time, the other is automatically rebooked to the next open slot/barber with a clear "your requested time was taken" message, not an error page
- [ ] No duplicate/overlapping booking is ever created regardless of how many tabs race (verify in the DB, not just the UI)

## QR Poster

- [ ] `admin-qr-poster.html` renders a scannable QR pointing at `book-slot.html`
- [ ] Counter Size / Wall Poster Size toggle changes the rendered size and re-generates the QR at appropriate resolution
- [ ] Download PNG and Download SVG both produce valid, scannable files
- [ ] Print Poster hides the nav/footer/buttons and prints only the poster

## Authentication

- [ ] Sign up with a new email → account created, redirected/confirmed per your email-confirmation setting
- [ ] Sign up with an already-registered email → friendly error, no account enumeration leak beyond Supabase's default message
- [ ] Sign up with a weak password (<8 chars) → inline validation error, no request sent
- [ ] Sign up with mismatched confirm-password → inline error
- [ ] Log in with correct credentials → redirected to `dashboard.html`
- [ ] Log in with wrong password → friendly error, field not cleared unnecessarily
- [ ] Visit `login.html`/`signup.html` while already logged in → auto-redirected to dashboard
- [ ] Visit `dashboard.html`/`profile.html`/`book-slot.html` while logged out → redirected to `login.html`
- [ ] Forgot password → request link → email arrives → link opens `forgot-password.html` in recovery mode → set new password → redirected to login
- [ ] Log out from navbar → session cleared, protected pages redirect to login again
- [ ] Admin login with a non-admin account → rejected with "no admin access", session signed out
- [ ] Admin login with a real admin account → lands on `admin-dashboard.html`
- [ ] Visit `admin-dashboard.html` directly as a non-admin (or logged out) → redirected to `admin-login.html`

## Booking Flow

- [ ] `book-slot.html` shows only active services
- [ ] Selecting a service reveals the date picker; date picker `min` is today
- [ ] Selecting a weekly-off day → hint shown, no slots fetched
- [ ] Selecting a holiday date (in `shop_closed_dates`) → hint shown, no slots
- [ ] Selecting today → slots in the past are absent
- [ ] Selecting a service+date → only genuinely open slots appear (verify one manually against `shop_settings` hours/buffer)
- [ ] Book a slot → booking created with status `confirmed`, correct `end_time` (duration + buffer), a queue number assigned
- [ ] Immediately book the exact same slot again in a second tab/incognito → second attempt fails with "slot was just taken" (tests the DB exclusion constraint, not just the UI)
- [ ] Book two overlapping times for the same barber → second rejected
- [ ] Confirm redirect to `booking-success.html?booking=<id>` after booking

## Booking Success / Payment

- [ ] All fields populate: booking ID, customer, service, barber, date, time, queue #, estimated wait, payment status, amount
- [ ] QR code renders and, when scanned/opened, lands on `admin-scan.html?booking=<id>` with the correct booking pre-loaded
- [ ] Print Receipt opens the browser print dialog with only the receipt visible (nav/footer/buttons hidden)
- [ ] Download Receipt (PDF) produces a branded, correctly-filled PDF
- [ ] Selecting Cash → "Confirm Cash Payment" → payment status becomes `pending`, no charge attempted
- [ ] Selecting Card/UPI → Razorpay Checkout opens with the correct amount
- [ ] Complete a Razorpay **test** payment → payment status flips to `paid`, confirmation email sent (if configured)
- [ ] Cancel the Razorpay modal (don't pay) → payment stays `pending`, no error thrown
- [ ] Tamper with the Razorpay response client-side (e.g. via devtools) before it reaches `verify-razorpay-payment` → signature check fails, payment marked `failed`, nothing marked Paid
- [ ] Attempt to pay for a booking that's already `paid` → `create_payment_record` rejects with "already paid for"
- [ ] Reload the page after paying → payment section hides, status shows Paid (idempotent — reloading doesn't create a duplicate charge)

## Customer Dashboard

- [ ] Upcoming Appointment card shows the soonest active booking with the correct timeline stage highlighted
- [ ] Live wait countdown updates every ~30s without a page refresh
- [ ] Cancel from the hero card → confirmation prompt → booking removed from active list, queue renumbers for anyone behind it
- [ ] Reschedule from the hero card → scrolls to and opens the matching row's reschedule panel
- [ ] Reschedule panel: picking a new date shows only open slots for that date; confirming moves the booking and re-validates all the same rules as a fresh booking
- [ ] Booking history lists past bookings with correct status badges (including `arrived`/`in_service`/`no_show`)
- [ ] Completed booking with no review yet shows the star picker; submitting requires at least 1 star
- [ ] Completed booking with a review already shows the stars/comment (read-only) and any admin reply
- [ ] Receipt link on every row opens `booking-success.html?booking=<id>` correctly, even for old/completed bookings
- [ ] Open two browser tabs as the same customer; in tab A cancel a booking — tab B's dashboard updates within ~1s without a manual refresh (Realtime)

## Admin Panel — Dashboard

- [ ] All 8 stat cards populate and match a manual count in the DB for today
- [ ] Book something as a customer in another tab → dashboard numbers update live without refresh

## Admin Panel — Queue

- [ ] Today's bookings appear ordered by queue number
- [ ] Mark Arrived / Start Service / Complete / No Show each transition correctly and only show for the right prior status
- [ ] Call Next Customer pulls the lowest-queue-number `arrived` booking into `in_service`; errors clearly if someone is already `in_service` or nobody has arrived
- [ ] Cancel from the queue table removes the booking and renumbers the rest
- [ ] Add a walk-in → gets today's earliest open slot and a queue number immediately, status `arrived`
- [ ] Two admins (two tabs) both viewing the queue — an action in one tab reflects in the other within ~1s

## Admin Panel — Services / Barbers

- [ ] Add / edit a service; price and duration validate (no negative price, no zero duration)
- [ ] "Delete" a service → it disappears from `book-slot.html`'s service list but existing bookings referencing it are untouched
- [ ] Reactivate a deleted service → reappears for customers
- [ ] Add / edit / deactivate a barber; deactivated barber no longer offered for new bookings

## Admin Panel — Shop Settings

- [ ] Change opening/closing time, buffer, grace period, slot interval, weekly-off days → save → immediately reflected in `book-slot.html`'s availability for a customer
- [ ] Add a holiday date → that date becomes unbookable for customers; remove it → bookable again

## Admin Panel — Customers / Reports / Audit

- [ ] Search finds a customer by partial name, email, or phone
- [ ] Customer detail splits Upcoming vs History correctly
- [ ] Reports: Daily/Weekly/Monthly presets and a Custom range all return correct totals; revenue reflects only `paid` payments, not just completed-booking price
- [ ] Popular Services ranks by booking count within the chosen range
- [ ] Audit Log filters by date range and by action type; entries exist for created/cancelled/rescheduled/completed/no-show/payment events

## Reviews

- [ ] Customer can only review their own completed booking (attempt via devtools RPC call for someone else's booking → rejected)
- [ ] Submitting a second review for the same booking updates the existing one rather than creating a duplicate
- [ ] `admin-reviews.html` lists all reviews; replying saves and displays immediately; a non-admin calling `admin_reply_review` directly is rejected

## Error Handling / Production Features

- [ ] Navigate to a non-existent URL → Vercel serves `404.html`
- [ ] Manually open `500.html` → renders correctly, on-brand
- [ ] Toggle devtools "offline" mode on a page with the offline banner wired in → banner appears; go back online → disappears
- [ ] Every form shows inline field errors before making a network request for obviously-invalid input (empty required fields, bad email format, short passwords)
- [ ] Every async button (login, signup, book, pay, cancel, reschedule, admin actions) shows a loading state and disables itself during the request

## Security / Abuse Attempts (adversarial pass)

- [ ] Call `create_booking` via the browser console for a date in the past → rejected
- [ ] Call `mark_payment_paid` directly via `supabase.rpc(...)` as a logged-in customer → rejected (function not granted to `authenticated`)
- [ ] Call `complete_booking`/`mark_no_show`/`call_next_customer` as a non-admin → rejected with "Only an admin can…"
- [ ] Try to fetch another customer's booking via `get_booking_receipt` with their booking ID while logged in as someone else → rejected unless you're an admin
- [ ] Try to `select` another user's row from `public.users` as a customer → RLS returns nothing
- [ ] Rapid-fire click "Confirm Booking" / "Pay Now" multiple times → button disables after first click, no duplicate booking/payment created
- [ ] Open the same open slot in two tabs and submit both within a second of each other → exactly one succeeds, the other gets "slot was just taken" (race condition test on the DB exclusion constraint)
