"""Prospective trilingual contrast families. Labels and roles precede any model screen.

Written from the taxonomy rubric and training cell counts, in the short register of
real SMS. Each family shares one opaque link where a link appears, so body evidence
must decide. Every spam row carries a visible malicious clause: a fee, card or
credential request through the link, or a threat attached to one. Development
families share no topic with training families and are never trained.
"""
ABSTAIN = '__sift_abstain__'


def cases():
    return [
        # Normal notices that ask the recipient to sign in, against phishing on the same link.
        ('training', 'insurer-claim-letter', 'login-link', 'orvani', [
            ('finance.insurance', '您的理赔决定书已上传，登录会员中心即可查看。', 'Your claim decision letter is ready. Sign in to your policy account to read it.', '保険金請求の決定通知をアップロードしました。契約者ページにログインしてご確認ください。'),
            ('spam', '理赔款将于今晚作废，请立即点击登录并填写银行卡号和CVV领取。', 'Your claim payout expires tonight. Sign in now and enter your card number and CVV to collect it.', '保険金の受取期限は今夜までです。今すぐログインしてカード番号とセキュリティコードを入力してください。'),
            ('promotion', '新客加购齿科保障首年八折，详情看这里。', 'New: add dental cover and get 20% off your first year. See plans here.', '歯科保障の追加で初年度20%オフ。プランの詳細はこちらから。'),
            (ABSTAIN, '保单那封信我还没看，晚上一起研究下吧。', 'I have not read the insurance letter yet, can we go through it tonight?', '保険の手紙まだ読んでないから、今夜一緒に見てくれる？'),
        ]),
        ('training', 'patient-lab-results', 'login-link', 'cereno', [
            ('life.medical', '您的化验报告已出，请登录患者端查看，如有疑问请联系门诊。', 'Your lab results are available. Log in to the patient portal to view them or call the clinic with questions.', '検査結果が出ました。患者ポータルにログインしてご確認ください。ご不明点は外来までどうぞ。'),
            ('spam', '化验结果异常，须先支付19元解锁费，请点击并输入银行卡信息。', 'Abnormal lab result. Pay a 19 dollar unlock fee at this link with your card details to see it.', '検査結果に異常があります。閲覧には1900円の解除料が必要です。リンクからカード情報を入力してください。'),
            ('promotion', '春季体检套餐限时六折，名额有限，点此预约。', 'Spring health check packages are 40% off this month. Book your spot here.', '春の健診パッケージが今月限定40%オフ。ご予約はこちら。'),
            (ABSTAIN, '医生说结果正常，我晚点把报告拿回家给你看。', 'The doctor said it all looks fine, I will bring the report home later.', '先生は問題ないって。結果は後で家に持って帰るね。'),
        ]),
        ('training', 'school-teacher-reply', 'login-link', 'talvino', [
            ('transaction.message', '王老师在家校平台回复了您的留言，登录后可查看。', 'Ms Lane replied to your note in the parent app. Log in to read her reply.', '田中先生が保護者アプリであなたのメッセージに返信しました。ログインしてご覧ください。'),
            ('spam', '您孩子的学籍将被注销，请立即登录并缴纳299元保留费。', 'Your child will be removed from the school roll. Log in now and pay a 299 dollar retention fee.', 'お子様の学籍が抹消されます。今すぐログインして保持費29900円をお支払いください。'),
            ('promotion', '暑期编程营开放报名，早鸟立减300元。', 'Summer coding camp is open. Early birds save 30 dollars when they enrol here.', '夏のプログラミング合宿受付中。早期申込で3000円引き。'),
            (ABSTAIN, '老师回我了，说明天不用带午饭。', 'The teacher got back to me, no packed lunch needed tomorrow.', '先生から返事が来て、明日はお弁当いらないって。'),
        ]),
        ('training', 'tenant-portal-repair', 'login-link', 'brimola', [
            ('transaction.message', '物业已回复您的报修留言，请登录租户中心查看。', 'Your property manager replied to your repair ticket. Log in to the tenant portal to see the message.', '管理会社が修理依頼に返信しました。入居者ページにログインしてご確認ください。'),
            ('spam', '房东已更换收款账户，本月租金请点击链接转入新账户，否则将被清退。', 'Your landlord changed bank details. Send this month\'s rent to the new account at this link or face eviction.', '大家さんの振込先が変わりました。リンク先の新しい口座へ今月の家賃を送金しないと退去となります。'),
            ('life.other', '明早9点维修师傅上门检修热水器，请家中留人。', 'A technician will check your water heater at 9 tomorrow morning. Please have someone home.', '明朝9時に給湯器の点検に伺います。ご在宅をお願いします。'),
            (ABSTAIN, '热水器修好了吗？我今晚想早点回去洗澡。', 'Is the water heater fixed yet? I want to get home early for a shower.', '給湯器もう直った？今夜は早く帰ってお風呂に入りたいな。'),
        ]),
        ('training', 'tax-inbox-statement', 'login-link', 'dessaru', [
            ('government.tax', '您的年度个税清单已生成，请登录税务账户查看。', 'Your annual tax statement is ready. Sign in to your tax account to view it.', '年間の税額通知を発行しました。税務アカウントにログインしてご確認ください。'),
            ('spam', '您有未领取退税3280元，24小时内点击填写银行卡和密码办理。', 'You have an unclaimed tax refund of 3,280. Enter your card and PIN at this link within 24 hours.', '未受取の還付金が32800円あります。24時間以内にリンクからカード番号と暗証番号を入力してください。'),
            ('government.other', '办税大厅本周六因系统升级暂停对外服务。', 'The tax service hall is closed this Saturday for a system upgrade.', '税務窓口はシステム更新のため今週土曜日は休業します。'),
            (ABSTAIN, '今年退税到账了吗？我的还在审核。', 'Did your tax refund arrive yet? Mine is still in review.', '今年の還付金もう入った？私のはまだ審査中。'),
        ]),
        ('training', 'bank-inbox-document', 'login-link', 'hemeru', [
            ('finance.bank', '您的账户对账单已放入网银信箱，登录后可下载。', 'Your account statement is in your online banking inbox. Log in to download it.', 'オンラインバンキングに口座明細が届いています。ログインしてダウンロードしてください。'),
            ('spam', '您的账户已被冻结，2小时内点击登录并输入密码和验证码，否则永久停用。', 'Your account is frozen. Log in within 2 hours and enter your password and SMS code or it closes for good.', '口座を凍結しました。2時間以内にログインしてパスワードと認証コードを入力しないと永久に停止します。'),
            ('transaction.account_security', '您的账户在新设备登录，如非本人操作请修改密码。', 'Your account was signed in on a new device. If this was not you, change your password.', '新しい端末からログインがありました。心当たりがない場合はパスワードを変更してください。'),
            ('promotion', '新开定存享3.2%年利率，到网点或线上均可办理。', 'Open a new fixed deposit at 3.2% a year, online or in branch.', '新規定期預金が年3.2%。店頭またはオンラインでお申し込みいただけます。'),
        ]),
        # Service look-alikes where the fee, threat or credential request is the difference.
        ('training', 'parcel-redelivery-fee', 'lookalike', 'kurisen', [
            ('life.express', '您的包裹今日派送未成功，可在此免费改约时间。', 'We missed you today. Choose a new delivery time for free here.', '本日お荷物をお届けできませんでした。こちらから無料で再配達を手配できます。'),
            ('spam', '包裹因地址不全被扣留，请付1.99元手续费并填写银行卡信息后重新派送。', 'Parcel held for an incomplete address. Pay a 1.99 fee with your card details to release it.', '住所不備でお荷物を保管中です。手数料199円をカード情報入力のうえお支払いください。'),
            ('life.pickup_code', '您的包裹已到自提柜，取件码6185。', 'Your parcel is in the locker. Pickup code 6185.', 'お荷物が宅配ロッカーに届きました。受取コード6185。'),
            ('promotion', '寄件满3单送优惠券，本周有效。', 'Send 3 parcels this week and get a coupon.', '今週3個以上の発送でクーポンをプレゼント。'),
        ]),
        ('training', 'road-toll-unpaid', 'lookalike', 'vantoru', [
            ('government.traffic', '您的车辆有一条违停记录，可在交管平台核对并办理。', 'Your vehicle has a parking violation on record. Review it on the traffic authority site.', 'お車の駐車違反が記録されています。交通当局のサイトでご確認ください。'),
            ('spam', '您有未缴通行费，今日不付款将吊销驾照，请点击输入卡号缴费。', 'Unpaid road toll. Pay today by entering your card here or your licence will be suspended.', '通行料金が未納です。本日中にカード番号を入力して支払わないと免許停止になります。'),
            ('travel.transport', '明日环城高速施工，请提前规划路线。', 'Ring road works tomorrow. Plan your route ahead.', '明日は環状道路で工事があります。経路を事前にご確認ください。'),
            (ABSTAIN, '我今天停车好像压线了，不知道会不会被罚。', 'I think I parked over the line today, hope I do not get fined.', '今日の駐車、線を踏んでたかも。違反にならないといいけど。'),
        ]),
        ('training', 'streaming-renewal-card', 'lookalike', 'poliveo', [
            ('finance.consumption', '您的视频会员月费25元已扣款。', 'Your video subscription charge of 25 went through.', '動画サービスの月額2500円を引き落としました。'),
            ('spam', '会员扣费失败，账号即将删除，请点击重新填写银行卡和有效期。', 'Your subscription payment failed and your account will be deleted. Re-enter your card and expiry here.', '決済に失敗しアカウントが削除されます。こちらからカード番号と有効期限を再入力してください。'),
            ('transaction.member', '您的会员已续期至明年3月。', 'Your membership is renewed through March next year.', '会員資格を来年3月まで更新しました。'),
            ('promotion', '升级家庭版立减10元，首月体验。', 'Upgrade to the family plan and save 10 on your first month.', 'ファミリープランへのアップグレードで初月1000円引き。'),
        ]),
        ('training', 'carrier-points-expiry', 'lookalike', 'mobirex', [
            ('transaction.points', '您有800积分将于月底到期，可在营业厅App兑换。', 'Your 800 points expire at month end. Redeem them in the carrier app.', '800ポイントが月末に失効します。アプリで交換できます。'),
            ('spam', '积分今晚清零，请点击输入银行卡和验证码兑换现金。', 'Your points reset tonight. Enter your card number and code here to swap them for cash.', 'ポイントは今夜失効します。カード番号と認証コードを入力して現金に交換してください。'),
            ('carrier.promotion', '加10元升级5G套餐，流量翻倍。', 'Add 10 a month to move up to 5G and double your data.', '月1000円の追加で5Gプランへ。データ容量が2倍に。'),
            ('carrier.billing', '您本月话费58元已出账，请按时缴纳。', 'Your phone bill this month is 58. Please pay on time.', '今月の通信料金は5800円です。期日までにお支払いください。'),
        ]),
        ('training', 'credit-card-freeze', 'lookalike', 'zerano', [
            ('finance.credit_card', '您本期信用卡账单1260元，最后还款日为18日。', 'Your card statement is 1,260, due on the 18th.', '今月のカードご請求額は12600円、お支払期限は18日です。'),
            ('spam', '您的信用卡因异常被锁，请点击填写卡号、CVV和短信码解锁。', 'Your credit card is locked. Enter your number, CVV and SMS code here to unlock it.', 'クレジットカードをロックしました。カード番号、セキュリティコード、SMSコードを入力して解除してください。'),
            ('verification', '您的验证码是582913，5分钟内有效，请勿告诉他人。', 'Your code is 582913, valid for 5 minutes. Do not share it.', '認証コードは582913です。5分間有効です。他人に教えないでください。'),
            ('promotion', '办新卡首刷返50元，点击申请。', 'Get 50 back on your first spend with a new card. Apply here.', '新規カードの初回利用で500円還元。お申し込みはこちら。'),
        ]),
        ('training', 'recruiter-task-job', 'lookalike', 'jovanta', [
            ('work.approval', '您的请假申请已获主管批准。', 'Your leave request has been approved by your manager.', '休暇申請が上長に承認されました。'),
            ('spam', '兼职刷单日赚500，先垫付一单，加导师领任务。', 'Part-time rating tasks pay 500 a day. Advance the first order and message the mentor for tasks.', '在宅タスクで日給5万円。最初の注文を立て替えて、担当者に連絡してください。'),
            ('work.training', '周四下午新员工安全培训，请准时到B会议室。', 'New staff safety training is Thursday afternoon in room B.', '新入社員の安全研修は木曜午後、B会議室です。'),
            (ABSTAIN, '我打算下个月换工作，最近在看机会。', 'I am thinking of changing jobs next month, just looking around.', '来月転職しようと思って、いま色々見てるところ。'),
        ]),
        ('training', 'benefit-subsidy-claim', 'lookalike', 'nesvaro', [
            ('government.social_security', '您的医保缴费记录已更新，可在社保平台查询。', 'Your health insurance contribution record is updated. Check it on the social security site.', '健康保険の納付記録を更新しました。年金ポータルでご確認いただけます。'),
            ('spam', '您可领取补贴2400元，请点击填写身份证和银行卡密码，今日截止。', 'You qualify for a 2,400 subsidy. Enter your ID and card PIN here by today.', '給付金24000円を受け取れます。本日中に身分証番号とカード暗証番号を入力してください。'),
            ('government.policy', '新版生育津贴办法自下月起施行，全文已公布。', 'New parental allowance rules take effect next month. The full text is published.', '新しい出産手当の制度が来月施行されます。全文を公表しました。'),
            ('government.other', '社区服务中心本周起调整午休时间。', 'The community service centre changes its lunch hours from this week.', '地域サービスセンターの昼休み時間を今週から変更します。'),
        ]),
        ('training', 'court-hearing-warrant', 'lookalike', 'quelaro', [
            ('government.court', '您的案件定于5月12日上午开庭，请携证件到第三法庭。', 'Your case is set for hearing on May 12 in the morning, courtroom 3. Bring your ID.', '事件の期日は5月12日午前、第3法廷です。身分証をお持ちください。'),
            ('spam', '您涉嫌洗钱将被逮捕，请立即将资金转入安全账户配合调查。', 'You are named in a money laundering case. Move your funds to the safe account now or be arrested.', 'マネーロンダリングの疑いで逮捕されます。直ちに資金を安全口座へ移してください。'),
            ('government.notice', '您提交的居住证申请已受理，预计5个工作日办结。', 'Your residence permit application is accepted and should finish in 5 working days.', '在留関連の申請を受理しました。処理には5営業日ほどかかります。'),
            (ABSTAIN, '明天我要去法院当陪审员，午饭你们先吃。', 'I have jury duty tomorrow, go ahead with lunch without me.', '明日は裁判員で裁判所に行くから、お昼は先に食べてて。'),
        ]),
        ('training', 'wealth-guaranteed-group', 'lookalike', 'finoral', [
            ('finance.wealth', '您赎回的理财产品已到期，本金和收益已转回。', 'Your wealth product has matured. Principal and return are back in your account.', 'お申し込みの資産運用商品が満期を迎え、元本と収益を返金しました。'),
            ('spam', '内部荐股群保本月赚30%，先转入保证金再拉你进群。', 'Private stock group guarantees 30% a month. Send a deposit first and we add you.', '元本保証で月30%の非公開投資グループ。先に保証金を振り込むと招待します。'),
            ('finance.stock', '您持有的股票分红已到账。', 'The dividend on your shares has been paid.', '保有株式の配当金が入金されました。'),
            ('promotion', '新发行稳健理财产品开售，起投1万元，风险自担。', 'New low-risk fund on sale from 10,000. Investment carries risk.', '新しい低リスクファンド発売中。1万円から。投資にはリスクがあります。'),
        ]),
        # Thin labels against their neighbours, without any filtering contrast.
        ('training', 'public-office-four-way', 'thin-label', None, [
            ('government.other', '市档案馆下周一闭馆盘点，恢复开放时间另行通知。', 'The city records office closes Monday for stocktaking. Reopening will be announced.', '市の公文書館は月曜に蔵書点検で休館します。再開日は追ってお知らせします。'),
            ('government.policy', '市政府发布新的公共停车管理条例，下季度实施。', 'The city has issued new public parking regulations, in force next quarter.', '市は新しい公共駐車場条例を公布しました。来四半期に施行します。'),
            ('government.reminder', '近期气温骤降，请注意用火用电安全。', 'Temperatures are dropping fast. Please take care with heaters and open flames.', '急に冷え込んでいます。火の元と電気の安全にご注意ください。'),
            ('government.notice', '您申请的残疾人停车证已办结，可到窗口领取。', 'Your disabled parking permit is ready to collect at the counter.', 'ご申請の障害者用駐車許可証ができました。窓口でお受け取りください。'),
        ]),
        ('training', 'carrier-missed-call', 'thin-label', 'telvoro', [
            ('carrier.call_reminder', '您关机期间有2个未接来电，最近一次来自尾号3321。', 'You had 2 missed calls while your phone was off, the latest from a number ending 3321.', '電源オフの間に不在着信が2件ありました。最新は末尾3321の番号からです。'),
            ('carrier.data_reminder', '您本月流量已用85%，剩余1.5GB。', 'You have used 85% of your data this month, 1.5 GB left.', '今月のデータ通信量を85%使いました。残り1.5GBです。'),
            ('carrier.service', '您的国际漫游已开通，回国后可随时关闭。', 'International roaming is now on. Turn it off any time when you return.', '国際ローミングを有効にしました。帰国後はいつでも解除できます。'),
            ('spam', '您有一条语音留言待收听，请点击安装插件并允许访问短信。', 'You have a voicemail waiting. Tap to install the player and allow access to your messages.', '留守番電話が届いています。再生アプリをインストールしてSMSへのアクセスを許可してください。'),
        ]),
        ('training', 'takeaway-rider-order', 'thin-label', None, [
            ('life.takeaway', '骑手已取餐，预计20分钟送达。', 'Your rider picked up the food, about 20 minutes away.', '配達員が料理を受け取りました。約20分でお届けします。'),
            ('life.express', '您的快递正在派送中，今天下午送达。', 'Your parcel is out for delivery and arrives this afternoon.', 'お荷物は配達中で、本日午後に到着予定です。'),
            ('transaction.order', '您的订单已确认，商家正在备货。', 'Your order is confirmed and the seller is preparing it.', 'ご注文を確定しました。店舗で商品を準備しています。'),
            ('promotion', '今晚外卖满30减8，手慢无。', 'Tonight only: 8 off food orders over 30.', '今夜限定、3000円以上のデリバリーで800円引き。'),
        ]),
        ('training', 'flight-rebooking-fee', 'lookalike', 'aerivon', [
            ('travel.ticketing', '您的机票已出票，订单号K7T2Q，可在行程单查看。', 'Your flight ticket is issued, reference K7T2Q. See your itinerary for details.', '航空券を発券しました。予約番号K7T2Q。旅程表でご確認いただけます。'),
            ('travel.transport', '您乘坐的航班因天气延误至20:15起飞。', 'Your flight is delayed by weather and now departs at 20:15.', 'ご搭乗便は天候のため20時15分発に遅れます。'),
            ('spam', '您的航班已取消，请点击支付改签费并提供银行卡验证码以获得赔偿。', 'Flight cancelled. Pay the rebooking fee here and send your bank code to receive compensation.', 'ご搭乗便は欠航です。変更手数料を支払い、銀行の認証コードを送ると補償を受けられます。'),
            ('travel.tourism', '您报名的古城一日游明早8点集合，导游小陈。', 'Your old town day tour meets at 8 tomorrow. Your guide is Chen.', 'ご参加の旧市街日帰りツアーは明朝8時集合、ガイドは陳です。'),
        ]),
        ('training', 'power-cut-threat', 'lookalike', 'luminet', [
            ('life.utility', '您家本月电费186元，请于25日前缴纳。', 'Your electricity bill this month is 186, due by the 25th.', '電気代のご請求は18600円、支払期限は25日です。'),
            ('spam', '您家今晚将被断电，请立即点击用银行卡缴清欠费。', 'Your power will be cut tonight. Clear the arrears now with your bank card at this link.', '今夜電気を止めます。直ちにリンクからカードで未納分を支払ってください。'),
            ('life.other', '小区周日上午清洗水箱，期间可能短暂停水。', 'The building tank is cleaned Sunday morning, so water may stop briefly.', '日曜午前に貯水槽を清掃するため、一時的に断水する場合があります。'),
            ('promotion', '安装屋顶太阳能，首年省电费，免费上门评估。', 'Go solar and cut your bills. Book a free home assessment.', '屋根に太陽光パネルを。無料の現地診断受付中。'),
        ]),
        ('training', 'merchant-overpaid-refund', 'lookalike', 'refundia', [
            ('finance.refund', '您退货的款项89元已退回原支付方式。', 'Your 89 return refund is back on your original payment method.', '返品分の8900円を元のお支払い方法へ返金しました。'),
            ('spam', '商家多收了您的货款，请把收到的短信验证码告诉客服才能退款。', 'The shop overcharged you. Tell our agent the SMS code you get so we can refund you.', '店舗が過剰に請求しました。返金のため、届いたSMSコードを担当者にお伝えください。'),
            ('finance.consumption', '您在便利店消费23元。', 'You spent 23 at the convenience store.', 'コンビニで2300円のご利用がありました。'),
            ('transaction.other', '您的售后申请状态已更新为处理中。', 'Your after-sales request status is now in progress.', 'アフターサービスの申請状況を処理中に更新しました。'),
        ]),
        ('training', 'password-reset-event', 'lookalike', 'sentrix', [
            ('transaction.account_security', '您的登录密码已修改。如非本人操作请联系客服。', 'Your login password was changed. Contact support if this was not you.', 'ログインパスワードが変更されました。心当たりがない場合はサポートへご連絡ください。'),
            ('verification', '登录验证码440271，请勿转发。', 'Sign-in code 440271. Do not forward it.', 'ログイン用コード440271。転送しないでください。'),
            ('spam', '我是客服，您的账号被盗，请把刚收到的验证码发给我处理。', 'Support here, your account was hacked. Send me the code you just got so I can fix it.', 'サポート担当です。アカウントが乗っ取られました。今届いたコードを私に送ってください。'),
            ('transaction.other', '您的账号资料已同步完成。', 'Your profile data has finished syncing.', 'アカウント情報の同期が完了しました。'),
        ]),
        ('training', 'it-mailbox-quota', 'lookalike', 'corpdesk', [
            ('work.alert', '生产服务器磁盘使用率超过90%，请值班人员处理。', 'Production server disk is over 90%. On-call please respond.', '本番サーバーのディスク使用率が90%を超えました。担当者は対応してください。'),
            ('spam', '您的邮箱已满将被关闭，请点击输入工号和密码扩容。', 'Your mailbox is full and will close. Enter your staff ID and password here to expand it.', 'メールボックスが満杯で閉鎖されます。社員番号とパスワードを入力して容量を増やしてください。'),
            ('work.meeting', '项目评审会改到周三10点，线上进行。', 'Project review moved to Wednesday at 10, online.', 'プロジェクトレビューは水曜10時に変更、オンラインで行います。'),
            ('work.attendance', '您昨日缺少下班打卡记录，请补卡。', 'You are missing a clock-out for yesterday. Please correct it.', '昨日の退勤打刻がありません。修正をお願いします。'),
        ]),
        ('training', 'family-new-number', 'lookalike', None, [
            (ABSTAIN, '妈，我换号了，这是新号码，周末回家吃饭。', 'Mum, this is my new number. See you for dinner on the weekend.', 'お母さん、番号変えたよ。週末ごはん食べに帰るね。'),
            ('spam', '妈，我手机坏了，这是新号，急需用钱，先转3000到这个账户。', 'Mum, my phone broke, new number. I urgently need money, send 3,000 to this account now.', 'お母さん、スマホが壊れて番号変わった。急ぎでお金が必要だから、この口座に3万円振り込んで。'),
            ('life.other', '您预约的家政阿姨周六上午9点上门。', 'Your cleaner is booked for Saturday at 9 in the morning.', 'ご予約のハウスクリーニングは土曜午前9時に伺います。'),
            ('transaction.message', '您的好友在相册留言板给您留言了。', 'Your friend left you a comment on the shared album.', 'お友だちが共有アルバムにコメントを残しました。'),
        ]),

        # Development families: disjoint topics, screened by nothing, never trained.
        ('development', 'gym-member-account', 'login-link', 'athlora', [
            ('transaction.member', '您的健身会员卡已冻结一个月，登录账户可随时恢复。', 'Your gym membership is paused for a month. Log in any time to resume it.', 'ジム会員を1か月休会にしました。アカウントからいつでも再開できます。'),
            ('spam', '健身卡将被注销且不退款，请点击登录并填写银行卡CVV保留。', 'Your gym account will be closed with no refund. Log in and enter your card CVV to keep it.', 'ジム会員が返金なしで解約されます。ログインしてカードのセキュリティコードを入力してください。'),
            ('promotion', '私教课买十送二，本月有效。', 'Buy ten personal training sessions, get two free this month.', 'パーソナルトレーニング10回購入で2回無料。今月限定。'),
            (ABSTAIN, '今晚健身房人太多了，我们明天再去吧。', 'The gym is packed tonight, let us go tomorrow.', '今夜はジムが混みすぎ。明日にしよう。'),
        ]),
        ('development', 'pension-portal-letter', 'login-link', 'senvora', [
            ('government.social_security', '您的养老金待遇核定表已生成，登录社保账户可查看。', 'Your pension award letter is ready. Log in to your social security account to see it.', '年金額の決定通知を発行しました。年金アカウントにログインしてご確認ください。'),
            ('spam', '养老金账户异常将停发，请点击填写身份证和银行卡密码核实。', 'Your pension account has a problem and payments will stop. Enter your ID and card PIN to verify.', '年金口座に異常があり支給を停止します。身分証番号とカード暗証番号を入力して確認してください。'),
            ('government.policy', '今年退休人员基本养老金调整方案已公布。', 'This year\'s adjustment to the basic pension for retirees has been published.', '今年度の基礎年金の改定方針を公表しました。'),
            (ABSTAIN, '我爸下个月退休，正想帮他算算养老金。', 'My dad retires next month and I am helping him work out the pension.', '父が来月退職するから、年金の計算を手伝ってる。'),
        ]),
        ('development', 'vet-clinic-records', 'login-link', 'petrano', [
            ('life.medical', '您家猫咪的疫苗记录已更新，登录宠物医院账户可查看。', 'Your cat\'s vaccine record is updated. Log in to your vet clinic account to view it.', '猫ちゃんのワクチン記録を更新しました。動物病院のアカウントにログインしてご覧ください。'),
            ('spam', '宠物检查发现重症，须先扫码转账500元给医生个人账户才给治疗。', 'Your pet has a serious illness. Send 500 to the doctor\'s personal account before treatment starts.', 'ペットに重い病気が見つかりました。治療前に医師個人の口座へ5万円を振り込んでください。'),
            ('promotion', '宠物洁牙套餐立减百元，预约从速。', 'Save 100 on pet dental cleaning. Book soon.', 'ペットの歯科クリーニングが1万円引き。お早めにご予約を。'),
            (ABSTAIN, '猫今天打完针一直在睡，应该没事吧。', 'The cat has been sleeping since the shot, I think she is fine.', '猫は注射のあとずっと寝てる。たぶん大丈夫だよね。'),
        ]),
        ('development', 'freight-customs-duty', 'lookalike', 'cargolu', [
            ('life.logistics', '您的整车货物已到华东转运仓，预计明日发往门店。', 'Your freight reached the east transfer warehouse and leaves for the store tomorrow.', '貨物は東日本の中継倉庫に到着し、明日店舗へ出荷予定です。'),
            ('spam', '海关扣留您的货物，请点击支付关税并填写银行卡，否则销毁。', 'Customs is holding your goods. Pay the duty with your bank card at this link or they are destroyed.', '税関が貨物を保留中です。リンクからカードで関税を支払わないと廃棄されます。'),
            ('life.express', '您的快件已由小李签收代放门卫处。', 'Your parcel was signed for and left at the front desk.', 'お荷物は受付でお預かりしています。'),
            ('promotion', '企业大宗货运首单九折，欢迎咨询。', 'Business freight customers get 10% off the first shipment.', '法人向け貨物輸送、初回10%オフ。お気軽にご相談ください。'),
        ]),
        ('development', 'wallet-top-up-code', 'lookalike', 'paylume', [
            ('finance.other', '您的电子钱包年度对账说明已生成。', 'Your e-wallet annual reconciliation summary is ready.', '電子ウォレットの年間明細を発行しました。'),
            ('spam', '钱包被风控，请把支付密码和验证码发给客服解除限制。', 'Your wallet is restricted. Send your payment password and code to the agent to lift it.', 'ウォレットが制限されました。支払いパスワードと認証コードを担当者に送って解除してください。'),
            ('verification', '您正在绑定钱包，验证码709146。', 'You are linking your wallet. Your code is 709146.', 'ウォレット連携の認証コードは709146です。'),
            ('promotion', '钱包充值满100送5元，本周末截止。', 'Top up your wallet by 100 and get 5 free until Sunday.', 'ウォレットに1万円チャージで500円還元。今週末まで。'),
        ]),
        ('development', 'vehicle-registration-renewal', 'lookalike', 'motorca', [
            ('government.traffic', '您的机动车年检将于下月到期，请及时办理。', 'Your vehicle inspection expires next month. Please arrange it in time.', 'お車の車検は来月で期限切れになります。お早めに手続きください。'),
            ('spam', '车辆登记异常将被扣押，今日点击输入卡号缴纳罚金。', 'Your car registration is invalid and the vehicle will be seized. Enter your card today to pay the fine.', '車両登録に問題があり差し押さえます。本日中にカード番号を入力して罰金を支払ってください。'),
            ('government.reminder', '雨雪天路面湿滑，请减速慢行。', 'Roads are slippery in rain and snow. Please slow down.', '雨や雪の日は路面が滑りやすいので、速度を落としてください。'),
            ('government.other', '车管所周五下午因培训暂停办公。', 'The vehicle office closes Friday afternoon for staff training.', '運転免許センターは研修のため金曜午後は休業します。'),
        ]),
        ('development', 'rail-ticket-refund', 'lookalike', 'trainly', [
            ('travel.ticketing', '您的高铁票已改签至明日G1208次。', 'Your train ticket was changed to G1208 tomorrow.', '新幹線の切符を明日のG1208便に変更しました。'),
            ('spam', '您的车票退款失败，请点击填写银行卡和密码领取退款。', 'Your train refund failed. Enter your bank card and PIN here to collect it.', '切符の払い戻しに失敗しました。カード番号と暗証番号を入力して受け取ってください。'),
            ('travel.transport', '您乘坐的G1208次列车晚点约15分钟。', 'Train G1208 is running about 15 minutes late.', 'G1208便は約15分遅れて運行しています。'),
            ('promotion', '办铁路常旅客卡，首年免费送贵宾厅券。', 'Join the rail frequent traveller club and get a free lounge pass in year one.', '鉄道会員に入会で、初年度ラウンジ券を無料プレゼント。'),
        ]),
        ('development', 'hr-portal-payroll', 'login-link', 'workfolk', [
            ('work.other', '您的劳动合同续签文件已上传，请登录人事系统查看。', 'Your contract renewal file is uploaded. Log in to the HR system to view it.', '雇用契約の更新書類をアップロードしました。人事システムにログインしてご確認ください。'),
            ('spam', '工资账户验证失败，请点击输入工号、网银密码，否则本月停发。', 'Payroll account check failed. Enter your staff ID and banking password here or this month\'s pay stops.', '給与口座の確認に失敗しました。社員番号とネットバンクのパスワードを入力しないと今月の給与を停止します。'),
            ('work.announcement', '公司端午假期安排已发布，共放假三天。', 'The company holiday schedule is out, three days off in total.', '会社の連休予定を発表しました。合計3日間の休みです。'),
            (ABSTAIN, '人事刚找我聊了合同的事，下班跟你细说。', 'HR just talked to me about my contract, I will tell you after work.', '人事と契約の話をしたよ。仕事のあと詳しく話すね。'),
        ]),
    ]
