export type SummaryStat = {
  label: string;
  value: string;
  note: string;
};

export type Section = {
  title: string;
  paragraphs: string[];
  bullets?: string[];
  callout?: string;
};

export type LegalPageData = {
  eyebrow: string;
  title: string;
  lead: string;
  updated: string;
  summaryTitle: string;
  summary: SummaryStat[];
  sections: Section[];
  footerNote: string;
};
