"""Prospective trilingual link test written before any model sees it.

The audit found normal messages with real-format links almost unmeasured. Each family
has two normal events, one scam and one offer, sharing a fictional real-format host, so
the host cannot decide. Topics are new. These rows are never trained.
"""


def cases():
    return [
        ('library-renewal', 'lumbrio', [
            ('transaction.other', '您借阅的3本图书已续借至6月2日，详情请登录图书馆账户。', 'Your 3 library books are renewed to June 2. Sign in to your library account for details.', '貸出中の本3冊を6月2日まで延長しました。詳細は図書館アカウントでご確認ください。'),
            ('transaction.message', '馆员回复了您的荐购留言，请登录查看。', 'A librarian answered your book suggestion. Log in to read the reply.', '司書が購入リクエストに返信しました。ログインしてご覧ください。'),
            ('spam', '您的借书证将被注销，请登录并支付9.9元保证金及银行卡信息。', 'Your library card will be cancelled. Sign in and pay a 9.90 deposit with your card details.', '図書カードが停止されます。ログインして保証金990円をカード情報とともにお支払いください。'),
            ('promotion', '图书馆文创周边买二送一，线上商店本周开放。', 'Library gift shop: buy two, get one free online this week.', '図書館グッズが2点購入で1点無料。今週オンライン販売中。'),
        ]),
        ('dental-reminder', 'smileport', [
            ('life.medical', '您预约的洗牙是周二15:30，如需改期请在线操作。', 'Your dental cleaning is Tuesday at 15:30. Reschedule online if needed.', '歯のクリーニングは火曜15時30分です。変更はオンラインでどうぞ。'),
            ('life.medical', '您的牙片已上传，登录患者账户即可查看。', 'Your dental X-rays are uploaded. Log in to your patient account to view them.', 'レントゲン画像をアップロードしました。患者アカウントにログインしてご覧ください。'),
            ('spam', '您的牙科保险将失效，请立即点击填写银行卡号和验证码续保。', 'Your dental cover is about to lapse. Enter your card number and SMS code now to renew.', '歯科保険が失効します。今すぐカード番号と認証コードを入力して更新してください。'),
            ('promotion', '牙齿美白套餐限时五折，名额不多。', 'Teeth whitening is half price for a limited time.', 'ホワイトニングが期間限定で半額。枠に限りがあります。'),
        ]),
        ('water-account', 'aquanet', [
            ('life.utility', '您的水费账单已生成，共76元，可登录查看明细。', 'Your water bill of 76 is ready. Log in to see the details.', '水道料金7600円の請求書を発行しました。ログインして明細をご覧ください。'),
            ('life.utility', '您已成功开通水费自动扣款。', 'Automatic payment for your water bill is now active.', '水道料金の自動引き落としを開始しました。'),
            ('spam', '您家水费严重逾期，今晚停水，请点击用银行卡缴清并验证密码。', 'Your water bill is badly overdue and supply stops tonight. Pay by card here and confirm your PIN.', '水道料金が延滞中で今夜断水します。カードで支払い、暗証番号を確認してください。'),
            ('promotion', '家用净水器新品上市，老用户立减200元。', 'New home water filter, 200 off for existing customers.', '新型浄水器が登場。既存のお客様は2万円引き。'),
        ]),
        ('university-enrolment', 'campuslink', [
            ('life.other', '您的选课结果已公布，请登录教务系统查看。', 'Your course enrolment results are posted. Log in to the student portal.', '履修登録の結果を公開しました。学務システムにログインしてご確認ください。'),
            ('transaction.message', '导师在学生平台给您发了一条消息。', 'Your supervisor sent you a message on the student portal.', '指導教員から学生ポータルにメッセージが届きました。'),
            ('spam', '您的助学金已到账待领取，请先转入298元手续费到指定账户。', 'Your grant is ready to collect. First send a 298 handling fee to the account given.', '奨学金を受け取れます。先に手数料2980円を指定口座へ振り込んでください。'),
            ('promotion', '考研冲刺班开放报名，早报优惠500元。', 'Exam prep course now open, 50 off when you sign up early.', '受験対策講座の受付開始。早期申込で5000円引き。'),
        ]),
        ('pharmacy-refill', 'medimart', [
            ('life.medical', '您的处方药已备好，可到门店取药。', 'Your prescription is ready to collect in store.', 'お薬の準備ができました。店舗でお受け取りください。'),
            ('transaction.order', '您的药品订单已发货，点击可查看物流。', 'Your pharmacy order has shipped. Tap to track it.', 'お薬のご注文を発送しました。配送状況はこちら。'),
            ('spam', '您的处方账户被盗用，请点击输入身份证号和网银密码核实。', 'Your prescription account was misused. Enter your ID number and banking password to verify.', '処方アカウントが不正利用されました。身分証番号とネットバンクのパスワードを入力して確認してください。'),
            ('promotion', '会员日保健品满199减50。', 'Member day: 50 off supplements over 199.', '会員デーはサプリ19900円以上で5000円引き。'),
        ]),
        ('car-insurance', 'drivesure', [
            ('finance.insurance', '您的车险保单已续保，电子保单可登录下载。', 'Your car insurance is renewed. Log in to download your policy.', '自動車保険を更新しました。証券はログインしてダウンロードできます。'),
            ('finance.insurance', '您报案的理赔已受理，定损员将在两日内联系您。', 'Your claim is accepted. An assessor will contact you within two days.', 'ご報告の事故を受け付けました。担当者が2日以内にご連絡します。'),
            ('spam', '车险理赔款待发放，请把银行卡验证码回复给理赔专员。', 'Your claim money is pending. Reply to the agent with the code from your bank.', '保険金の支払い待ちです。銀行から届いたコードを担当者に返信してください。'),
            ('promotion', '新车险投保立享八五折，还送道路救援。', 'Switch your car insurance for 15% off plus free roadside help.', '自動車保険の乗り換えで15%オフ、ロードサービス付き。'),
        ]),
        ('airline-miles', 'skyrewards', [
            ('transaction.points', '您的2,400里程已入账，可登录查看余额。', 'Your 2,400 miles are posted. Log in to see your balance.', '2,400マイルを加算しました。ログインして残高をご確認ください。'),
            ('travel.ticketing', '您的里程兑换机票已出票，行程单已发送。', 'Your award ticket is issued and the itinerary was sent.', '特典航空券を発券し、旅程表をお送りしました。'),
            ('spam', '您的里程今晚清零，请点击填写信用卡号和CVV兑换现金。', 'Your miles expire tonight. Enter your credit card and CVV here to swap them for cash.', '本日でマイルが消えます。交換にはカード番号とセキュリティコードの入力が必要です。'),
            ('promotion', '联名信用卡新户送10000里程，点此申请。', 'Get 10,000 bonus miles with our co-brand card. Apply here.', '提携カード新規入会で1万マイル進呈。お申し込みはこちら。'),
        ]),
        ('moving-company', 'haulright', [
            ('life.logistics', '您的搬家货物已装车，预计明早到达新地址。', 'Your household goods are loaded and reach the new address tomorrow morning.', 'お荷物の積み込みが完了し、明朝新居に到着予定です。'),
            ('life.other', '您预约的搬家服务已确认，周六8点上门。', 'Your moving service is confirmed for Saturday at 8.', '引っ越しのご予約を確定しました。土曜8時に伺います。'),
            ('spam', '货物被扣押，须再付1200元押金到司机个人账户才放行。', 'Your goods are being held. Pay another 1,200 deposit to the driver\'s personal account to release them.', 'お荷物を留めています。運転手個人の口座へ追加で12万円を支払うと解放します。'),
            ('promotion', '搬家季特惠，老客户再享九折。', 'Moving season deal: returning customers get 10% off.', '引っ越しシーズン特典、リピーターは10%オフ。'),
        ]),
        ('mortgage-statement', 'homelend', [
            ('finance.bank', '您的房贷年度对账单已生成，登录网银可查看。', 'Your annual mortgage statement is ready. Log in to online banking.', '住宅ローンの年間明細を発行しました。ネットバンクでご確認ください。'),
            ('finance.bank', '您的提前还款申请已通过。', 'Your early mortgage repayment request is approved.', '繰上返済のお申し込みを承認しました。'),
            ('spam', '您的房贷账户异常，请立即点击登录并输入密码和短信码，否则收回房产。', 'Your mortgage account has a problem. Log in now with your password and SMS code or the home is repossessed.', '住宅ローン口座に異常があります。今すぐパスワードとSMSコードでログインしないと物件を差し押さえます。'),
            ('promotion', '房贷转贷利率低至3.1%，免费测算。', 'Refinance your mortgage from 3.1%. Free quote.', '住宅ローン借り換えは年3.1%から。無料試算受付中。'),
        ]),
        ('waste-collection', 'cityclean', [
            ('government.reminder', '本周起厨余垃圾请分类投放，感谢配合。', 'From this week please sort food waste separately. Thank you.', '今週から生ごみの分別にご協力をお願いします。'),
            ('government.notice', '您申请的大件垃圾清运已安排在周四上午。', 'Your bulky waste pickup is booked for Thursday morning.', 'ご申請の粗大ごみ収集は木曜午前に手配しました。'),
            ('spam', '您有垃圾处理费未缴将被起诉，请点击输入银行卡缴纳罚款。', 'Unpaid waste fees mean legal action. Enter your bank card here to pay the fine.', 'ごみ処理費の未納で提訴します。カード番号を入力して罰金を支払ってください。'),
            ('promotion', '智能垃圾桶新品八折，社区用户专享。', 'Smart bins 20% off for local residents.', 'スマートごみ箱が地域の方限定で20%オフ。'),
        ]),
        ('visa-application', 'visadesk', [
            ('government.notice', '您的签证申请已受理，进度可登录查询。', 'Your visa application is accepted. Log in to check progress.', 'ビザ申請を受理しました。進捗はログインしてご確認ください。'),
            ('government.other', '签证中心本周五因节假日暂停办公。', 'The visa centre is closed this Friday for a public holiday.', 'ビザセンターは祝日のため今週金曜は休業します。'),
            ('spam', '您的签证被拒，点击支付680元加急费并提供护照照片和银行卡。', 'Your visa was refused. Pay a 680 rush fee here and send your passport photo and bank card.', 'ビザが却下されました。特急料金6800円を支払い、パスポート画像とカード番号を送ってください。'),
            ('promotion', '留学移民讲座开放报名，现场咨询免费。', 'Study abroad seminar open for sign-up, with free advice on site.', '留学セミナー受付中。当日の相談は無料です。'),
        ]),
        ('kids-sports-club', 'playfield', [
            ('life.other', '本周六足球训练改到室内场，时间不变。', 'This Saturday football training moves indoors, same time.', '今週土曜のサッカー練習は屋内に変更、時間は同じです。'),
            ('transaction.member', '您孩子的俱乐部会籍已续费成功。', 'Your child\'s club membership has been renewed.', 'お子様のクラブ会員を更新しました。'),
            ('spam', '您孩子在训练中受伤住院，请马上向教练个人账户转3000元。', 'Your child was hurt at training and is in hospital. Send 3,000 to the coach\'s own account right now.', 'お子様が練習中に怪我で入院しました。今すぐコーチ個人の口座へ3万円を振り込んでください。'),
            ('promotion', '暑期足球夏令营开放报名，二孩半价。', 'Summer football camp is open, second child half price.', '夏のサッカーキャンプ受付中。2人目は半額。'),
        ]),
        ('cloud-storage', 'driftbox', [
            ('transaction.other', '您的云盘备份已完成，共同步1,204个文件。', 'Your cloud backup is finished, 1,204 files synced.', 'クラウドのバックアップが完了し、1,204個のファイルを同期しました。'),
            ('transaction.message', '同事在共享文件夹中给您留了评论，登录可查看。', 'A colleague left you a comment in a shared folder. Log in to view it.', '同僚が共有フォルダにコメントを残しました。ログインしてご覧ください。'),
            ('spam', '您的云盘将被删除，请立即点击输入账号密码并支付恢复费。', 'Your cloud files will be deleted. Enter your password and pay the recovery fee here now.', 'クラウドのデータが削除されます。今すぐパスワードを入力して復旧料金を支払ってください。'),
            ('promotion', '云盘2TB年付立减40元。', 'Get 40 off the 2 TB yearly cloud plan.', 'クラウド2TB年額プランが4000円引き。'),
        ]),
        ('freelance-invoice', 'paydesk', [
            ('finance.income', '客户支付的设计费5,200元已到账。', 'The client\'s 5,200 design fee has arrived in your account.', 'お客様からデザイン料52000円が入金されました。'),
            ('transaction.message', '客户在项目平台回复了您的报价。', 'A client replied to your quote on the project platform.', 'クライアントがプロジェクト画面で見積もりに返信しました。'),
            ('spam', '客户已付款，您需先交1,000元保证金解冻，再把验证码发给客服。', 'The client has paid. Pay a 1,000 unfreezing deposit first, then send the code to the agent.', 'お客様の支払いは完了しました。先に凍結解除の保証金1万円を払い、コードを担当者へ送ってください。'),
            ('promotion', '自由职业者记账软件首年半价。', 'Freelancer bookkeeping app, half price for your first year.', 'フリーランス向け会計アプリが初年度半額。'),
        ]),
        ('marketplace-seller', 'bazaaro', [
            ('transaction.message', '买家向您询问商品尺寸，请登录回复。', 'A buyer asked about the item size. Log in to reply.', '購入者からサイズの質問が届きました。ログインして返信してください。'),
            ('transaction.order', '您的商品已售出，请在两日内发货。', 'Your item sold. Please ship within two days.', '商品が売れました。2日以内に発送してください。'),
            ('spam', '买家已付款但被冻结，请点击填写银行卡和密码才能收款。', 'The buyer paid but the money is frozen. Enter your bank card and PIN here to receive it.', '購入者の支払いが凍結されました。受け取るにはカード番号と暗証番号を入力してください。'),
            ('promotion', '开通店铺推广，首周曝光翻倍。', 'Promote your shop and double your views in week one.', 'ショップ広告を始めると初週の表示が2倍に。'),
        ]),
    ]
