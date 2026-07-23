import Foundation

/// International seed templates. Each language covers the high-volume SMS
/// categories (verification, promo, spam, banking, delivery, travel, carrier,
/// order and account security); `en`/`zh` carry the full label coverage.
enum SeedTemplatesGlobal {
    static let templates: [SeedLanguage: [String: [String]]] = [
        .es: spanish,
        .pt: portuguese,
        .fr: french,
        .de: german,
        .ru: russian,
        .ko: korean,
        .id: indonesian,
        .vi: vietnamese,
        .th: thai
    ]

    // MARK: - Español

    static let spanish: [String: [String]] = [
        "verification": [
            "Tu código de verificación es {code}. Válido por {minutes} minutos. No lo compartas.",
            "Código de acceso: {code}. Si no fuiste tú, ignora este mensaje.",
            "{platform}: código de seguridad {code} para confirmar tu identidad.",
            "Código de pago {code}. Nunca lo reenvíes a nadie.",
            "Tu clave dinámica es {code}, caduca en {minutes} minutos."
        ],
        "promotion": [
            "¡Oferta flash! Miembros de {brand} ahorran ${amount} hoy. Responde BAJA para cancelar.",
            "{merchant}: rebajas de temporada hasta {percent}% de descuento {url}",
            "Día del socio: tus cupones ya están en tu cuenta de {brand}.",
            "Gran apertura de {merchant} en {city}: vale de ${amount} al presentar este SMS.",
            "Tus puntos de {bank} caducan el {date}. Canjéalos en {url}"
        ],
        "spam": [
            "¡GANASTE! Has sido seleccionado para un premio. Contacta al agente para reclamar.",
            "Préstamo inmediato sin buró, hasta ${amount2} solo con tu ID: {url}",
            "Tu paquete no pudo entregarse. Verifica tus datos en {url}",
            "Tu cuenta será suspendida. Evítalo verificando en {url}",
            "Gana ${amount} al día desde casa, sin experiencia. Escribe al {order}."
        ],
        "finance.bank": [
            "Cargo de ${amount} en tu cuenta terminación {tail} a las {time}. Si no fuiste tú, llama al banco.",
            "{bank}: abono recibido de ${amount}. Saldo disponible ${amount2}.",
            "Retiro en cajero de ${amount}, cuenta terminación {tail}.",
            "Transferencia de ${amount} enviada; llegará en {minutes} minutos.",
            "Tu comprobante electrónico está listo, operación {order}."
        ],
        "finance.credit_card": [
            "Tu estado de cuenta está listo: ${amount} a pagar antes del {date}.",
            "Pago automático programado: ${amount} el {date}.",
            "Pago recibido: ${amount} aplicado a tu tarjeta. Gracias.",
            "Pago mínimo ${amount} vence el {date}; evita intereses."
        ],
        "finance.consumption": [
            "Compra con tarjeta terminación {tail} por ${amount}.",
            "Pago de compra confirmado: ${amount} en {merchant}."
        ],
        "finance.income": [
            "Recibiste una transferencia de ${amount}. Nuevo saldo ${amount2}.",
            "Nómina depositada: ${amount2} en tu cuenta terminación {tail}.",
            "{name} te envió ${amount}. Ya está en tu saldo.",
            "Depósito en efectivo de ${amount} confirmado."
        ],
        "life.express": [
            "Tu paquete llegó a {station} y se prepara para la entrega.",
            "Pedido en reparto: llega hoy.",
            "{courier}: tu paquete está en camino con el repartidor.",
            "Entrega fallida; reintentaremos mañana.",
            "{courier}: el envío {order} salió de {city} y está en tránsito."
        ],
        "life.pickup_code": [
            "Paquete en {station}. Código de retiro {code}.",
            "Casillero {count} asignado. Tu código es {code}.",
            "Retira tu paquete con el código {code} en {station}.",
            "Recuerda: tu paquete lleva {days} días esperando. Código {code}."
        ],
        "travel.ticketing": [
            "Vuelo emitido: {flight}. ¡Buen viaje!",
            "Reserva de tren confirmada: {train}, sale a las {time}.",
            "Entradas emitidas. Ingresa con el código {code}.",
            "Cambio confirmado: nueva salida {date} {time}.",
            "Check-in disponible para el vuelo {flight}. Elige tu asiento."
        ],
        "carrier.data_reminder": [
            "Has usado {count}GB este mes. Te quedan {remain}GB.",
            "{carrier}: te quedan {remain}GB de datos nacionales.",
            "Saldo bajo: menos de ${amount}. Recarga para seguir conectado.",
            "Has consumido el {percent}% de tus datos; aplican tarifas extra al superar el plan."
        ],
        "transaction.order": [
            "Pedido {order} pagado. El vendedor prepara tu compra.",
            "¡Tu pedido fue enviado! Síguelo en la app.",
            "Pedido {order} cancelado; el cargo será revertido.",
            "La tienda aceptó tu pedido, listo en {minutes} minutos."
        ],
        "transaction.account_security": [
            "Alerta de seguridad: inicio de sesión desde un nuevo dispositivo. ¿Fuiste tú?",
            "Tu contraseña se cambió a las {time}.",
            "Nuevo acceso desde {city} a las {time}. Revisa tu actividad.",
            "Se solicitó cambiar el teléfono de tu cuenta; congélala si no fuiste tú."
        ]
    ]

    // MARK: - Português

