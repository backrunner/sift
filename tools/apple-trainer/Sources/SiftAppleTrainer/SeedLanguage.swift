import Foundation
import NaturalLanguage

/// Languages the synthetic seed corpus can generate. `zh` is the primary
/// corpus (deepest label coverage); `en` covers every label; the rest cover
/// the high-volume international SMS categories.
enum SeedLanguage: String, CaseIterable {
    case zh
    case en
    case es
    case pt
    case fr
    case de
    case ru
    case ja
    case ko
    case id
    case vi
    case th

    static func parse(_ raw: String) -> [SeedLanguage]? {
        if raw.lowercased() == "all" {
            return SeedLanguage.allCases
        }
        var languages: [SeedLanguage] = []
        for token in raw.split(separator: ",") {
            guard let language = SeedLanguage(rawValue: token.trimmingCharacters(in: .whitespaces).lowercased()) else {
                return nil
            }
            if !languages.contains(language) {
                languages.append(language)
            }
        }
        return languages.isEmpty ? nil : languages
    }

    var templates: [String: [String]] {
        switch self {
        case .zh: return SeedTemplatesChinese.templates
        case .en: return SeedTemplatesEnglish.templates
        case .ja: return SeedTemplatesJapanese.templates
        default: return SeedTemplatesGlobal.templates[self] ?? [:]
        }
    }

    /// zh / en / ja are the project's first-class languages: their template
    /// sets must jointly and individually cover every taxonomy leaf.
    var isCoreLanguage: Bool {
        self == .zh || self == .en || self == .ja
    }

    var pools: SeedFillPools {
        switch self {
        case .zh: return .chinese
        case .en: return .english
        case .es: return .spanish
        case .pt: return .portuguese
        case .fr: return .french
        case .de: return .german
        case .ru: return .russian
        case .ja: return .japanese
        case .ko: return .korean
        case .id: return .indonesian
        case .vi: return .vietnamese
        case .th: return .thai
        }
    }
}

/// Locale-appropriate value pools used to fill `{placeholder}` slots.
struct SeedFillPools {
    let brands: [String]
    let banks: [String]
    let platforms: [String]
    let merchants: [String]
    let couriers: [String]
    let carriers: [String]
    let hospitals: [String]
    let cities: [String]
    let names: [String]
    let stations: [String]
    let tasks: [String]
    let tiers: [String]
    let urlHosts: [String]
    /// May reference `{brand}` / `{name}`; substituted after selection.
    let prefixes: [String]
    let suffixes: [String]
}

