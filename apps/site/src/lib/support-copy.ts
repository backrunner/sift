import type { SupportLocale } from './support';

const en = {
  eyebrow: 'Support', title: 'How can we help?',
  intro: 'A question, a problem, or an idea — tell us what’s on your mind. Leave your email so we can follow up. No account needed.',
  language: 'Support language', topic: 'What do you need help with?',
  topics: { problem: 'App & filtering', premium: 'Premium & downloads', question: 'Questions & ideas', privacy: 'Data & privacy' },
  email: 'Your email', subject: 'Subject', subjectHint: 'A short summary', details: 'Details',
  prompts: {
    problem: 'What happened, and what did you expect? Include the steps to reproduce it, without sharing real SMS messages.',
    premium: 'Tell us whether you need help with a purchase, restoring Premium, or a model download. Include any error message.',
    question: 'What would you like help with, or what would you like Sift to do?',
    privacy: 'Describe your question or request. Please do not include SMS messages or sensitive identity information.'
  },
  privacyHint: 'Please leave out real SMS messages, phone numbers, verification codes, Apple ID credentials, and payment details.',
  device: 'App and device details', optional: 'Optional', appVersion: 'App version', iosVersion: 'iOS version', deviceModel: 'iPhone model',
  appHint: 'e.g. 1.4', iosHint: 'e.g. iOS 26', deviceHint: 'e.g. iPhone 16',
  verified: 'Security check complete.', verifying: 'Complete the security check to send your request.', retry: 'Retry verification',
  send: 'Send request', sending: 'Sending…',
  consent: 'Your email and message will be used to handle this request.', privacyLink: 'Privacy policy',
  success: 'Request received', successDetail: 'Your request is with the Sift support team. Keep this reference if you contact us again.',
  home: 'Back to Sift', emailAlternative: 'Prefer email?', noScript: 'JavaScript is required for security verification. You can also email support@alkinum.io.',
  errors: {
    method: 'This request could not be submitted. Reload the support page.', origin: 'Please submit from sift.alkinum.com/support.',
    media: 'The request format is invalid. Reload the support page.', unavailable: 'Support is temporarily unavailable. Please email support@alkinum.io.',
    rate_limit: 'Too many attempts. Please wait a minute before trying again.', invalid: 'Check your email and required fields, then complete the security check.',
    verification: 'Verification failed or expired. Please complete a new security check.',
    uncertain: 'We could not confirm your submission. Please contact support@alkinum.io before submitting again.',
    captcha: 'The security check could not load. Retry or email support@alkinum.io.', timeout: 'The security check timed out. Please retry.'
  }
};