    static let portuguese: [String: [String]] = [
        "verification": [
            "Seu código de verificação é {code}. Válido por {minutes} minutos. Não compartilhe.",
            "Código de login: {code}. Se não foi você, ignore.",
            "{platform}: código de segurança {code} para confirmar sua identidade.",
            "Código de pagamento {code}. Nunca repasse a ninguém.",
            "Sua senha dinâmica é {code}, expira em {minutes} minutos."
        ],
        "promotion": [
            "Oferta relâmpago! Membros {brand} economizam R${amount} hoje. Responda SAIR para cancelar.",
            "{merchant}: liquidação com até {percent}% de desconto {url}",
            "Dia do sócio: seus cupons já estão na conta {brand}.",
            "Inauguração da {merchant} em {city}: vale de R${amount} apresentando este SMS.",
            "Seus pontos do {bank} vencem em {date}. Troque em {url}"
        ],
        "spam": [
            "PARABÉNS! Você foi sorteado. Fale com o atendente para resgatar o prêmio.",
            "Empréstimo na hora sem consulta, até R${amount2} só com RG: {url}",
            "Sua encomenda não pôde ser entregue. Atualize seus dados em {url}",
            "Sua conta será bloqueada. Regularize agora em {url}",
            "Ganhe R${amount} por dia em casa, sem experiência. Chame {order}."
        ],
        "finance.bank": [
            "Débito de R${amount} na conta final {tail} às {time}. Não reconhece? Ligue para o banco.",
            "{bank}: crédito recebido de R${amount}. Saldo disponível R${amount2}.",
            "Saque no caixa eletrônico de R${amount}, conta final {tail}.",
            "Transferência de R${amount} enviada; chega em {minutes} minutos.",
            "Seu comprovante eletrônico está pronto, operação {order}."
        ],
        "finance.credit_card": [
            "Sua fatura fechou: R${amount} com vencimento em {date}.",
            "Débito automático agendado: R${amount} em {date}.",
            "Pagamento recebido: R${amount} creditado no cartão. Obrigado.",
            "Pagamento mínimo de R${amount} vence em {date}; evite juros."
        ],
        "finance.consumption": [
            "Compra no cartão final {tail} de R${amount}.",
            "Pagamento de compra confirmado: R${amount} em {merchant}."
        ],
        "finance.income": [
            "Você recebeu uma transferência de R${amount}. Novo saldo R${amount2}.",
            "Salário depositado: R${amount2} na conta final {tail}.",
            "{name} enviou R${amount} para você. Já está no seu saldo.",
            "Depósito em dinheiro de R${amount} confirmado."
        ],
        "life.express": [
            "Sua encomenda chegou em {station} e está sendo preparada para entrega.",
            "Pedido saiu para entrega: chega hoje.",
            "{courier}: seu pacote está com o entregador.",
            "Tentativa de entrega falhou; tentaremos amanhã.",
            "{courier}: o envio {order} saiu de {city} e está em trânsito."
        ],
        "life.pickup_code": [
            "Encomenda em {station}. Código de retirada {code}.",
            "Armário {count} reservado. Seu código é {code}.",
            "Retire seu pacote com o código {code} em {station}.",
            "Lembrete: sua encomenda aguarda há {days} dias. Código {code}."
        ],
        "travel.ticketing": [
            "Passagem emitida: voo {flight}. Boa viagem!",
            "Reserva de trem confirmada: {train}, partida às {time}.",
            "Ingressos emitidos. Entre com o código {code}.",
            "Remarcação confirmada: nova partida {date} {time}.",
            "Check-in aberto para o voo {flight}. Escolha seu assento."
        ],
        "carrier.data_reminder": [
            "Você usou {count}GB este mês. Restam {remain}GB.",
            "{carrier}: restam {remain}GB de internet.",
            "Saldo baixo: menos de R${amount}. Recarregue para continuar conectado.",
            "Você consumiu {percent}% da franquia; tarifas extras após o limite."
        ],
        "transaction.order": [
            "Pedido {order} pago. O vendedor está preparando o envio.",
            "Seu pedido foi enviado! Acompanhe no app.",
            "Pedido {order} cancelado; o valor será estornado.",
            "A loja aceitou seu pedido, pronto em {minutes} minutos."
        ],
        "transaction.account_security": [
            "Alerta de segurança: login em novo dispositivo. Foi você?",
            "Sua senha foi alterada às {time}.",
            "Novo acesso de {city} às {time}. Revise sua atividade.",
            "Troca de telefone solicitada na sua conta; bloqueie se não foi você."
        ]
    ]

    // MARK: - Français

