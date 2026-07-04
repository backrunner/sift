import type { LegalPageData } from "./legal-types";

export const privacyPage: LegalPageData = {
  eyebrow: "Sift privacy",
  title: "Privacy Policy",
  lead:
    "Sift filters SMS on device first. Remote sample contribution is optional, sanitized, and reversible with a receipt token.",
  updated: "2026-07-05",
  summaryTitle: "At a glance",
  summary: [
    {
      label: "Default mode",
      value: "Local first",
      note: "Classification, rules, and personalization stay on the phone unless you choose otherwise."
    },
    {
      label: "Remote samples",
      value: "Opt-in only",
      note: "The app asks for consent before any remote sample submission is made."
    },
    {
      label: "Identity fields",
      value: "Never sent",
      note: "Sender, account, phone, and device identity fields are never part of the sample payload."
    },
    {
      label: "Storage",
      value: "iCloud (CloudKit)",
      note: "Samples live in the app's CloudKit public database; statistics back up to your own private iCloud database."
    }
  ],
  sections: [
    {
      title: "What Sift does on device",
      paragraphs: [
        "The iOS app keeps SMS filtering, custom rule management, and local personalization on the device by default.",
        "Custom rules, preview text, and receipt state are stored locally so the app can keep working without an account."
      ]
    },
    {
      title: "When a sample is shared remotely",
      paragraphs: [
        "If you choose anonymous contribution, the app writes only sanitized SMS text, the chosen label, the classifier version, and a coarse language/region tag (for example zh-CN) into the app's CloudKit public database.",
        "Submission uses your device's iCloud session, but the stored sample payload carries no account, sender, or device identity fields."
      ],
      bullets: [
        "No Sift account or login is required; an iCloud session on the device is used only to write the record.",
        "No sender, phone number, email, contact name, or device identifier is included in the sample payload.",
        "The app keeps a receipt for the submitted record so you can delete it later.",
        "Settings → Data & Privacy lets you export all of your submissions as JSON or erase every one of them permanently."
      ]
    },
    {
      title: "Statistics and purchases",
      paragraphs: [
        "Daily filtering statistics are counters only — never message content — and are backed up to the CloudKit private database of your own iCloud account, which we cannot read.",
        "The optional Premium upgrade is a one-time in-app purchase processed entirely by Apple; we never receive payment details."
      ]
    },
    {
      title: "What we do not intentionally collect",
      paragraphs: [
        "The sample pipeline is designed to avoid collecting account data, advertising IDs, precise location, or contact graphs.",
        "We still treat sanitized sample text conservatively as personal data for operational and legal controls."
      ]
    },
    {
      title: "Retention and deletion",
      paragraphs: [
        "Contributed samples are kept in the CloudKit public database while they remain useful for training and dataset curation.",
        "Training corpora are exported as snapshots; snapshots are rebuilt from the live database, so a deleted sample drops out of future exports.",
        "The app keeps the last receipt locally so the most recent remote sample can still be deleted after a relaunch."
      ],
      callout:
        "Erasure is built into the app: Settings → Data & Privacy removes every sample you contributed and your statistics backups, and erased samples drop out of all future model training."
    },
    {
      title: "Legal site traffic",
      paragraphs: [
        "This site is static and does not add analytics, ad tech, or third-party tracking scripts.",
        "Standard hosting metadata may still be processed by the platform that serves the site."
      ]
    }
  ],
  footerNote:
    "For privacy requests, receipt help, or deletion questions, write to privacy@sift.alkinum.io."
};

export const tosPage: LegalPageData = {
  eyebrow: "Sift terms",
  title: "Terms of Service",
  lead:
    "These terms cover the Sift iOS app, the optional sample pipeline, and the legal site hosted on sift.alkinum.io.",
  updated: "2026-07-05",
  summaryTitle: "At a glance",
  summary: [
    {
      label: "Account model",
      value: "No account",
      note: "The product is designed for local use and optional anonymous contribution."
    },
    {
      label: "Hosted service",
      value: "Optional",
      note: "The app works locally even if the public sample service is unavailable."
    },
    {
      label: "Software basis",
      value: "Open source",
      note: "Repository code is governed by its license; these terms cover the hosted service and site."
    },
    {
      label: "Warranty",
      value: "As is",
      note: "The service is provided without guarantees of fitness, availability, or error-free operation."
    }
  ],
  sections: [
    {
      title: "Acceptance",
      paragraphs: [
        "By using Sift or the hosted legal site, you agree to these terms and the linked privacy policy.",
        "If you do not agree, you should not use the hosted sample submission service."
      ]
    },
    {
      title: "Service scope",
      paragraphs: [
        "Sift includes a local SMS classifier, custom rules, and an optional remote sample contribution flow.",
        "The hosted service may change, pause, or be discontinued as the product evolves."
      ],
      bullets: [
        "Local classification remains available without an account.",
        "Remote sample contribution is optional and can be skipped entirely.",
        "The legal site may be updated independently of the app binary."
      ]
    },
    {
      title: "Your responsibilities",
      paragraphs: [
        "You are responsible for the content you submit and for using the service lawfully.",
        "Do not try to submit identity fields, malicious payloads, or data you do not have the right to share."
      ],
      callout:
        "The sample store is intentionally narrow: it is meant for labeled SMS samples, not for arbitrary user content."
    },
    {
      title: "Premium (in-app purchase)",
      paragraphs: [
        "Premium is a one-time, non-consumable purchase that permanently unlocks the Transformer multilingual model on your Apple ID.",
        "Prices — including temporary discounts or free promotions — are set and displayed by the App Store; restore purchases from Settings on any device with the same Apple ID.",
        "Billing and refunds are handled exclusively by Apple. If a purchase is refunded, the app reverts to the standard model."
      ]
    },
    {
      title: "Remote contribution",
      paragraphs: [
        "If you choose to contribute a sample, you confirm that the sample can be sanitized and used to improve the model.",
        "The receipt kept by the app is your deletion handle for the most recent accepted submission, and full erasure is available in Settings."
      ]
    },
    {
      title: "Availability and changes",
      paragraphs: [
        "Cloud infrastructure, storage backends, and dataset curation practices may change over time.",
        "If the sample store is unavailable, the app should continue to work in its local mode."
      ]
    },
    {
      title: "Disclaimer",
      paragraphs: [
        "Sift is provided on an as-is and as-available basis.",
        "To the fullest extent allowed by law, we disclaim warranties of merchantability, fitness for a particular purpose, and non-infringement."
      ]
    }
  ],
  footerNote:
    "Questions about the hosted service or these terms can go to privacy@sift.alkinum.io."
};
