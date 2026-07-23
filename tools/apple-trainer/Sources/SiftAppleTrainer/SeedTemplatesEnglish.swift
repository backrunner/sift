import Foundation

/// English seed templates. Full coverage of every taxonomy leaf so the
/// classifier generalises to English SMS across all categories.
enum SeedTemplatesEnglish {
    static let templates: [String: [String]] = [
        "finance.bank": [
            "Your account ending {tail} was debited ${amount} at {time}. Call us if this wasn't you.",
            "Balance update: ${amount} credited to account ending {tail}. Available balance ${amount2}.",
            "{bank}: your transfer of ${amount} has been submitted and should arrive within {minutes} minutes.",
            "Debit card ending {tail} was used for ${amount} on {date}.",
            "Your e-receipt is ready. View transaction {order} in mobile banking.",
            "Housing loan review progress updated. Visit the counter to confirm.",
            "Mortgage application status updated. Check mobile banking for details.",
            "ATM withdrawal of ${amount} from account ending {tail}. If unauthorized, call the number on your card.",
            "{bank}: your new debit card has shipped and should arrive within {days} days.",
            "Account ending {tail} was charged ${amount} by {merchant}; available balance ${amount2}.",
            "Debit account {tail} recorded a ${amount} merchant purchase on {date}.",
            "Bank activity alert: ${amount} spent from account {tail} through an in-store merchant."
        ],
        "finance.insurance": [
            "Your policy is now active. Coverage ${amount2}, effective {date}.",
            "Claim received. Review is expected to complete in {days} business days.",
            "{brand} Insurance: your renewal quote is ready. Confirm before {date}.",
            "Auto policy update complete. New premium: ${amount}.",
            "Premium reminder: ${amount} due on {date}. Keep your coverage active.",
            "Claim payout of ${amount} has been sent to your account ending {tail}."
        ],
        "finance.wealth": [
            "Fund update: {brand} Growth Fund returned {percent}% this quarter.",
            "Your investment product matures on {date}. Choose redeem or reinvest.",
            "Auto-invest confirmed: ${amount} added to your portfolio.",
            "{bank} Wealth: the risk rating of a holding in your portfolio has changed.",
            "Redemption request accepted. Funds arrive in {days} business days.",
            "Dividend of ${amount} has been paid into your settlement account."
        ],
        "finance.credit_card": [
            "Your credit card statement is ready. Amount due ${amount}, payment due {date}.",
            "Your card statement is ready. ${amount} is due by {date}.",
            "Autopay scheduled: ${amount} will be drafted on {date}.",
            "Your credit limit increase request for card ending {tail} was received.",
            "Installment reminder: this month's payment is ${amount}.",
            "Payment received. ${amount} posted to card ending {tail}. Thank you.",
            "Minimum payment ${amount} for card ending {tail} is due {date}. Late payment affects your credit score."
        ],
        "finance.consumption": [
            "Purchase alert: ${amount} at {merchant} on {time}.",
            "Payment to {merchant} of ${amount} completed. Order {order}.",
            "You paid {merchant} ${amount} via {platform}.",
            "Retail card transaction approved at {merchant} for ${amount}; card ending {tail}.",
            "Contactless payment approved: ${amount} at {merchant}.",
            "Card ending {tail} used for ${amount}. Monthly spend so far: ${amount2}.",
            "Subscription renewed: {platform} charged ${amount} for your monthly plan.",
            "Installment purchase at {merchant}: ${amount} was paid with your card.",
            "Installment payment complete for order {order}: ${amount}."
        ],
        "finance.income": [
            "You received a transfer of ${amount}. New balance ${amount2}.",
            "Salary alert: ${amount2} has been deposited into account ending {tail}.",
            "{name} sent you ${amount}. It's now in your balance.",
            "Deposit received: ${amount} at {time}.",
            "Cash deposit of ${amount} to account ending {tail} confirmed.",
            "Expense reimbursement of ${amount} has been paid. Check your account."
        ],
        "finance.refund": [
            "Your refund of ${amount} has been issued to your original payment method.",
            "Order refund complete: ${amount} returned. Allow {days} business days.",
            "{platform}: refund for return {order} has been processed.",
            "The merchant initiated a ${amount} refund. Watch for the credit.",
            "Refund approved. ${amount} will appear on your statement shortly.",
            "Partial refund of ${amount} for order {order} has arrived.",
            "Transaction refund of ${amount} was sent back to the original payment method.",
            "Your refund request was approved; funds will return to the original account.",
            "After-sales update: the refund for order {order} is complete.",
            "The merchant reversed the transaction and is returning ${amount}.",
            "Card purchase reversal complete. ${amount} has been credited back.",
            "Installment order cancelled. The first payment of ${amount} is being refunded."
        ],
        "finance.stock": [
            "{brand} shares moved {percent}% today. Review your positions.",
            "Order filled: {count} shares executed.",
            "IPO allocation notice: you may subscribe up to {count} shares.",
            "Brokerage cash balance changed by ${amount}.",
            "Order {order} has been cancelled as requested.",
            "Margin call warning: maintain the required equity before {date}."
        ],
        "finance.other": [
            "You have a new notice from your bank. Sign in to view it.",
            "Finance update: please confirm your latest service status.",
            "Your e-invoice details were updated. Confirm before {date}.",
            "Proof-of-funds request received. Track progress online.",
            "Please upload the latest supporting documents for your finance application.",
            "Exchange rate alert: your watched currency pair has been updated."
        ],
        "transaction.order": [
            "Order {order} paid successfully. The seller is preparing your items.",
            "Your order has shipped! Track it in the app.",
            "{platform}: your scheduled service starts at {time}.",
            "Order {order} has been cancelled. Any charges will be reversed.",
            "The store accepted your order. Ready in about {minutes} minutes.",
            "Final payment received. Your invoice request has been submitted.",
            "Your pre-order balance payment window opens {date}. Don't miss it.",
            "Your in-game item order {order} is paid and the seller is preparing delivery.",
            "The limited equipment you purchased has been delivered to your game inventory.",
            "The skins and gold in your order have shipped and should arrive within {minutes} minutes.",
            "Your game-account trade is in verification; the buyer will be notified when it completes.",
            "The mount you purchased was delivered to the character selected at checkout.",
            "Virtual-material order {order} is complete; verify the quantity in your character inventory.",
            "Your purchased cosmetic has been delivered to the collection on the linked account.",
            "Item trade complete: the seller sent the goods to your selected server character."
        ],
        "transaction.points": [
            "You earned {points} points on this purchase. Redeem at checkout.",
            "Your reward points are about to expire. Use them soon!",
            "{brand}: {points} points added. Your balance has been updated.",
            "Points redemption confirmed. Your voucher code arrives shortly.",
            "{points} points expire on {date}.",
            "Points applied: ${amount} discount on this order.",
            "Your rewards-gift redemption is confirmed and ships within {days} business days.",
            "The points redemption request is preparing for delivery; no second request is needed.",
            "This redemption used {points} points and the gift order status was updated.",
            "Rewards mall result: redemption accepted, with tracking available in your history."
        ],
        "transaction.member": [
            "You've been upgraded to {tier}! Exclusive perks are now active.",
            "Your membership expires soon. Renew to keep your benefits.",
            "{brand}: your birthday reward is here. Use it before {date}.",
            "Membership approved. Member ID {order}.",
            "Welcome to {tier}! Valid through {date}.",
            "Heads up: {brand} membership renews on {date} for ${amount}. Manage anytime."
        ],
        "transaction.message": [
            "New message: {task}.",
            "Inbox updated — {count} unread notifications.",
            "{platform}: support replied to your ticket.",
            "You have a new comment reply.",
            "System message: a service you follow has an update.",
            "A campaign page has a new in-app message. Open the app to view details.",
            "An item on your wishlist just dropped in price.",
            "Game version update complete: the new map and balance changes are now live.",
            "The mobile game releases a new version on {date}; login is unavailable during maintenance.",
            "Your game client is up to date. This release fixes crashes and matchmaking issues.",
            "Routine maintenance is complete with fixes for voice chat and party connectivity.",
            "The version patch finished installing and contains stability and performance changes only.",
            "Game service update complete; no paid content was added in this maintenance release."
        ],
        "transaction.account_security": [
            "Security alert: new device sign-in detected. Was this you?",
            "Security alert: unusual sign-in attempts detected.",
            "Login security alert: abnormal sign-in attempt detected. Was this you?",
            "Login protection enabled. If this wasn't you, change your password now.",
            "Your password was changed at {time}.",
            "Verification passed. This device is now trusted.",
            "New sign-in from {city} at {time}. Review your account activity.",
            "Phone number change requested for your account. Freeze the account if this wasn't you.",
            "Two-step verification is now on. You'll need a code at each login."
        ],
        "transaction.other": [
            "Your transaction center has a new status update.",
            "Account service notice: information sync completed.",
            "Service ticket {order} status changed. Check progress in the app.",
            "You have a pending confirmation. Complete it before {date}.",
            "Platform notice: your subscription status was updated.",
            "Your activity record has been archived."
        ],
        "life.takeaway": [
            "Your food has arrived — please pick it up at the door.",
            "Order's ready! Your courier is on the way.",
            "{merchant} accepted your order. ETA {minutes} min.",
            "Your rider is waiting at the restaurant for pickup.",
            "Delivery order cancelled. Refund will follow the original payment.",
            "Delivery issue: the rider will call to confirm your address.",
            "Your order was left at the front desk / delivery locker. Enjoy!"
        ],
        "life.express": [
            "Your parcel reached {station} and is being prepared for delivery.",
            "Package out for delivery — expect it today.",
            "{courier}: your package is with the driver for delivery.",
            "Your parcel was delivered to {station}.",
            "Delivery attempt failed. We'll retry tomorrow.",
            "Your package moved to a pickup point. Details to follow.",
            "{courier}: shipment {order} left {city} and is in transit.",
            "Your driver {name} is delivering today. Keep your phone handy."
        ],
        "life.utility": [
            "Water bill of ${amount} is ready. Pay by {date}.",
            "Electricity reminder: ${amount} due this month.",
            "Gas bill issued: ${amount} for this period.",
            "HOA fee reminder: pay by {date} to avoid late charges.",
            "Broadband bill ${amount} generated. Autopay on {date}.",
            "Parking payment of ${amount} confirmed."
        ],
        "life.logistics": [
            "Tracking {order}: your freight reached a transit hub, arriving tomorrow.",
            "Your shipment reached the distribution center.",
            "Goods loaded. Route information updated.",
            "Logistics alert: the delivery address needs a unit number.",
            "Order {order} left the warehouse. Next stop {station}.",
            "Bulky-item delivery scheduled for {date} {time}.",
            "Line-haul update: freight cleared the {city} sorting hub, temperature normal.",
            "Your mover accepted the job — truck ending {tail} arrives in {minutes} minutes."
        ],
        "life.pickup_code": [
            "Your parcel has arrived at {station}. Pickup code {code}.",
            "Parcel at {station}. Pickup code {code}.",
            "Locker drop-off complete. Your code is {code}.",
            "{station}: collect your parcel with code {code}.",
            "Pickup notice: parcel for number ending {tail}, code {code}.",
            "Held at the pickup point — collect within {days} days with your code.",
            "Locker {count} assigned. Access code {code}.",
            "Reminder: your parcel has waited {days} days. Use code {code} before it's returned."
        ],
        "life.medical": [
            "Appointment booked for {date} {time}.",
            "Your lab results are ready. View them in the patient portal.",
            "{hospital}: queue number {count}. Please arrive early to check in.",
            "Health check booked. Please fast before your visit on {date}.",
            "Follow-up reminder: your doctor will see you at {time}.",
            "Prescription issued. Pharmacy pickup details are in the portal.",
            "Vaccination reminder: dose {count} scheduled for {date}."
        ],
        "life.weather": [
            "Weather warning: heavy rain expected in {city} around {time}.",
            "Heat advisory: {city} reaching {temp}°C today.",
            "{city} weather service issued a high wind warning. Limit outdoor activity.",
            "Temperatures drop sharply over the next {days} days. Dress warmly.",
            "Flash flood watch issued. Avoid low-lying roads.",
            "Air quality alert: pollution levels are elevated today.",
            "Storm track update: landfall expected near {city} on {date}."
        ],
        "life.other": [
            "Service update: your request has been received.",
            "Community notice: please check the latest announcement.",
            "Housekeeping booked for {date} {time}.",
            "Repair ticket {order} assigned. Keep your phone reachable.",
            "Event registration confirmed. Please sign in on arrival.",
            "Access badge updated. Valid through {date}."
        ],
        "travel.tourism": [
            "Trip confirmed! Hotel check-in on {date}.",
            "Itinerary update: your attraction tickets are issued.",
            "Hotel booking confirmed for guest ending {tail}.",
            "Tour reminder: meet the group at {time}.",
            "Itinerary change: your guide will call within {minutes} minutes.",
            "Vacation rental confirmed. Door code {code}."
        ],
        "travel.transport": [
            "Travel reminder: your departure is at {time}.",
            "Flight delay notice — watch for rebooking options.",
            "Trip complete. Fare: ${amount}.",
            "Bus arrival: next service in about {minutes} minutes.",
            "Parking exit fee ${amount} paid for plate ending {tail}.",
            "Your airport driver {name} is on the way, about {minutes} minutes out."
        ],
        "travel.ticketing": [
            "Your flight is ticketed. Flight {flight}.",
            "Train booking confirmed. Details sent to your account.",
            "Ticket issued for train {train}, departing {time}.",
            "Event tickets issued. Enter with code {code}.",
            "Refund request received. Fees apply as shown at purchase.",
            "Rebooking successful: new departure {date} {time}.",
            "Online check-in for flight {flight} is open. Pick your seat now."
        ],
        "travel.other": [
            "Travel service update: your order status changed.",
            "Trip planning complete — see your full itinerary.",
            "Car rental confirmed. Pickup {date} {time}.",
            "Visa application progress updated. Check for document requests.",
            "Luggage shipping booked. Tracking {order}.",
            "Travel protection active through {date}."
        ],
        "work.reminder": [
            "To-do: {task} is due by {time}.",
            "Calendar: {task} starts soon.",
            "Project reminder: {task} is due {date}.",
            "On-call reminder: your shift starts at {time} tonight.",
            "{name} is waiting on your reply since {time}.",
            "Weekly report due {date}. Please submit on time."
        ],
        "work.alert": [
            "System alert: {task} failed. Immediate action required.",
            "Monitoring: API latency exceeded the threshold.",
            "Resolved: service {task} is back to normal.",
            "Security scanner alert: service {task} failed policy checks.",
            "Disk space is running low on the production server.",
            "Job failure count hit the alert threshold.",
            "Pager: on-call engineer, please ack P{count} now.",
            "Build failed: pipeline {brand} errored at {time}."
        ],
        "work.meeting": [
            "Meeting reminder: starts at {time}. Join early.",
            "You're invited to an online meeting — link sent to your email.",
            "{platform} meeting starts in {minutes} minutes.",
            "Room booked: floor {count}, {city} office.",
            "Weekly sync: {date} {time}. Agenda published.",
            "Zoom reminder: {date} {time}, passcode sent separately."
        ],
        "work.approval": [
            "Approval needed: a request is waiting for you.",
            "Your leave request has been approved.",
            "Expense approval: ${amount} claim moved to review.",
            "Workflow {order} awaits your approval.",
            "{name} returned your request with comments.",
            "Comp-time request approved. See details in the system."
        ],
        "work.attendance": [
            "Attendance synced for today.",
            "Leave recorded: {count} hours.",
            "Field check-in recorded in {city}.",
            "Attendance issue: missing clock-out on {date}.",
            "Roster: you're on duty on {date}.",
            "Overtime logged: {count} hours."
        ],
        "work.announcement": [
            "Company notice: holiday schedule is out.",
            "New org announcement published.",
            "All hands this Friday at {time}.",
            "Welcome {name} to the {brand} team!",
            "Benefits update effective {date}.",
            "Team offsite: RSVP by {date}."
        ],
        "work.training": [
            "Training starts {date}.",
            "New course assigned: {task}.",
            "Exam reminder: online test on {date} {time}.",
            "Certification expires {date}. Schedule your renewal.",
            "Learning plan updated — finish this week's modules.",
            "Onboarding session {count} starts at {time}."
        ],
        "work.other": [
            "Your work inbox has new updates.",
            "Collaboration: one unread task message.",
            "Expense report {order} moved to finance review.",
            "Ticket {task} assigned to {name}.",
            "New comment awaits your reply on the project board.",
            "Team admin: member permissions updated."
        ],
        "carrier.call_reminder": [
            "Missed call alert: you have a new missed call.",
            "Call assistant: {count} missed calls recently.",
            "{carrier}: a number ending {tail} called you at {time}.",
            "Missed call — no voicemail left. Tap to call back.",
            "New voicemail. Dial your mailbox to listen.",
            "Call guard blocked {count} suspected spam calls this week."
        ],
        "carrier.data_reminder": [
            "You've used {count}GB this month. {remain}GB left in your plan.",
            "Plan alert: your data pack expires soon.",
            "{carrier}: {remain}GB of nationwide data remaining.",
            "Voice usage: {count} minutes so far this month.",
            "Data cap protection is on — browsing pauses at your limit.",
            "You've used {percent}% of your data. Overage rates apply beyond your plan.",
            "Your plan has {remain}GB remaining, and rollover data clears at month end.",
            "Usage notice: {remain}GB is available in this billing cycle and resets next month.",
            "Current data balance is {remain}GB; this message is a usage reminder only.",
            "You've used {percent}% of your monthly mobile allowance."
        ],
        "carrier.billing": [
            "{carrier} billing notice: ${amount} is due by {date}.",
            "Low airtime balance: ${amount} remains on your account. Please top up.",
            "Payment received: ${amount} was added to your {carrier} account. New balance ${remain}.",
            "Your monthly {carrier} statement is ready in the app.",
            "Autopay reminder: this month's mobile bill will be charged on {date}.",
            "Overdue account notice: ${amount} is outstanding. Pay to avoid service suspension.",
            "Your {carrier} bill is paid in full. Thank you.",
            "Account balance notice: ${amount} remains available for mobile service.",
            "{carrier} monthly bill ready: ${amount} is due by {date}.",
            "Mobile service statement: ${amount} must be paid before {date}."
        ],
        "carrier.service": [
            "Service request received. We'll text you the result.",
            "Your plan change request has been submitted.",
            "{carrier}: identity verification passed.",
            "SIM replacement submitted. Bring ID to collect at a store.",
            "Broadband relocation booked. A technician will call on {date}.",
            "International roaming activated through {date}."
        ],
        "carrier.promotion": [
            "Broadband speed upgrade offer — reply INFO to learn more.",
            "Special plan deal: switch today and save.",
            "{carrier}: top up ${amount} and get a bonus data pack.",
            "Loyalty upgrade offer for long-term customers. Reply to enroll.",
            "Home internet bundle discount ends {date}.",
            "Limited streaming perk — claim at your nearest store.",
            "{carrier}: prepay ${amount} airtime and get {count}GB monthly bonus data. Reply 1.",
            "5G plan flash discount for switchers — device subsidy included, ask in store.",
            "{carrier} rewards mall is open: redeem {points} points for data packs and streaming perks.",
            "Use your mobile rewards for a ${amount} airtime voucher before {date}: {url}",
            "Earn {points} bonus carrier points on selected services and redeem device gifts."
        ],
        "carrier.other": [
            "Carrier notice: your account status was updated.",
            "Service reminder: see the latest announcement.",
            "{carrier}: rate your recent support experience.",
            "Maintenance window: brief outages after midnight on {date}.",
            "Line status: secondary SIM info synced."
        ],
        "government.notice": [
            "Public service notice: {task} has been received.",
            "Official notice: please complete your information confirmation.",
            "Community notice: complete data collection before {date}.",
            "Your document application status was updated on the portal.",
            "Immigration application moved to the next step. Watch for SMS updates.",
            "Registry result ready — collect at the designated counter."
        ],
        "government.traffic": [
            "DMV reminder: appointment confirmed for {date}.",
            "Vehicle ending {tail} has a violation recorded on {date}. Handle it promptly.",
            "Licence renewal reminder: complete review before {date}.",
            "Toll charge: ${amount} for your recent trip.",
            "Vehicle inspection appointment confirmed.",
            "Traffic authority: your penalty notice has been generated."
        ],
        "government.tax": [
            "Tax notice: your filing was submitted. Result will follow by SMS.",
            "e-Tax: this month's VAT filing is complete.",
            "Annual tax reconciliation is open. File in the official app.",
            "Your tax refund of ${amount} has been approved.",
            "Tax awareness campaign: see the latest policy updates.",
            "Invoice quota approved. Collect at the tax office."
        ],
        "government.social_security": [
            "Social insurance paid: ${amount} for this month.",
            "Health insurance: balance ${amount} available at partner clinics.",
            "Housing fund: this month's contribution has posted.",
            "Benefits transfer completed. Review the details online.",
            "Your digital insurance credential is active for hospital checkout.",
            "Housing fund contribution certificate request was received."
        ],
        "government.court": [
            "Court notice: case {order}, appear on {date}.",
            "Judicial service: please acknowledge the electronic documents.",
            "Mediation scheduled for {date} {time}.",
            "Enforcement notice: fulfill obligations before {date}.",
            "Case filing accepted: your litigation materials were received.",
            "Hearing schedule changed — check the court bulletin."
        ],
        "government.policy": [
            "Benefit policy: subsidy eligibility review has started.",
            "New regulation effective {date}. See details on the portal.",
            "Employment support policy updated — visit the official site.",
            "Housing assistance applications are now open.",
            "Public health guidance updated. Please follow the requirements.",
            "New government circular published on the official website."
        ],
        "government.other": [
            "Civic center notice: check the latest announcement.",
            "Public service: your case moved to the next stage.",
            "Public payment services restored.",
            "Service reminder: your queue number is {count}.",
            "Application submitted. Response within {days} business days.",
            "Your public-platform profile has been updated."
        ],
        "verification": [
            "Your verification code is {code}. Valid for {minutes} minutes. Do not share it.",
            "Login code: {code}. Ignore if this wasn't you.",
            "{platform} security code {code} for identity confirmation.",
            "Payment code {code}. Never forward this to anyone.",
            "Sign-up code: {code}, expires in {minutes} minutes.",
            "Password reset code {code}. Staff will never ask for it.",
            "{brand} code {code}. Enter within {minutes} minutes.",
            "Your one-time passcode is {code}.",
            "OTP: {code} for your {bank} transaction. Do not disclose.",
            "2FA code {code}. {brand} will never call to ask for this.",
            "Use {code} to verify your phone number change.",
            "G-{code} is your {platform} verification code."
        ],
        "promotion": [
            "Flash sale! {brand} members save ${amount} today. Reply STOP to opt out.",
            "{brand} event is live — first {count} orders get a discount.",
            "New arrivals at {merchant}: spend & save today only.",
            "Member day is here! Coupons added to your account.",
            "Store anniversary — show this SMS for a free gift.",
            "Live shopping tonight {time}: first {count} buyers get special pricing.",
            "{merchant} Black Friday: up to {percent}% off storewide {url}",
            "{merchant} Cyber Monday: extra {percent}% off, tap {url}",
            "{brand} holiday bundle — {tier} members earn {points} bonus points.",
            "Grand opening: pick up a ${amount} voucher in store at {merchant}.",
            "{brand} Christmas deals are live at {url}",
            "Two-for-one Tuesdays at {merchant}!",
            "You have {count} unclaimed coupons in your {brand} account.",
            "{merchant} summer sale from {percent}% off select lines.",
            "Loyalty thanks: a ${amount} reward just for you, {name}.",
            "New season styles at {merchant} — ${amount} off your first order {url}",
            "{brand} beauty: {percent}% off until {time} tonight.",
            "${amount} dining voucher from {merchant} — reply STOP to end.",
            "Buy 4 get 1 free coffee at {merchant} through {date}.",
            "{brand} gym {city}: annual pass ${amount2} — details {url}",
            "Your {bank} points expire {date} — redeem gifts at {url}",
            "Double-points day at {merchant}: earn {points} on every visit.",
            "A new game server launches today — preregister for an exclusive hero and {points} gems.",
            "First top-up bonus is back: buy ${amount} in game credits and receive double currency.",
            "New season pass sale: limited skins and rare in-game items are {percent}% off.",
            "Anniversary game bundle includes a mount, equipment, and bonus draw tickets.",
            "In-game item marketplace sale: reduced fees on equipment and gold trades this week.",
            "Verified game account and gear marketplace — complete a trade and get a ${amount} coupon.",
            "{bank} card rewards mall: redeem {points} points for appliances and gift cards.",
            "{bank} marketplace member day: spend ${amount2} and save ${amount} on selected items.",
            "{brand} rewards mall offers double points plus a chance to win a ${amount} voucher.",
            "Seasonal fashion sale at {merchant}: buy two styles and save {percent}%.",
            "{merchant} grocery member day: save ${amount} when you spend ${amount2} on fresh food.",
            "Weekend supermarket sale — household essentials are buy one, get one half price {url}",
            "Game top-up week: buy ${amount} in credits and receive {points} bonus gems.",
            "{bank} personal loan rate offer for eligible customers; apply only in the official app.",
            "Licensed lender welcome offer: review the APR and fees before using your loan coupon.",
            "{brand} launches its new collection tonight at {time}; preorders save ${amount}.",
            "New products are live at {merchant}, with double points on selected releases.",
            "Furnished one-bedroom apartment near the {city} metro; book a viewing for ${amount} off fees.",
            "New rental listings from {brand} apartments include move-in and rent promotions {url}",
            "This week's armory rotation is live: rare gear is available for instant listing and sale.",
            "The game marketplace armory refresh adds limited weapons and skins with zero listing fees.",
            "The equipment rotation sale is open; verified sellers earn a bonus on featured item trades.",
            "Gold, materials, and rare mounts have new trading tiers with reduced fees this week.",
            "Game-item seller offer: refresh your storefront and list selected gear to receive promotion credits.",
            "Limited skins are ready for instant sale in today's armory drop, with discounts on bulk purchases.",
            "The account-and-gear consignment event is live; verify and list an item to claim a coupon.",
            "Virtual-item marketplace restock: rotating goods are on presale with double member points.",
            "New phone launch trade-in combines extra device credit with a screen-protection bundle.",
            "Airline member fare day offers discounted return routes plus bonus miles.",
            "Hotel advance-booking package includes consecutive nights, breakfast, and a member rate.",
            "Early auto-insurance renewal adds car-wash and roadside-assistance benefits to your quote.",
            "Car-care member event includes a vehicle inspection and labor voucher with an oil service.",
            "Cinema member revival week has limited savings on pair-ticket packages.",
            "The late-night dining menu includes a snack and a future voucher with qualifying takeout.",
            "Early enrollment for summer classes includes a trial lesson and project-course bundle.",
            "New fitness club opening offer waives the joining fee and extends annual plans.",
            "Home renovation showcase clients save the design fee and receive upgraded fittings.",
            "Bank rewards mall redemption week lowers point prices and includes free shipping.",
            "Card dining cashback season rewards qualifying spend at selected restaurants."
        ],
        "spam": [
            "High-yield investment club — join now for guaranteed returns. Reply STOP.",
            "WINNER! You've been selected for a prize. Contact the agent to claim.",
            "Earn ${amount}/day working from home. Add the recruiter to start.",
            "Your account is abnormal. Click the link to verify or it will be frozen.",
            "Instant loan approval — borrow up to ${amount2} with just your ID.",
            "Invoices and certificates for sale. Contact online support.",
            "[WARNING] Account at risk. Resolve now at {url}",
            "Congrats! You won an iPhone. Claim via {order} today.",
            "Data-entry side job, ${amount}/day, no experience. Join group {order}.",
            "Bad credit OK — instant cash, no checks: {url}",
            "Your delivery could not be signed. Re-verify at {url}",
            "Your {brand} account is flagged for violations. Fix it at {url}",
            "Exclusive wealth group invite: {percent}% annualized, guaranteed.",
            "Your toll pass expired. Reactivate at {url}",
            "{bank} card upgrade required — verify at {url} immediately.",
            "Your package is held at customs. Pay ${amount} duty: {url}",
            "IRS notice: unpaid taxes detected. Settle immediately to avoid arrest.",
            "Hi mom, my phone broke — message me at this new number {order}.",
            "Your Netflix payment failed. Update billing at {url}",
            "Crypto insider signals — 10x guaranteed, join {order}.",
            "Your number won the international lottery. Send a fee to release funds.",
            "Unpaid parking fine: avoid penalties, pay now at {url}",
            "Pay a deposit before your loan is released — no credit check, same-day cash. Contact {order}."
        ]
    ]
}