    static let french: [String: [String]] = [
        "verification": [
            "Votre code de vérification est {code}. Valable {minutes} minutes. Ne le partagez pas.",
            "Code de connexion : {code}. Si ce n'était pas vous, ignorez ce message.",
            "{platform} : code de sécurité {code} pour confirmer votre identité.",
            "Code de paiement {code}. Ne le transmettez à personne.",
            "Votre mot de passe à usage unique est {code}, valable {minutes} minutes."
        ],
        "promotion": [
            "Vente flash ! Les membres {brand} économisent {amount} € aujourd'hui. STOP pour vous désabonner.",
            "{merchant} : soldes jusqu'à -{percent}% {url}",
            "Journée membres : vos bons d'achat sont dans votre compte {brand}.",
            "Ouverture de {merchant} à {city} : bon de {amount} € sur présentation de ce SMS.",
            "Vos points {bank} expirent le {date}. Échangez-les sur {url}"
        ],
        "spam": [
            "FÉLICITATIONS ! Vous avez gagné un lot. Contactez l'agent pour le récupérer.",
            "Crédit immédiat sans justificatif, jusqu'à {amount2} € : {url}",
            "Votre colis n'a pas pu être livré. Vérifiez vos coordonnées sur {url}",
            "Votre compte sera suspendu. Régularisez sur {url}",
            "Gagnez {amount} €/jour depuis chez vous, sans expérience. Contact {order}."
        ],
        "finance.bank": [
            "Débit de {amount} € sur le compte se terminant par {tail} à {time}. Contactez-nous si ce n'était pas vous.",
            "{bank} : virement reçu de {amount} €. Solde disponible {amount2} €.",
            "Retrait DAB de {amount} €, compte se terminant par {tail}.",
            "Virement de {amount} € envoyé ; arrivée sous {minutes} minutes.",
            "Votre reçu électronique est prêt, opération {order}."
        ],
        "finance.credit_card": [
            "Votre relevé est disponible : {amount} € à régler avant le {date}.",
            "Prélèvement automatique prévu : {amount} € le {date}.",
            "Paiement reçu : {amount} € crédités sur votre carte. Merci.",
            "Paiement minimum de {amount} € dû le {date} ; évitez les intérêts."
        ],
        "finance.consumption": [
            "Achat carte se terminant par {tail} : {amount} €.",
            "Paiement d'achat confirmé : {amount} € chez {merchant}."
        ],
        "finance.income": [
            "Vous avez reçu un virement de {amount} €. Nouveau solde {amount2} €.",
            "Salaire versé : {amount2} € sur le compte se terminant par {tail}.",
            "{name} vous a envoyé {amount} €. C'est dans votre solde.",
            "Dépôt d'espèces de {amount} € confirmé."
        ],
        "life.express": [
            "Votre colis est arrivé au {station} et se prépare pour la livraison.",
            "Colis en cours de livraison : il arrive aujourd'hui.",
            "{courier} : votre colis est avec le livreur.",
            "Échec de livraison ; nouvelle tentative demain.",
            "{courier} : l'envoi {order} a quitté {city} et est en transit."
        ],
        "life.pickup_code": [
            "Colis au {station}. Code de retrait {code}.",
            "Consigne {count} attribuée. Votre code est {code}.",
            "Retirez votre colis avec le code {code} au {station}.",
            "Rappel : votre colis attend depuis {days} jours. Code {code}."
        ],
        "travel.ticketing": [
            "Billet émis : vol {flight}. Bon voyage !",
            "Réservation de train confirmée : {train}, départ à {time}.",
            "Billets émis. Entrez avec le code {code}.",
            "Échange confirmé : nouveau départ le {date} à {time}.",
            "Enregistrement ouvert pour le vol {flight}. Choisissez votre siège."
        ],
        "carrier.data_reminder": [
            "Vous avez consommé {count} Go ce mois-ci. Il reste {remain} Go.",
            "{carrier} : il vous reste {remain} Go d'internet.",
            "Crédit faible : moins de {amount} €. Rechargez pour rester connecté.",
            "Vous avez utilisé {percent}% de votre forfait ; hors forfait facturé au-delà."
        ],
        "transaction.order": [
            "Commande {order} payée. Le vendeur prépare votre colis.",
            "Votre commande a été expédiée ! Suivez-la dans l'app.",
            "Commande {order} annulée ; le montant sera remboursé.",
            "Le magasin a accepté votre commande, prête dans {minutes} minutes."
        ],
        "transaction.account_security": [
            "Alerte sécurité : connexion depuis un nouvel appareil. Était-ce vous ?",
            "Votre mot de passe a été modifié à {time}.",
            "Nouvelle connexion depuis {city} à {time}. Vérifiez votre activité.",
            "Changement de numéro demandé sur votre compte ; bloquez-le si ce n'était pas vous."
        ]
    ]

    // MARK: - Deutsch

    static let german: [String: [String]] = [
        "verification": [
            "Ihr Bestätigungscode lautet {code}. Gültig für {minutes} Minuten. Nicht weitergeben.",
            "Login-Code: {code}. Falls Sie das nicht waren, ignorieren Sie diese Nachricht.",
            "{platform}: Sicherheitscode {code} zur Identitätsbestätigung.",
            "Zahlungscode {code}. Geben Sie ihn niemals weiter.",
            "Ihr Einmalpasswort ist {code}, gültig für {minutes} Minuten."
        ],
        "promotion": [
            "Blitzangebot! {brand}-Mitglieder sparen heute {amount} €. STOP zum Abmelden.",
            "{merchant}: Sale mit bis zu {percent}% Rabatt {url}",
            "Mitgliedertag: Ihre Gutscheine liegen im {brand}-Konto bereit.",
            "Neueröffnung {merchant} in {city}: {amount} €-Gutschein gegen Vorlage dieser SMS.",
            "Ihre {bank}-Punkte verfallen am {date}. Einlösen unter {url}"
        ],
        "spam": [
            "GLÜCKWUNSCH! Sie wurden ausgelost. Melden Sie sich beim Agenten für Ihren Gewinn.",
            "Sofortkredit ohne Schufa, bis {amount2} € nur mit Ausweis: {url}",
            "Ihr Paket konnte nicht zugestellt werden. Daten prüfen unter {url}",
            "Ihr Konto wird gesperrt. Jetzt verifizieren unter {url}",
            "Verdienen Sie {amount} €/Tag von zu Hause, keine Erfahrung nötig. Kontakt {order}."
        ],
        "finance.bank": [
            "Abbuchung von {amount} € vom Konto mit Endziffern {tail} um {time}. Nicht Sie? Rufen Sie uns an.",
            "{bank}: Gutschrift über {amount} € erhalten. Verfügbarer Saldo {amount2} €.",
            "Geldautomat: Abhebung von {amount} €, Konto Endziffern {tail}.",
            "Überweisung über {amount} € gesendet; Eingang in {minutes} Minuten.",
            "Ihr elektronischer Beleg ist bereit, Vorgang {order}."
        ],
        "finance.credit_card": [
            "Ihre Abrechnung ist da: {amount} € fällig am {date}.",
            "Lastschrift geplant: {amount} € am {date}.",
            "Zahlung eingegangen: {amount} € Ihrer Karte gutgeschrieben. Danke.",
            "Mindestzahlung {amount} € fällig am {date}; vermeiden Sie Zinsen."
        ],
        "finance.consumption": [
            "Kartenzahlung Endziffern {tail}: {amount} €.",
            "Kaufzahlung bestätigt: {amount} € bei {merchant}."
        ],
        "finance.income": [
            "Sie haben eine Überweisung über {amount} € erhalten. Neuer Saldo {amount2} €.",
            "Gehalt eingegangen: {amount2} € auf Konto Endziffern {tail}.",
            "{name} hat Ihnen {amount} € gesendet. Bereits im Guthaben.",
            "Bareinzahlung von {amount} € bestätigt."
        ],
        "life.express": [
            "Ihr Paket ist in der {station} angekommen und wird für die Zustellung vorbereitet.",
            "Paket in Zustellung: es kommt heute an.",
            "{courier}: Ihr Paket ist beim Zusteller.",
            "Zustellung fehlgeschlagen; neuer Versuch morgen.",
            "{courier}: Sendung {order} hat {city} verlassen und ist unterwegs."
        ],
        "life.pickup_code": [
            "Paket in der {station}. Abholcode {code}.",
            "Fach {count} reserviert. Ihr Code ist {code}.",
            "Holen Sie Ihr Paket mit Code {code} in der {station} ab.",
            "Erinnerung: Ihr Paket wartet seit {days} Tagen. Code {code}."
        ],
        "travel.ticketing": [
            "Ticket ausgestellt: Flug {flight}. Gute Reise!",
            "Zugbuchung bestätigt: {train}, Abfahrt {time}.",
            "Tickets ausgestellt. Einlass mit Code {code}.",
            "Umbuchung bestätigt: neue Abfahrt {date} {time}.",
            "Check-in für Flug {flight} geöffnet. Sitzplatz wählen."
        ],
        "carrier.data_reminder": [
            "Sie haben diesen Monat {count} GB verbraucht. Noch {remain} GB übrig.",
            "{carrier}: noch {remain} GB Datenvolumen verfügbar.",
            "Guthaben niedrig: unter {amount} €. Jetzt aufladen.",
            "Sie haben {percent}% Ihres Datenvolumens verbraucht; danach gelten Zusatztarife."
        ],
        "transaction.order": [
            "Bestellung {order} bezahlt. Der Händler bereitet den Versand vor.",
            "Ihre Bestellung wurde versandt! Verfolgen Sie sie in der App.",
            "Bestellung {order} storniert; der Betrag wird erstattet.",
            "Das Geschäft hat Ihre Bestellung angenommen, fertig in {minutes} Minuten."
        ],
        "transaction.account_security": [
            "Sicherheitswarnung: Anmeldung von neuem Gerät. Waren Sie das?",
            "Ihr Passwort wurde um {time} geändert.",
            "Neue Anmeldung aus {city} um {time}. Prüfen Sie Ihre Kontoaktivität.",
            "Rufnummernwechsel für Ihr Konto beantragt; sperren Sie es, falls Sie das nicht waren."
        ]
    ]