extension SeedFillPools {
    static let chinese = SeedFillPools(
        brands: [
            "星云", "云闪付", "麦芽", "安心", "晨光", "拾光", "青禾", "松果", "云鹿", "海岚",
            "知乎严选", "得物", "花田", "好物社", "悠选", "甄品", "壹号", "百果", "鲜乐",
            "蜜柚", "橙子优选", "白咖啡", "唐宁书店", "山月", "野象", "米淘", "拾贝", "锦绣",
            "禾木", "山下", "途客", "悦享", "时光里", "云上", "Today", "OBOR", "Easy购"
        ],
        banks: [
            "东湖银行", "海川银行", "银杉银行", "城市银行", "中信银行", "招商银行", "平安银行",
            "建设银行", "工商银行", "农业银行", "交通银行", "邮储银行", "民生银行", "光大银行",
            "兴业银行", "浦发银行", "广发银行", "华夏银行", "渤海银行", "北京银行", "上海银行"
        ],
        platforms: [
            "星云生活", "麦芽到家", "云仓", "安心服务", "美团", "饿了么", "拼多多", "淘宝", "京东",
            "天猫", "抖音", "快手", "小红书", "得物", "唯品会", "携程", "去哪儿", "飞猪",
            "马蜂窝", "高德", "滴滴", "T3 出行", "曹操出行", "瑞幸", "肯德基", "星巴克", "喜茶"
        ],
        merchants: [
            "青禾超市", "拾光餐厅", "松果便利", "云鹿商行", "好嘉超市", "鲜丰水果", "永辉超市",
            "全家便利", "罗森", "7-Eleven", "M Stand", "瑞幸咖啡", "Manner", "茶颜悦色", "霸王茶姬",
            "海底捞", "西贝莜面村", "巴奴毛肚", "九毛九", "外婆家", "奈雪", "蜜雪冰城", "古茗",
            "肯德基", "麦当劳", "汉堡王", "塔斯汀", "南城香", "家乐福", "山姆会员店", "盒马鲜生",
            "ZARA", "优衣库", "海澜之家", "森马", "李宁", "安踏", "迪卡侬", "屈臣氏", "万宁",
            "丝芙兰", "完美日记", "花西子", "INTO YOU", "护肤研习社", "宠物之家", "怡和书店"
        ],
        couriers: [
            "云达", "顺捷", "丰行", "中联", "顺丰", "中通", "圆通", "申通", "韵达", "百世",
            "京东物流", "极兔", "德邦", "EMS", "菜鸟", "天天", "宅急送"
        ],
        carriers: ["中国移动", "中国联通", "中国电信", "广电网络", "中国广电"],
        hospitals: [
            "市一医院", "和康门诊", "仁安医院", "中心医院", "协和医院", "同仁医院", "瑞金医院",
            "华山医院", "中山医院", "人民医院", "妇幼保健院", "口腔医院", "儿童医院", "肿瘤医院"
        ],
        cities: [
            "北京", "上海", "杭州", "深圳", "广州", "成都", "武汉", "南京", "西安", "重庆",
            "苏州", "天津", "长沙", "青岛", "厦门", "宁波", "无锡", "合肥", "佛山", "东莞"
        ],
        names: [
            "李先生", "王女士", "张老师", "刘工", "陈同学", "赵经理", "黄主任", "周顾问",
            "吴先生", "徐女士", "孙老师", "马总", "朱医生", "胡客户经理", "林女士",
            "Mr. Lee", "Ms. Wang", "Tony", "Linda", "James"
        ],
        stations: [
            "北门驿站", "幸福里驿站", "云仓站点", "丰巢快递柜", "菜鸟驿站", "蜂收站",
            "小区物业", "校区收发室", "便利店代收", "顺丰柜机"
        ],
        tasks: [
            "提交周报", "确认订单", "完成审批", "检查账单", "处理告警", "审核合同",
            "回复邮件", "更新文档", "上传材料", "完成签字", "校对数据", "录入凭证"
        ],
        tiers: ["白银", "黄金", "铂金", "钻石", "黑金", "至尊", "至臻", "PLUS", "PRO"],
        urlHosts: [
            "h5.brand.cn/p/", "m.shop.com/i/", "promo.app/", "act.brand.com/d/",
            "go.platform.cn/x/", "v.merchant.io/c/", "u.brand.cn/r/", "t.cn/", "dwz.cn/"
        ],
        prefixes: [
            "", "【{brand}】", "[{brand}] ", "{brand}提醒：", "{brand}通知 - ", "短信通知：",
            "尊敬的用户，", "{brand}服务通知：", "您好，", "系统通知：", "Hi {name}，",
            "亲爱的会员，", "{brand} | ", "[官方] "
        ],
        suffixes: [
            "", "请及时查看。", "可在App内查看详情。", "如已处理请忽略。", "感谢您的配合。",
            "详情以页面显示为准。", "如有疑问请联系官方渠道。", "本消息仅作状态提醒。",
            " 详见 {url}", "（回T退订）", "[退订回T]", " 戳→ {url}", "（如非本人请忽略）",
            " — {brand}", "请勿回复本短信。"
        ]
    )