type Copy = typeof en;
export const supportCopy: Record<SupportLocale, Copy> = {
  en,
  'zh-Hans': {
    eyebrow: '技术支持', title: '有什么可以帮你？',
    intro: '使用上有疑问、遇到问题，或有新的想法，都可以告诉我们。留下邮箱，方便我们跟进，无需注册账号。',
    language: '支持语言', topic: '你需要哪方面的帮助？',
    topics: { problem: '应用与短信过滤', premium: '购买与模型下载', question: '使用与建议', privacy: '数据与隐私' },
    email: '联系邮箱', subject: '主题', subjectHint: '用一句话概括', details: '详细说明',
    prompts: {
      problem: '发生了什么？你预期的结果是什么？可以说明复现步骤，请勿粘贴真实短信。',
      premium: '请说明是购买、恢复高级版还是模型下载的问题。如有错误提示，也可以一并描述。',
      question: '你想了解什么，或者希望 Sift 增加哪些功能？',
      privacy: '请说明你的问题或请求。不要提供短信内容或敏感身份信息。'
    },
    privacyHint: '请勿填写真实短信、电话号码、验证码、Apple ID 登录凭据或支付信息。',
    device: '应用与设备信息', optional: '选填', appVersion: '应用版本', iosVersion: 'iOS 版本', deviceModel: 'iPhone 型号',
    appHint: '例如 1.4', iosHint: '例如 iOS 26', deviceHint: '例如 iPhone 16',
    verified: '安全验证已完成。', verifying: '完成安全验证后即可提交。', retry: '重新验证',
    send: '提交工单', sending: '正在提交…', consent: '我们会使用你的邮箱和留言处理本次请求。', privacyLink: '隐私政策',
    success: '已收到你的请求', successDetail: '工单已提交给 Sift 支持团队。请保留以下编号，方便后续联系。',
    home: '返回 Sift 首页', emailAlternative: '也可以发送邮件：', noScript: '安全验证需要启用 JavaScript。你也可以发送邮件至 support@alkinum.io。',
    errors: {
      method: '暂时无法提交，请重新加载支持页面。', origin: '请从 sift.alkinum.com/support 提交。',
      media: '请求格式有误，请重新加载支持页面。', unavailable: '支持服务暂时不可用，请发送邮件至 support@alkinum.io。',
      rate_limit: '尝试次数较多，请等待一分钟后再试。', invalid: '请检查邮箱和必填内容，并完成安全验证。',
      verification: '验证失败或已过期，请重新完成安全验证。', uncertain: '暂时无法确认是否提交成功，请先联系 support@alkinum.io，避免重复提交。',
      captcha: '安全验证未能加载，请重试或发送邮件至 support@alkinum.io。', timeout: '安全验证超时，请重试。'
    }
  },
  ja: {
    eyebrow: 'サポート', title: 'どのようなご用件ですか？',
    intro: 'ご質問、不具合、ご要望をお聞かせください。ご連絡用のメールアドレスだけで送信できます。アカウント登録は不要です。',
    language: 'サポートの言語', topic: 'お問い合わせの種類',
    topics: { problem: 'アプリ・振り分け', premium: '購入・モデルの取得', question: '使い方・ご要望', privacy: 'プライバシー' },
    email: 'メールアドレス', subject: '件名', subjectHint: 'お問い合わせの概要', details: '詳しい内容',
    prompts: {
      problem: '発生したことと期待した動作、再現手順を教えてください。実際のSMS本文は記載しないでください。',
      premium: '購入、Premiumの復元、モデルのダウンロードのどれについてお困りですか？エラーがあれば内容もお知らせください。',
      question: '知りたいことや、Siftに追加してほしい機能をお聞かせください。',
      privacy: 'ご質問やご依頼の内容をご記入ください。SMS本文や機密性の高い個人情報は記載しないでください。'
    },
    privacyHint: '実際のSMS、電話番号、認証コード、Apple IDの認証情報、決済情報は記載しないでください。',
    device: 'アプリと端末の情報', optional: '任意', appVersion: 'アプリのバージョン', iosVersion: 'iOSのバージョン', deviceModel: 'iPhoneのモデル',
    appHint: '例：1.4', iosHint: '例：iOS 26', deviceHint: '例：iPhone 16',
    verified: 'セキュリティ確認が完了しました。', verifying: '送信するにはセキュリティ確認を完了してください。', retry: 'もう一度確認',
    send: '問い合わせを送信', sending: '送信中…', consent: 'メールアドレスと内容は、お問い合わせへの対応に使用します。', privacyLink: 'プライバシーポリシー',
    success: 'お問い合わせを受け付けました', successDetail: 'Siftサポートチームに送信されました。再度ご連絡いただく際のために、この受付番号をお控えください。',
    home: 'Siftのホームに戻る', emailAlternative: 'メールでも受け付けています：', noScript: 'セキュリティ確認にはJavaScriptが必要です。support@alkinum.ioへのメールでもお問い合わせいただけます。',
    errors: {
      method: '送信できませんでした。サポートページを再読み込みしてください。', origin: 'sift.alkinum.com/supportから送信してください。',
      media: '送信形式が無効です。サポートページを再読み込みしてください。', unavailable: '現在サポートを利用できません。support@alkinum.ioへメールでご連絡ください。',
      rate_limit: '試行回数が多すぎます。1分ほど待ってから再度お試しください。', invalid: 'メールアドレスと必須項目を確認し、セキュリティ確認を完了してください。',
      verification: '確認に失敗したか、有効期限が切れました。もう一度セキュリティ確認を行ってください。', uncertain: '送信結果を確認できませんでした。重複送信を避けるため、再送信の前にsupport@alkinum.ioへご連絡ください。',
      captcha: 'セキュリティ確認を読み込めませんでした。再試行するかsupport@alkinum.ioへご連絡ください。', timeout: 'セキュリティ確認がタイムアウトしました。再度お試しください。'
    }
  }
};