    // MARK: - Русский

    static let russian: [String: [String]] = [
        "verification": [
            "Ваш код подтверждения: {code}. Действителен {minutes} минут. Никому не сообщайте.",
            "Код для входа: {code}. Если это не вы — проигнорируйте сообщение.",
            "{platform}: код безопасности {code} для подтверждения личности.",
            "Код оплаты {code}. Никому не пересылайте.",
            "Ваш одноразовый пароль: {code}, действует {minutes} минут."
        ],
        "promotion": [
            "Флеш-распродажа! Участники {brand} экономят {amount} ₽ сегодня. СТОП — отписка.",
            "{merchant}: скидки до {percent}% {url}",
            "День клиента: купоны уже в вашем аккаунте {brand}.",
            "Открытие {merchant} в {city}: купон на {amount} ₽ по этому SMS.",
            "Баллы {bank} сгорают {date}. Обменяйте на {url}"
        ],
        "spam": [
            "ПОЗДРАВЛЯЕМ! Вы выиграли приз. Свяжитесь с оператором для получения.",
            "Займ за 5 минут без проверок, до {amount2} ₽ по паспорту: {url}",
            "Ваша посылка не доставлена. Подтвердите данные: {url}",
            "Ваш аккаунт будет заблокирован. Подтвердите: {url}",
            "Зарабатывайте {amount} ₽ в день из дома, без опыта. Пишите {order}."
        ],
        "finance.bank": [
            "Списание {amount} ₽ со счёта *{tail} в {time}. Если это не вы — позвоните в банк.",
            "{bank}: поступление {amount} ₽. Доступный остаток {amount2} ₽.",
            "Снятие наличных {amount} ₽ в банкомате, счёт *{tail}.",
            "Перевод {amount} ₽ отправлен; поступит в течение {minutes} минут.",
            "Электронная квитанция готова, операция {order}."
        ],
        "finance.credit_card": [
            "Выписка готова: к оплате {amount} ₽ до {date}.",
            "Автоплатёж: {amount} ₽ спишется {date}.",
            "Платёж получен: {amount} ₽ зачислено на карту. Спасибо.",
            "Минимальный платёж {amount} ₽ до {date}; не допускайте просрочки."
        ],
        "finance.consumption": [
            "Покупка по карте *{tail}: {amount} ₽.",
            "Оплата покупки подтверждена: {amount} ₽ в {merchant}."
        ],
        "finance.income": [
            "Вам перевели {amount} ₽. Новый баланс {amount2} ₽.",
            "Зарплата зачислена: {amount2} ₽ на счёт *{tail}.",
            "{name} отправил(а) вам {amount} ₽. Уже на балансе.",
            "Внесение наличных {amount} ₽ подтверждено."
        ],
        "life.express": [
            "Посылка прибыла в {station} и готовится к доставке.",
            "Заказ передан курьеру: доставка сегодня.",
            "{courier}: ваша посылка у курьера.",
            "Доставка не удалась; повторим завтра.",
            "{courier}: отправление {order} покинуло {city}, в пути."
        ],
        "life.pickup_code": [
            "Посылка в {station}. Код получения {code}.",
            "Ячейка {count} закреплена. Ваш код {code}.",
            "Заберите посылку по коду {code} в {station}.",
            "Напоминание: посылка ждёт уже {days} дней. Код {code}."
        ],
        "travel.ticketing": [
            "Билет оформлен: рейс {flight}. Хорошего полёта!",
            "Бронь поезда подтверждена: {train}, отправление {time}.",
            "Билеты оформлены. Вход по коду {code}.",
            "Обмен подтверждён: новое отправление {date} {time}.",
            "Открыта регистрация на рейс {flight}. Выберите место."
        ],
        "carrier.data_reminder": [
            "Вы израсходовали {count} ГБ в этом месяце. Осталось {remain} ГБ.",
            "{carrier}: осталось {remain} ГБ интернета.",
            "Баланс менее {amount} ₽. Пополните счёт, чтобы оставаться на связи.",
            "Использовано {percent}% трафика; сверх пакета — по повышенному тарифу."
        ],
        "transaction.order": [
            "Заказ {order} оплачен. Продавец готовит отправку.",
            "Ваш заказ отправлен! Отслеживайте в приложении.",
            "Заказ {order} отменён; средства будут возвращены.",
            "Магазин принял заказ, будет готов через {minutes} минут."
        ],
        "transaction.account_security": [
            "Внимание: вход с нового устройства. Это были вы?",
            "Ваш пароль изменён в {time}.",
            "Новый вход из города {city} в {time}. Проверьте активность.",
            "Запрошена смена номера телефона аккаунта; заблокируйте его, если это не вы."
        ]
    ]