    static let english = SeedFillPools(
        brands: [
            "Nimbus", "Brightline", "Acorn", "Lumen", "Vertex", "Solstice", "Harbor", "Peak",
            "Northwind", "Cobalt", "Maple&Co", "Everly", "Zephyr", "Trailhead", "Alder"
        ],
        banks: [
            "First National Bank", "Harborview Bank", "Summit Credit Union", "Meridian Bank",
            "Citizens Trust", "Pacific Savings", "Oakline Bank", "Union Federal", "Crestwood Bank"
        ],
        platforms: [
            "ShopNow", "QuickCart", "RideGo", "FreshDrop", "PayLink", "StreamBox", "BookIt",
            "TravelHub", "FoodDash", "MarketPlace"
        ],
        merchants: [
            "Sunrise Market", "The Corner Cafe", "Urban Outfit Co", "GreenLeaf Grocery",
            "Bella Cucina", "Metro Pharmacy", "City Books", "Fresh & Fast", "Style Studio",
            "The Coffee Bar", "Northside Gym", "Happy Paws Vet"
        ],
        couriers: ["SwiftShip", "ParcelPro", "FedUp Express", "BlueDart", "QuickPost", "MetroCourier"],
        carriers: ["TeleOne", "GlobalCell", "AirLink Mobile", "MetroTel", "SkyNet Wireless"],
        hospitals: ["City General Hospital", "St. Mary's Clinic", "Lakeside Medical Center", "Downtown Health"],
        cities: [
            "New York", "London", "Sydney", "Toronto", "Chicago", "Austin", "Manchester",
            "Dublin", "Auckland", "Singapore", "San Francisco", "Seattle"
        ],
        names: ["John", "Sarah", "Mike", "Emma", "David", "Lisa", "Chris", "Anna", "Mr. Smith", "Ms. Brown"],
        stations: ["Locker Hub #4", "Front Desk", "Parcel Point", "Community Locker", "Mail Room B"],
        tasks: [
            "submit the weekly report", "confirm the order", "approve the request", "review the invoice",
            "acknowledge the alert", "sign the contract", "reply to the email", "upload the documents"
        ],
        tiers: ["Silver", "Gold", "Platinum", "Diamond", "VIP", "Plus", "Pro"],
        urlHosts: [
            "shop.ly/", "deals.co/x/", "trk.li/", "promo.io/d/", "bit.do/", "go.app/r/", "m.store.com/i/"
        ],
        prefixes: [
            "", "[{brand}] ", "{brand}: ", "{brand} Alert: ", "Notice: ", "Dear customer, ",
            "Hi {name}, ", "{brand} Notification - ", "Official: "
        ],
        suffixes: [
            "", " Thank you.", " Please do not reply.", " See the app for details.",
            " Reply STOP to opt out.", " Txt STOP to end.", " Details: {url}", " Visit {url}",
            " If this wasn't you, ignore this message.", " - {brand}"
        ]
    )

    static let spanish = SeedFillPools(
        brands: ["Solmarca", "Andina", "Lumbre", "Vientos", "Cumbre", "Norte&Co", "Almena", "Riberia"],
        banks: ["Banco del Sol", "Banco Central Hispano", "Caja Andaluza", "Banco Riviera", "BancoNorte", "Caja Rural del Este"],
        platforms: ["CompraYa", "MercadoRápido", "ViajaFácil", "PagoLink", "ComidaExpress", "TiendaPlus"],
        merchants: ["Supermercado La Plaza", "Café del Centro", "Farmacia San Juan", "Moda Urbana", "La Bodega Fresca", "Librería Cervantes"],
        couriers: ["EnvíoRápido", "PaqueteYa", "CorreoExpress", "MensajeríaSur", "LogísticaPlus"],
        carriers: ["TeleSur", "MóvilOne", "RedCel", "AndesTel", "GlobalMóvil"],
        hospitals: ["Hospital Central", "Clínica Santa María", "Centro Médico del Sur", "Hospital San Rafael"],
        cities: ["Madrid", "Barcelona", "Ciudad de México", "Buenos Aires", "Bogotá", "Lima", "Sevilla", "Valencia", "Santiago"],
        names: ["Sr. García", "Sra. López", "Carlos", "María", "Juan", "Lucía", "Diego", "Carmen"],
        stations: ["Punto de Recogida Centro", "Taquilla 12", "Consigna Norte", "Locker Plaza Mayor"],
        tasks: ["enviar el informe", "confirmar el pedido", "aprobar la solicitud", "revisar la factura"],
        tiers: ["Plata", "Oro", "Platino", "Diamante", "VIP"],
        urlHosts: ["oferta.es/", "tienda.mx/p/", "promo.lat/d/", "enlace.co/x/", "m.compra.es/i/"],
        prefixes: ["", "[{brand}] ", "{brand}: ", "Aviso: ", "Estimado cliente, ", "Hola {name}, ", "{brand} Informa: "],
        suffixes: ["", " Gracias.", " No responda a este mensaje.", " Más info: {url}", " Responde BAJA para cancelar.", " Si no fuiste tú, ignora este mensaje.", " - {brand}"]
    )

