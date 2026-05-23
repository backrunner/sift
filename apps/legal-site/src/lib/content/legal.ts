import type { LegalPageData } from "./legal-types";

export const privacyPage: LegalPageData = {
  eyebrow: "Sift privacy",
  title: "Privacy Policy",
  lead:
    "Sift filters SMS on device first. Remote sample contribution is optional, sanitized, and reversible with a receipt token.",
  updated: "2026-05-09",
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
      value: "Rejected",
      note: "Sender, account, device, and similar identity fields are blocked at the API."
    },
    {
      label: "Retention",
      value: "180 / 30 days",
      note: "Primary samples and training snapshots follow separate retention windows."
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
        "If you choose anonymous contribution, the app sends only sanitized SMS text, the chosen label, and model metadata needed to improve the classifier.",
        "The public worker rejects identity fields if a client tries to send them."
      ],
      bullets: [
        "No account ID or login is required.",
        "No sender, phone number, email, contact name, or device identifier is accepted in the sample API.",
        "The server returns a receipt token so you can delete the submitted sample later."
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
        "Primary D1 sample rows are retained for up to 180 days unless deleted earlier with a valid receipt token.",
        "Training snapshots stored in R2 are retained for up to 30 days.",
        "The app keeps the last receipt token locally so the most recent remote sample can still be deleted after a relaunch."
      ],
      callout:
        "If you delete a sample from the app, the primary row is removed from the sample database rather than only hidden."
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
  updated: "2026-05-09",
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
        "The public API is intentionally narrow: it is meant for labeled SMS samples, not for arbitrary user content."
    },
    {
      title: "Remote contribution",
      paragraphs: [
        "If you choose to contribute a sample, you confirm that the sample can be sanitized and used to improve the model.",
        "The receipt token returned by the server is your deletion handle for the most recent accepted submission."
      ]
    },
    {
      title: "Availability and changes",
      paragraphs: [
        "Cloud infrastructure, API routes, and retention windows may change over time.",
        "If a service endpoint is unavailable, the app should continue to work in its local mode."
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