    // MARK: - 한국어

    static let korean: [String: [String]] = [
        "verification": [
            "인증번호는 {code}입니다. {minutes}분간 유효합니다. 타인에게 알려주지 마세요.",
            "로그인 인증번호: {code}. 본인이 아니면 무시하세요.",
            "{platform}: 본인 확인용 보안코드 {code}.",
            "결제 인증번호 {code}. 절대 전달하지 마세요.",
            "일회용 비밀번호는 {code}이며 {minutes}분 후 만료됩니다."
        ],
        "promotion": [
            "(광고) 반짝 세일! {brand} 회원 오늘 {amount}원 할인. 무료거부 0808001234",
            "{merchant}: 최대 {percent}% 할인 세일 {url}",
            "회원의 날: 쿠폰이 {brand} 계정에 지급되었습니다.",
            "{merchant} {city}점 오픈! 이 문자 제시 시 {amount}원 상품권 증정.",
            "{bank} 포인트가 {date} 소멸됩니다. {url} 에서 교환하세요."
        ],
        "spam": [
            "축하합니다! 경품에 당첨되셨습니다. 상담원에게 연락해 수령하세요.",
            "무심사 즉시 대출, 신분증만으로 최대 {amount2}원: {url}",
            "택배가 배송되지 못했습니다. 정보를 확인하세요 {url}",
            "계정이 정지될 예정입니다. 지금 인증하세요 {url}",
            "재택 알바 일당 {amount}원, 경력 무관. {order} 로 연락주세요."
        ],
        "finance.bank": [
            "끝자리 {tail} 계좌에서 {time}에 {amount}원이 출금되었습니다. 본인이 아니면 즉시 연락하세요.",
            "{bank}: {amount}원 입금. 잔액 {amount2}원.",
            "ATM 출금 {amount}원, 계좌 끝자리 {tail}.",
            "{amount}원 이체가 접수되었습니다. {minutes}분 내 입금 예정.",
            "전자 영수증이 발급되었습니다. 거래번호 {order}."
        ],
        "finance.credit_card": [
            "청구서가 확정되었습니다: {amount}원, 납부 기한 {date}.",
            "자동납부 예정: {date}에 {amount}원 출금.",
            "결제 확인: 카드에 {amount}원 입금되었습니다. 감사합니다.",
            "최소 결제금액 {amount}원의 기한은 {date}입니다. 연체에 유의하세요."
        ],
        "finance.consumption": [
            "끝자리 {tail} 카드로 {amount}원 결제되었습니다.",
            "구매 결제 완료: {merchant}에서 {amount}원."
        ],
        "finance.income": [
            "{amount}원 이체를 받았습니다. 새 잔액 {amount2}원.",
            "급여 입금: 끝자리 {tail} 계좌로 {amount2}원.",
            "{name}님이 {amount}원을 보냈습니다. 잔액에 반영되었습니다.",
            "현금 {amount}원 입금이 확인되었습니다."
        ],
        "life.express": [
            "택배가 {station}에 도착해 배송 준비 중입니다.",
            "오늘 배송 예정입니다. 상품을 받아주세요.",
            "{courier}: 기사님이 배송 중입니다.",
            "배송에 실패했습니다. 내일 다시 시도합니다.",
            "{courier}: 운송장 {order} 상품이 {city}에서 출발했습니다."
        ],
        "life.pickup_code": [
            "{station}에 택배가 보관 중입니다. 수령 코드 {code}.",
            "무인함 {count}번에 보관했습니다. 코드는 {code}입니다.",
            "코드 {code}로 {station}에서 찾아가세요.",
            "보관 {days}일이 지났습니다. 코드 {code}로 빨리 수령해주세요."
        ],
        "travel.ticketing": [
            "항공권이 발권되었습니다: {flight}편. 즐거운 여행 되세요!",
            "기차 예매 완료: {train}, {time} 출발.",
            "티켓이 발권되었습니다. 입장 코드 {code}.",
            "변경 완료: 새 출발 시간 {date} {time}.",
            "{flight}편 온라인 체크인이 시작되었습니다. 좌석을 선택하세요."
        ],
        "carrier.data_reminder": [
            "이번 달 {count}GB 사용, 잔여 {remain}GB입니다.",
            "{carrier}: 데이터 잔여량 {remain}GB.",
            "잔액이 {amount}원 미만입니다. 충전해 주세요.",
            "데이터의 {percent}%를 사용했습니다. 초과분은 추가 요금이 부과됩니다."
        ],
        "transaction.order": [
            "주문 {order} 결제 완료. 판매자가 상품을 준비 중입니다.",
            "주문하신 상품이 발송되었습니다! 앱에서 확인하세요.",
            "주문 {order}이 취소되었습니다. 결제 금액은 환불됩니다.",
            "매장이 주문을 접수했습니다. 약 {minutes}분 후 준비 완료."
        ],
        "transaction.account_security": [
            "보안 알림: 새 기기에서 로그인이 감지되었습니다. 본인이신가요?",
            "{time}에 비밀번호가 변경되었습니다.",
            "{city}에서 {time}에 새 로그인이 있었습니다. 활동을 확인하세요.",
            "계정 전화번호 변경이 요청되었습니다. 본인이 아니면 계정을 잠그세요."
        ]
    ]