    static let portuguese = SeedFillPools(
        brands: ["Aurora", "Vitral", "Mangue", "Cristalina", "Litoral", "Serra&Co", "Farol", "Verde Vale"],
        banks: ["Banco Litoral", "Banco Nacional do Sul", "Caixa Aurora", "Banco Horizonte", "BancoReal Plus"],
        platforms: ["CompreJá", "MercadoBom", "ViagemFácil", "PagueLink", "EntregaExpress", "LojaMais"],
        merchants: ["Supermercado Bom Preço", "Padaria Central", "Farmácia Vida", "Moda & Cia", "Mercearia do Bairro", "Livraria Atlântica"],
        couriers: ["EnvioRápido", "PacoteJá", "CorreioExpresso", "LogTotal", "EntregaSul"],
        carriers: ["TeleBrasil", "MóvelUm", "RedeCel", "AtlanticoTel", "GlobalMóvel"],
        hospitals: ["Hospital Central", "Clínica Santa Casa", "Centro Médico Paulista", "Hospital São Lucas"],
        cities: ["São Paulo", "Rio de Janeiro", "Lisboa", "Porto", "Belo Horizonte", "Brasília", "Curitiba", "Salvador"],
        names: ["Sr. Silva", "Sra. Santos", "João", "Ana", "Pedro", "Mariana", "Lucas", "Beatriz"],
        stations: ["Ponto de Retirada Centro", "Armário 7", "Locker Estação", "Agência do Bairro"],
        tasks: ["enviar o relatório", "confirmar o pedido", "aprovar a solicitação", "conferir a fatura"],
        tiers: ["Prata", "Ouro", "Platina", "Diamante", "VIP"],
        urlHosts: ["oferta.br/", "loja.pt/p/", "promo.com.br/d/", "link.br/x/", "m.compra.br/i/"],
        prefixes: ["", "[{brand}] ", "{brand}: ", "Aviso: ", "Prezado cliente, ", "Olá {name}, ", "{brand} Informa: "],
        suffixes: ["", " Obrigado.", " Não responda esta mensagem.", " Detalhes: {url}", " Responda SAIR para cancelar.", " Se não foi você, ignore.", " - {brand}"]
    )

    static let french = SeedFillPools(
        brands: ["Lumière", "Boréal", "Argile", "Riviera", "Clairval", "Moulin&Co", "Éclat", "Verger"],
        banks: ["Banque de la Loire", "Crédit du Nord-Est", "Banque Rivage", "Caisse Centrale", "Banque Lumière"],
        platforms: ["AchatVite", "MarchéFacile", "VoyagePlus", "PaieLink", "LivraisonGo", "BoutiquePlus"],
        merchants: ["Supermarché du Centre", "Café de la Gare", "Pharmacie Saint-Michel", "Mode Urbaine", "Épicerie Fine", "Librairie Voltaire"],
        couriers: ["EnvoiRapide", "ColisPlus", "CourrierExpress", "LogiFrance", "LivraisonSud"],
        carriers: ["TéléFrance", "MobileUn", "RéseauCel", "HexagoneTel", "GlobalMobile"],
        hospitals: ["Hôpital Central", "Clinique Sainte-Anne", "Centre Médical du Parc", "Hôpital Saint-Louis"],
        cities: ["Paris", "Lyon", "Marseille", "Toulouse", "Bordeaux", "Lille", "Nantes", "Genève", "Bruxelles"],
        names: ["M. Dupont", "Mme Martin", "Pierre", "Sophie", "Julien", "Camille", "Louis", "Chloé"],
        stations: ["Point Relais Centre", "Consigne 5", "Locker Gare", "Relais du Quartier"],
        tasks: ["envoyer le rapport", "confirmer la commande", "valider la demande", "vérifier la facture"],
        tiers: ["Argent", "Or", "Platine", "Diamant", "VIP"],
        urlHosts: ["offre.fr/", "boutique.fr/p/", "promo.fr/d/", "lien.fr/x/", "m.achat.fr/i/"],
        prefixes: ["", "[{brand}] ", "{brand} : ", "Avis : ", "Cher client, ", "Bonjour {name}, ", "{brand} Info : "],
        suffixes: ["", " Merci.", " Ne pas répondre.", " Détails : {url}", " STOP au 36111 pour vous désabonner.", " Si ce n'était pas vous, ignorez ce message.", " - {brand}"]
    )

