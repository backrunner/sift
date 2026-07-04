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
            "ATM withdrawal of ${amount} from account ending {tail}. If unauthorized, call the number on your card.",
            "{bank}: your new debit card has shipped and should arrive within {days} days."
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
            "Card ending {tail} was charged ${amount}. Pay on time to avoid interest.",
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
            "Contactless payment approved: ${amount} at {merchant}.",
            "Card ending {tail} used for ${amount}. Monthly spend so far: ${amount2}.",
            "Subscription renewed: {platform} charged ${amount} for your monthly plan."
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
            "Partial refund of ${amount} for order {order} has arrived."
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
            "Your pre-order balance payment window opens {date}. Don't miss it."
        ],
        "transaction.points": [
            "You earned {points} points on this purchase. Redeem at checkout.",
            "Your reward points are about to expire. Use them soon!",
            "{brand}: {points} points added. Your balance has been updated.",
            "Points redemption confirmed. Your voucher code arrives shortly.",
            "{points} points expire on {date}.",
            "Points applied: ${amount} discount on this order."
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
            "An item on your wishlist just dropped in price."
        ],
        "transaction.account_security": [
            "Security alert: new device sign-in detected. Was this you?",
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
            "Your parcel has arrived at {station}. Pickup code {code}.",
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
            "Security alert: unusual sign-in attempts detected.",
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
            "Low balance: under ${amount}. Top up to stay connected.",
            "Voice usage: {count} minutes so far this month.",
            "Data cap protection is on — browsing pauses at your limit.",
            "You've used {percent}% of your data. Overage rates apply beyond your plan."
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
            "5G plan flash discount for switchers — device subsidy included, ask in store."
        ],
        "carrier.other": [
            "Carrier notice: your account status was updated.",
            "Service reminder: see the latest announcement.",
            "{carrier}: rate your recent support experience.",
            "Maintenance window: brief outages after midnight on {date}.",
            "Line status: secondary SIM info synced.",
            "Your billing statement is ready in the app."
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
            "Housing loan review progress updated. Visit the counter to confirm."
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
            "Double-points day at {merchant}: earn {points} on every visit."
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
            "Unpaid parking fine: avoid penalties, pay now at {url}"
        ]
    ]
}