    // MARK: - Bahasa Indonesia

    static let indonesian: [String: [String]] = [
        "verification": [
            "Kode verifikasi Anda: {code}. Berlaku {minutes} menit. Jangan bagikan.",
            "Kode login: {code}. Abaikan jika bukan Anda.",
            "{platform}: kode keamanan {code} untuk konfirmasi identitas.",
            "Kode pembayaran {code}. Jangan pernah diteruskan ke siapa pun.",
            "Kata sandi sekali pakai Anda {code}, kedaluwarsa dalam {minutes} menit."
        ],
        "promotion": [
            "Flash sale! Member {brand} hemat Rp{amount}.000 hari ini. Balas STOP untuk berhenti.",
            "{merchant}: diskon hingga {percent}% {url}",
            "Hari member: kupon sudah masuk ke akun {brand} Anda.",
            "Grand opening {merchant} di {city}: voucher Rp{amount}.000 dengan menunjukkan SMS ini.",
            "Poin {bank} Anda hangus {date}. Tukarkan di {url}"
        ],
        "spam": [
            "SELAMAT! Anda terpilih mendapat hadiah. Hubungi agen untuk klaim.",
            "Pinjaman cair 5 menit tanpa BI checking, hingga Rp{amount2}.000: {url}",
            "Paket Anda gagal dikirim. Verifikasi data di {url}",
            "Akun Anda akan diblokir. Segera verifikasi di {url}",
            "Kerja dari rumah Rp{amount}.000/hari, tanpa pengalaman. Hubungi {order}."
        ],
        "finance.bank": [
            "Debit Rp{amount}.000 dari rekening akhiran {tail} pukul {time}. Bukan Anda? Hubungi bank.",
            "{bank}: dana masuk Rp{amount}.000. Saldo tersedia Rp{amount2}.000.",
            "Tarik tunai ATM Rp{amount}.000, rekening akhiran {tail}.",
            "Transfer Rp{amount}.000 terkirim; tiba dalam {minutes} menit.",
            "Bukti transaksi elektronik siap, nomor {order}."
        ],
        "finance.credit_card": [
            "Tagihan Anda terbit: Rp{amount}.000 jatuh tempo {date}.",
            "Autodebit terjadwal: Rp{amount}.000 pada {date}.",
            "Pembayaran diterima: Rp{amount}.000 masuk ke kartu Anda. Terima kasih.",
            "Pembayaran minimum Rp{amount}.000 jatuh tempo {date}; hindari bunga."
        ],
        "finance.consumption": [
            "Transaksi kartu akhiran {tail} sebesar Rp{amount}.000.",
            "Pembayaran pembelian dikonfirmasi: Rp{amount}.000 di {merchant}."
        ],
        "finance.income": [
            "Anda menerima transfer Rp{amount}.000. Saldo baru Rp{amount2}.000.",
            "Gaji masuk: Rp{amount2}.000 ke rekening akhiran {tail}.",
            "{name} mengirim Rp{amount}.000. Sudah masuk saldo Anda.",
            "Setoran tunai Rp{amount}.000 dikonfirmasi."
        ],
        "life.express": [
            "Paket Anda tiba di {station} dan sedang disiapkan untuk pengiriman.",
            "Paket sedang diantar: tiba hari ini.",
            "{courier}: paket Anda bersama kurir.",
            "Pengiriman gagal; akan dicoba lagi besok.",
            "{courier}: kiriman {order} berangkat dari {city}, dalam perjalanan."
        ],
        "life.pickup_code": [
            "Paket di {station}. Kode ambil {code}.",
            "Loker {count} terisi. Kode Anda {code}.",
            "Ambil paket dengan kode {code} di {station}.",
            "Pengingat: paket menunggu {days} hari. Kode {code}."
        ],
        "travel.ticketing": [
            "Tiket terbit: penerbangan {flight}. Selamat jalan!",
            "Pemesanan kereta dikonfirmasi: {train}, berangkat {time}.",
            "Tiket acara terbit. Masuk dengan kode {code}.",
            "Reschedule berhasil: keberangkatan baru {date} {time}.",
            "Check-in online penerbangan {flight} dibuka. Pilih kursi Anda."
        ],
        "carrier.data_reminder": [
            "Anda memakai {count}GB bulan ini. Sisa {remain}GB.",
            "{carrier}: kuota tersisa {remain}GB.",
            "Pulsa di bawah Rp{amount}.000. Isi ulang agar tetap terhubung.",
            "Kuota terpakai {percent}%; kelebihan dikenakan tarif tambahan."
        ],
        "transaction.order": [
            "Pesanan {order} dibayar. Penjual sedang menyiapkan barang.",
            "Pesanan Anda dikirim! Lacak di aplikasi.",
            "Pesanan {order} dibatalkan; dana akan dikembalikan.",
            "Toko menerima pesanan Anda, siap dalam {minutes} menit."
        ],
        "transaction.account_security": [
            "Peringatan keamanan: login dari perangkat baru. Apakah ini Anda?",
            "Kata sandi Anda diubah pukul {time}.",
            "Login baru dari {city} pukul {time}. Periksa aktivitas akun.",
            "Permintaan ganti nomor telepon akun terdeteksi; bekukan akun jika bukan Anda."
        ]
    ]

    // MARK: - Tiếng Việt