    static let german = SeedFillPools(
        brands: ["Nordlicht", "Bergquell", "Lindenhof", "Silberpfad", "Alpenland", "Fuchs&Co", "Eichenblatt", "Klarsee"],
        banks: ["Stadtbank Nord", "Volksbank Rheintal", "Sparkasse Mitte", "Bergbank", "Hansebank"],
        platforms: ["KaufJetzt", "MarktSchnell", "ReiseLeicht", "ZahlLink", "LieferGo", "ShopPlus"],
        merchants: ["Supermarkt am Ring", "Café Mitte", "Apotheke am Dom", "Stadtmode", "Feinkost Müller", "Buchhandlung Weber"],
        couriers: ["SchnellPaket", "PaketPlus", "KurierExpress", "LogistikNord", "SüdVersand"],
        carriers: ["TeleDeutsch", "MobilEins", "NetzCel", "AlpenTel", "GlobalMobil"],
        hospitals: ["Stadtklinik", "Klinikum Nord", "St. Elisabeth Krankenhaus", "Medizinisches Zentrum West"],
        cities: ["Berlin", "München", "Hamburg", "Frankfurt", "Köln", "Wien", "Zürich", "Stuttgart", "Leipzig"],
        names: ["Herr Müller", "Frau Schmidt", "Lukas", "Anna", "Felix", "Laura", "Jonas", "Marie"],
        stations: ["Packstation 112", "Abholpunkt Mitte", "Paketshop am Markt", "Schließfach 8"],
        tasks: ["den Wochenbericht senden", "die Bestellung bestätigen", "den Antrag freigeben", "die Rechnung prüfen"],
        tiers: ["Silber", "Gold", "Platin", "Diamant", "VIP"],
        urlHosts: ["angebot.de/", "shop.de/p/", "aktion.de/d/", "kurzlink.de/x/", "m.kauf.de/i/"],
        prefixes: ["", "[{brand}] ", "{brand}: ", "Hinweis: ", "Sehr geehrter Kunde, ", "Hallo {name}, ", "{brand} Info: "],
        suffixes: ["", " Vielen Dank.", " Bitte nicht antworten.", " Details: {url}", " Mit STOP abmelden.", " Falls Sie das nicht waren, ignorieren Sie diese Nachricht.", " - {brand}"]
    )

    static let russian = SeedFillPools(
        brands: ["Северлайн", "Мираж", "Кристалл", "Полюс", "Заря", "Вектор", "Альфа-Дом", "Лесной"],
        banks: ["Банк Северный", "НароdБанк", "СитиБанк Восток", "Уралкредит", "РечнойБанк"],
        platforms: ["КупиСейчас", "МаркетБыстро", "ПоездкаЛегко", "ОплатаЛинк", "ДоставкаГо", "МагазинПлюс"],
        merchants: ["Супермаркет Центральный", "Кафе на Невском", "Аптека Здоровье", "Городская Мода", "Гастроном №1", "Книжный Дом"],
        couriers: ["БыстраяПочта", "ПосылкаПлюс", "КурьерЭкспресс", "ЛогистикаСевер", "ЮжнаяДоставка"],
        carriers: ["ТелеРус", "МобилОдин", "СетьСел", "ВолгаТел", "ГлобалМобайл"],
        hospitals: ["Городская больница №3", "Клиника Здоровье", "Медицинский центр Юг", "Поликлиника №7"],
        cities: ["Москва", "Санкт-Петербург", "Новосибирск", "Екатеринбург", "Казань", "Алматы", "Минск", "Сочи"],
        names: ["Иван", "Мария", "Алексей", "Ольга", "Дмитрий", "Елена", "Сергей", "Анна"],
        stations: ["Пункт выдачи №12", "Постамат у метро", "ПВЗ Центральный", "Ячейка 45"],
        tasks: ["отправить отчёт", "подтвердить заказ", "согласовать заявку", "проверить счёт"],
        tiers: ["Серебро", "Золото", "Платина", "Бриллиант", "VIP"],
        urlHosts: ["skidka.ru/", "magazin.ru/p/", "aktsiya.ru/d/", "link.ru/x/", "m.pokupka.ru/i/"],
        prefixes: ["", "[{brand}] ", "{brand}: ", "Внимание: ", "Уважаемый клиент, ", "Здравствуйте, {name}! ", "{brand} сообщает: "],
        suffixes: ["", " Спасибо.", " Не отвечайте на это сообщение.", " Подробнее: {url}", " Отписка: СТОП.", " Если это были не вы, проигнорируйте.", " - {brand}"]
    )