    static let vietnamese: [String: [String]] = [
        "verification": [
            "Mã xác minh của bạn là {code}. Hiệu lực {minutes} phút. Không chia sẻ cho ai.",
            "Mã đăng nhập: {code}. Nếu không phải bạn, hãy bỏ qua.",
            "{platform}: mã bảo mật {code} để xác nhận danh tính.",
            "Mã thanh toán {code}. Tuyệt đối không chuyển tiếp.",
            "Mật khẩu dùng một lần của bạn là {code}, hết hạn sau {minutes} phút."
        ],
        "promotion": [
            "Flash sale! Thành viên {brand} giảm {amount}.000đ hôm nay. Soạn TC gửi 996 để hủy.",
            "{merchant}: giảm giá đến {percent}% {url}",
            "Ngày hội thành viên: mã giảm giá đã vào tài khoản {brand} của bạn.",
            "Khai trương {merchant} tại {city}: tặng voucher {amount}.000đ khi xuất trình SMS này.",
            "Điểm {bank} của bạn hết hạn ngày {date}. Đổi quà tại {url}"
        ],
        "spam": [
            "CHÚC MỪNG! Bạn trúng thưởng. Liên hệ nhân viên để nhận quà.",
            "Vay nhanh 5 phút không thẩm định, tới {amount2}.000đ chỉ cần CMND: {url}",
            "Bưu kiện của bạn giao không thành công. Xác nhận thông tin tại {url}",
            "Tài khoản của bạn sắp bị khóa. Xác minh ngay tại {url}",
            "Việc nhẹ tại nhà {amount}.000đ/ngày, không cần kinh nghiệm. Liên hệ {order}."
        ],
        "finance.bank": [
            "Tài khoản đuôi {tail} bị trừ {amount}.000đ lúc {time}. Không phải bạn? Gọi ngân hàng ngay.",
            "{bank}: nhận {amount}.000đ. Số dư khả dụng {amount2}.000đ.",
            "Rút tiền ATM {amount}.000đ, tài khoản đuôi {tail}.",
            "Chuyển khoản {amount}.000đ đã gửi; đến trong {minutes} phút.",
            "Biên lai điện tử đã sẵn sàng, giao dịch {order}."
        ],
        "finance.credit_card": [
            "Sao kê đã chốt: {amount}.000đ, hạn thanh toán {date}.",
            "Thanh toán tự động: {amount}.000đ vào ngày {date}.",
            "Đã nhận thanh toán: {amount}.000đ ghi có vào thẻ. Cảm ơn bạn.",
            "Khoản tối thiểu {amount}.000đ đến hạn {date}; tránh phát sinh lãi."
        ],
        "finance.consumption": [
            "Thẻ đuôi {tail} vừa chi tiêu {amount}.000đ.",
            "Đã xác nhận thanh toán mua hàng: {amount}.000đ tại {merchant}."
        ],
        "finance.income": [
            "Bạn nhận được {amount}.000đ. Số dư mới {amount2}.000đ.",
            "Lương đã về: {amount2}.000đ vào tài khoản đuôi {tail}.",
            "{name} vừa chuyển cho bạn {amount}.000đ.",
            "Nộp tiền mặt {amount}.000đ thành công."
        ],
        "life.express": [
            "Bưu kiện đã đến {station} và đang chuẩn bị giao.",
            "Đơn hàng đang giao: đến trong hôm nay.",
            "{courier}: shipper đang giao hàng cho bạn.",
            "Giao hàng không thành công; sẽ giao lại vào ngày mai.",
            "{courier}: kiện hàng {order} rời {city}, đang vận chuyển."
        ],
        "life.pickup_code": [
            "Bưu kiện tại {station}. Mã nhận {code}.",
            "Tủ số {count} đã có hàng. Mã của bạn là {code}.",
            "Nhận hàng bằng mã {code} tại {station}.",
            "Nhắc nhở: kiện hàng đã chờ {days} ngày. Mã {code}."
        ],
        "travel.ticketing": [
            "Vé máy bay đã xuất: chuyến {flight}. Chúc thượng lộ bình an!",
            "Đặt vé tàu thành công: {train}, khởi hành {time}.",
            "Vé sự kiện đã xuất. Vào cổng bằng mã {code}.",
            "Đổi vé thành công: giờ khởi hành mới {date} {time}.",
            "Chuyến {flight} đã mở check-in online. Chọn chỗ ngồi ngay."
        ],
        "carrier.data_reminder": [
            "Bạn đã dùng {count}GB trong tháng. Còn lại {remain}GB.",
            "{carrier}: dung lượng còn {remain}GB.",
            "Tài khoản dưới {amount}.000đ. Nạp thêm để tiếp tục sử dụng.",
            "Đã dùng {percent}% dung lượng; vượt gói tính phí phát sinh."
        ],
        "transaction.order": [
            "Đơn {order} đã thanh toán. Người bán đang chuẩn bị hàng.",
            "Đơn hàng của bạn đã được gửi đi! Theo dõi trong ứng dụng.",
            "Đơn {order} đã hủy; tiền sẽ được hoàn lại.",
            "Cửa hàng đã nhận đơn, sẵn sàng sau {minutes} phút."
        ],
        "transaction.account_security": [
            "Cảnh báo bảo mật: đăng nhập từ thiết bị mới. Có phải bạn không?",
            "Mật khẩu của bạn được đổi lúc {time}.",
            "Đăng nhập mới từ {city} lúc {time}. Kiểm tra hoạt động tài khoản.",
            "Có yêu cầu đổi số điện thoại tài khoản; hãy khóa tài khoản nếu không phải bạn."
        ]
    ]

    // MARK: - ไทย