    static let japanese = SeedFillPools(
        brands: ["さくらマート", "ひかりペイ", "青空堂", "みどり屋", "スターライン", "紅葉社", "波音", "こだま"],
        banks: ["さくら銀行", "みなと銀行", "青葉信用金庫", "中央銀行", "ひまわり銀行"],
        platforms: ["カウナウ", "マーケット便", "たびらく", "ペイリンク", "デリバゴー", "ショップ+"],
        merchants: ["セントラルスーパー", "駅前カフェ", "みどり薬局", "アーバンモード", "町の八百屋", "文栄堂書店"],
        couriers: ["はやぶさ便", "パケットプラス", "エクスプレス急便", "北ロジ", "南運輸"],
        carriers: ["テレジャパン", "モバイルワン", "ネットセル", "フジテル", "グローバルモバイル"],
        hospitals: ["中央病院", "聖マリア医院", "みなと医療センター", "ひかりクリニック"],
        cities: ["東京", "大阪", "名古屋", "福岡", "札幌", "横浜", "京都", "神戸"],
        names: ["田中様", "佐藤様", "鈴木様", "高橋様", "伊藤様", "渡辺様", "山本様"],
        stations: ["宅配ロッカー3番", "受取スポット駅前", "コンビニ受取", "ロッカー12"],
        tasks: ["週報を提出する", "注文を確認する", "申請を承認する", "請求書を確認する"],
        tiers: ["シルバー", "ゴールド", "プラチナ", "ダイヤモンド", "VIP"],
        urlHosts: ["sale.jp/", "shop.jp/p/", "cp.jp/d/", "link.jp/x/", "m.kaimono.jp/i/"],
        prefixes: ["", "【{brand}】", "[{brand}] ", "{brand}より：", "お知らせ：", "{name}、", "ご利用者様へ："],
        suffixes: ["", " ご確認ください。", " 本メッセージへの返信はできません。", " 詳細は {url}", " 配信停止は「停止」と返信。", " お心当たりのない場合は無視してください。", " ─ {brand}"]
    )

    static let korean = SeedFillPools(
        brands: ["한빛", "새봄", "푸른마켓", "달빛페이", "가온", "누리샵", "바다상회", "온새미로"],
        banks: ["한강은행", "미래은행", "새싹저축은행", "중앙은행", "가람은행"],
        platforms: ["지금사자", "마켓빠름", "여행이지", "페이링크", "배달고", "샵플러스"],
        merchants: ["중앙마트", "역전카페", "푸른약국", "어반스타일", "동네정육점", "한빛서점"],
        couriers: ["빠른택배", "패킷플러스", "익스프레스택배", "북부물류", "남도운송"],
        carriers: ["텔레코리아", "모바일원", "넷셀", "한빛텔", "글로벌모바일"],
        hospitals: ["중앙병원", "성모의원", "바다의료센터", "햇살클리닉"],
        cities: ["서울", "부산", "인천", "대구", "대전", "광주", "수원", "제주"],
        names: ["김민준님", "이서연님", "박지훈님", "최수아님", "정도윤님", "강하은님"],
        stations: ["무인택배함 3번", "편의점 픽업", "아파트 경비실", "픽업스팟 역앞"],
        tasks: ["주간 보고서 제출", "주문 확인", "결재 승인", "청구서 확인"],
        tiers: ["실버", "골드", "플래티넘", "다이아", "VIP"],
        urlHosts: ["sale.kr/", "shop.kr/p/", "event.kr/d/", "link.kr/x/", "m.buy.kr/i/"],
        prefixes: ["", "[{brand}] ", "{brand}: ", "(광고) {brand} ", "알림: ", "{name}, ", "고객님께: "],
        suffixes: ["", " 확인 부탁드립니다.", " 본 문자는 발신전용입니다.", " 자세히: {url}", " 무료거부 0808001234", " 본인이 아닌 경우 무시하세요.", " - {brand}"]
    )

    static let indonesian = SeedFillPools(
        brands: ["Cahaya", "Nusantara", "MegaMart", "Sentosa", "Harapan", "Melati&Co", "Samudra", "Pelangi"],
        banks: ["Bank Nusa", "Bank Sentral Jaya", "Bank Harapan", "Bank Samudra", "Bank Melati"],
        platforms: ["BeliCepat", "PasarKilat", "JalanMudah", "BayarLink", "AntarGo", "TokoPlus"],
        merchants: ["Supermarket Sejahtera", "Kafe Kota", "Apotek Sehat", "Mode Urban", "Warung Segar", "Toko Buku Cerdas"],
        couriers: ["KirimCepat", "PaketPlus", "EkspresKurir", "LogistikNusa", "AntarSelatan"],
        carriers: ["TeleIndo", "SelulerSatu", "NetSel", "GarudaTel", "GlobalSeluler"],
        hospitals: ["RS Pusat", "Klinik Santo Yosef", "Pusat Medis Selatan", "RS Harapan Bunda"],
        cities: ["Jakarta", "Surabaya", "Bandung", "Medan", "Yogyakarta", "Semarang", "Bali", "Makassar"],
        names: ["Bapak Budi", "Ibu Sari", "Andi", "Dewi", "Rizky", "Putri", "Agus", "Fitri"],
        stations: ["Loker Paket 5", "Titik Ambil Pusat", "Agen Kelurahan", "Loker Stasiun"],
        tasks: ["kirim laporan mingguan", "konfirmasi pesanan", "setujui pengajuan", "periksa tagihan"],
        tiers: ["Perak", "Emas", "Platinum", "Berlian", "VIP"],
        urlHosts: ["promo.id/", "toko.id/p/", "diskon.id/d/", "tautan.id/x/", "m.beli.id/i/"],
        prefixes: ["", "[{brand}] ", "{brand}: ", "Pemberitahuan: ", "Pelanggan yang terhormat, ", "Halo {name}, ", "Info {brand}: "],
        suffixes: ["", " Terima kasih.", " Jangan balas pesan ini.", " Info: {url}", " Balas STOP untuk berhenti.", " Abaikan jika bukan Anda.", " - {brand}"]
    )

    static let vietnamese = SeedFillPools(
        brands: ["Ánh Dương", "Sen Việt", "Đại Phát", "Hoa Mai", "Thịnh Vượng", "Sông Xanh", "Kim Long", "Bình Minh"],
        banks: ["Ngân hàng Sông Hồng", "Ngân hàng Đại Nam", "Ngân hàng Hoa Sen", "Ngân hàng Trung Tâm", "Ngân hàng Kim Long"],
        platforms: ["MuaNhanh", "ChợTốc", "DuLịchDễ", "ThanhToánLink", "GiaoGo", "ShopCộng"],
        merchants: ["Siêu thị Trung Tâm", "Cà phê Phố Cổ", "Nhà thuốc An Khang", "Thời trang Phố", "Tạp hóa Sạch", "Nhà sách Trí Tuệ"],
        couriers: ["GiaoNhanh", "GóiPlus", "ChuyểnPhátNhanh", "LogistiViệt", "GiaoNamBộ"],
        carriers: ["TeleViệt", "DiĐộngMột", "MạngCel", "SaoTel", "GlobalDiĐộng"],
        hospitals: ["Bệnh viện Trung ương", "Phòng khám Thánh Tâm", "Trung tâm Y tế Nam", "Bệnh viện Hòa Bình"],
        cities: ["Hà Nội", "TP.HCM", "Đà Nẵng", "Hải Phòng", "Cần Thơ", "Huế", "Nha Trang", "Vũng Tàu"],
        names: ["Anh Minh", "Chị Lan", "Anh Tuấn", "Chị Hương", "Anh Đức", "Chị Mai", "Anh Nam"],
        stations: ["Tủ nhận hàng số 3", "Điểm nhận Trung Tâm", "Bưu cục Phường", "Locker Ga"],
        tasks: ["gửi báo cáo tuần", "xác nhận đơn hàng", "duyệt đề xuất", "kiểm tra hóa đơn"],
        tiers: ["Bạc", "Vàng", "Bạch Kim", "Kim Cương", "VIP"],
        urlHosts: ["khuyenmai.vn/", "shop.vn/p/", "giamgia.vn/d/", "lienket.vn/x/", "m.mua.vn/i/"],
        prefixes: ["", "[{brand}] ", "{brand}: ", "Thông báo: ", "Kính gửi quý khách, ", "Chào {name}, ", "Tin từ {brand}: "],
        suffixes: ["", " Xin cảm ơn.", " Vui lòng không trả lời tin nhắn này.", " Chi tiết: {url}", " Soạn TC gửi 996 để hủy.", " Bỏ qua nếu không phải bạn.", " - {brand}"]
    )