    static let thai: [String: [String]] = [
        "verification": [
            "รหัสยืนยันของคุณคือ {code} ใช้ได้ {minutes} นาที ห้ามบอกผู้อื่น",
            "รหัสเข้าสู่ระบบ: {code} หากไม่ใช่คุณโปรดละเว้น",
            "{platform}: รหัสความปลอดภัย {code} เพื่อยืนยันตัวตน",
            "รหัสชำระเงิน {code} ห้ามส่งต่อให้ใครเด็ดขาด",
            "รหัสผ่านครั้งเดียวของคุณคือ {code} หมดอายุใน {minutes} นาที"
        ],
        "promotion": [
            "แฟลชเซล! สมาชิก {brand} ลด {amount} บาทวันนี้ พิมพ์ STOP เพื่อยกเลิก",
            "{merchant}: ลดสูงสุด {percent}% {url}",
            "วันสมาชิก: คูปองเข้าบัญชี {brand} ของคุณแล้ว",
            "{merchant} เปิดสาขาใหม่ที่{city} รับบัตรกำนัล {amount} บาทเมื่อแสดง SMS นี้",
            "คะแนน {bank} จะหมดอายุ {date} แลกของรางวัลที่ {url}"
        ],
        "spam": [
            "ยินดีด้วย! คุณได้รับรางวัล ติดต่อเจ้าหน้าที่เพื่อรับของรางวัล",
            "เงินกู้อนุมัติไว ไม่เช็คเครดิต สูงสุด {amount2} บาท ใช้แค่บัตรประชาชน: {url}",
            "พัสดุของคุณส่งไม่สำเร็จ ยืนยันข้อมูลที่ {url}",
            "บัญชีของคุณจะถูกระงับ ยืนยันทันทีที่ {url}",
            "งานทำที่บ้าน วันละ {amount} บาท ไม่ต้องมีประสบการณ์ ติดต่อ {order}"
        ],
        "finance.bank": [
            "บัญชีลงท้าย {tail} ถูกหัก {amount} บาท เวลา {time} หากไม่ใช่คุณโปรดติดต่อธนาคาร",
            "{bank}: เงินเข้า {amount} บาท ยอดคงเหลือ {amount2} บาท",
            "ถอนเงินสดที่ ATM {amount} บาท บัญชีลงท้าย {tail}",
            "โอนเงิน {amount} บาทแล้ว จะถึงภายใน {minutes} นาที",
            "สลิปอิเล็กทรอนิกส์พร้อมแล้ว รายการ {order}"
        ],
        "finance.credit_card": [
            "ใบแจ้งยอดออกแล้ว: {amount} บาท ครบกำหนด {date}",
            "ตัดบัญชีอัตโนมัติ: {amount} บาท วันที่ {date}",
            "รับชำระแล้ว: {amount} บาทเข้าบัตรของคุณ ขอบคุณค่ะ",
            "ยอดขั้นต่ำ {amount} บาท ครบกำหนด {date} โปรดชำระตรงเวลา"
        ],
        "finance.consumption": [
            "บัตรลงท้าย {tail} มีรายการใช้จ่าย {amount} บาท",
            "ยืนยันการชำระค่าสินค้า {amount} บาทที่ {merchant}"
        ],
        "finance.income": [
            "คุณได้รับเงินโอน {amount} บาท ยอดใหม่ {amount2} บาท",
            "เงินเดือนเข้าแล้ว: {amount2} บาท เข้าบัญชีลงท้าย {tail}",
            "{name} โอนเงิน {amount} บาทให้คุณ",
            "ฝากเงินสด {amount} บาท เรียบร้อยแล้ว"
        ],
        "life.express": [
            "พัสดุถึง {station} แล้ว และกำลังเตรียมจัดส่ง",
            "พัสดุกำลังนำส่ง: ถึงวันนี้",
            "{courier}: พนักงานกำลังนำส่งพัสดุของคุณ",
            "นำส่งไม่สำเร็จ จะส่งใหม่พรุ่งนี้",
            "{courier}: พัสดุ {order} ออกจาก{city}แล้ว กำลังขนส่ง"
        ],
        "life.pickup_code": [
            "พัสดุอยู่ที่ {station} รหัสรับ {code}",
            "ตู้หมายเลข {count} มีพัสดุ รหัสของคุณคือ {code}",
            "รับพัสดุด้วยรหัส {code} ที่ {station}",
            "แจ้งเตือน: พัสดุรอมา {days} วันแล้ว รหัส {code}"
        ],
        "travel.ticketing": [
            "ออกตั๋วเครื่องบินแล้ว: เที่ยวบิน {flight} เดินทางปลอดภัย!",
            "จองรถไฟสำเร็จ: {train} ออกเวลา {time}",
            "ออกบัตรงานแล้ว เข้างานด้วยรหัส {code}",
            "เปลี่ยนตั๋วสำเร็จ: ออกเดินทางใหม่ {date} {time}",
            "เที่ยวบิน {flight} เปิดเช็คอินออนไลน์แล้ว เลือกที่นั่งได้เลย"
        ],
        "carrier.data_reminder": [
            "เดือนนี้ใช้ไป {count}GB เหลือ {remain}GB",
            "{carrier}: เน็ตคงเหลือ {remain}GB",
            "ยอดเงินต่ำกว่า {amount} บาท เติมเงินเพื่อใช้งานต่อเนื่อง",
            "ใช้เน็ตไปแล้ว {percent}% ส่วนเกินคิดค่าบริการเพิ่ม"
        ],
        "transaction.order": [
            "คำสั่งซื้อ {order} ชำระแล้ว ร้านกำลังเตรียมสินค้า",
            "สินค้าถูกจัดส่งแล้ว! ติดตามได้ในแอป",
            "คำสั่งซื้อ {order} ถูกยกเลิก เงินจะคืนตามช่องทางเดิม",
            "ร้านรับออเดอร์แล้ว พร้อมใน {minutes} นาที"
        ],
        "transaction.account_security": [
            "แจ้งเตือนความปลอดภัย: พบการเข้าสู่ระบบจากอุปกรณ์ใหม่ ใช่คุณหรือไม่?",
            "รหัสผ่านของคุณถูกเปลี่ยนเมื่อ {time}",
            "มีการเข้าสู่ระบบใหม่จาก{city}เวลา {time} โปรดตรวจสอบกิจกรรม",
            "มีคำขอเปลี่ยนเบอร์โทรของบัญชี หากไม่ใช่คุณโปรดระงับบัญชีทันที"
        ]
    ]
}