    static let thai = SeedFillPools(
        brands: ["แสงทอง", "บัวขาว", "มณีมาร์ท", "ทรัพย์เจริญ", "ฟ้าใส", "ไผ่เงิน", "มหานคร", "รุ่งเรือง"],
        banks: ["ธนาคารแม่น้ำ", "ธนาคารกลางไทย", "ธนาคารบัวหลวงใหม่", "ธนาคารทรัพย์มั่น", "ธนาคารรุ่งเรือง"],
        platforms: ["ซื้อเลย", "ตลาดไว", "เที่ยวง่าย", "จ่ายลิงก์", "ส่งโก", "ช้อปพลัส"],
        merchants: ["ซูเปอร์มาร์เก็ตกลางเมือง", "คาเฟ่ริมทาง", "ร้านยาสุขภาพ", "แฟชั่นซิตี้", "ร้านชำสดใหม่", "ร้านหนังสือปัญญา"],
        couriers: ["ส่งด่วน", "พัสดุพลัส", "เอ็กซ์เพรสไทย", "โลจิสติกส์เหนือ", "ส่งใต้"],
        carriers: ["เทเลไทย", "โมบายวัน", "เน็ตเซล", "สยามเทล", "โกลบอลโมบาย"],
        hospitals: ["โรงพยาบาลกลาง", "คลินิกเซนต์แมรี่", "ศูนย์การแพทย์ใต้", "โรงพยาบาลร่มเย็น"],
        cities: ["กรุงเทพฯ", "เชียงใหม่", "ภูเก็ต", "ขอนแก่น", "พัทยา", "หาดใหญ่", "อุดรธานี", "นครราชสีมา"],
        names: ["คุณสมชาย", "คุณสมหญิง", "คุณอนันต์", "คุณมะลิ", "คุณวิชัย", "คุณพรทิพย์"],
        stations: ["ตู้ล็อกเกอร์ 3", "จุดรับพัสดุกลางเมือง", "ร้านสะดวกซื้อรับฝาก", "ล็อกเกอร์สถานี"],
        tasks: ["ส่งรายงานประจำสัปดาห์", "ยืนยันคำสั่งซื้อ", "อนุมัติคำขอ", "ตรวจสอบใบแจ้งหนี้"],
        tiers: ["ซิลเวอร์", "โกลด์", "แพลทินัม", "ไดมอนด์", "VIP"],
        urlHosts: ["promo.th/", "shop.th/p/", "sale.th/d/", "link.th/x/", "m.buy.th/i/"],
        prefixes: ["", "[{brand}] ", "{brand}: ", "แจ้งเตือน: ", "เรียนลูกค้า ", "สวัสดี {name} ", "ข่าวจาก {brand}: "],
        suffixes: ["", " ขอบคุณค่ะ", " ข้อความนี้ส่งอัตโนมัติ", " ดูรายละเอียด {url}", " พิมพ์ STOP เพื่อยกเลิก", " หากไม่ใช่คุณโปรดละเว้น", " - {brand}"]
    )
}
