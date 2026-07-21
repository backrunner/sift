#!/usr/bin/env python3
"""Generate leak-free trilingual private-conversation abstention rows."""

from __future__ import annotations

import argparse
import itertools
import json
import random
from collections import Counter
from pathlib import Path
from typing import Iterable

from curate_dataset import near_duplicate_signature, normalize
from model_contract import ABSTAIN_LABEL


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--holdout", type=Path, required=True)
    parser.add_argument("--per-language", type=int, default=220)
    parser.add_argument("--seed", type=int, default=42)
    return parser.parse_args()


def zh_candidates() -> Iterable[str]:
    places = ["公司楼下", "公园门口", "咖啡店外面", "小区门口", "车站出口", "书店一楼"]
    questions = ["你现在方便出来吗？", "要我进去找你吗？", "你还要多久？", "我们在哪里碰面？", "需要我等一会儿吗？"]
    for place, question in itertools.product(places, questions):
        yield f"我已经到{place}了，{question}"

    people = ["爸爸", "妈妈", "姐姐", "哥哥", "小林", "阿杰"]
    plans = ["周末一起吃饭", "明晚去散步", "下班后过来坐坐", "周日早点出发", "今晚在家做饭"]
    for person, plan in itertools.product(people, plans):
        yield f"{person}问我们要不要{plan}，你觉得怎么样？"

    items = ["雨伞", "充电器", "那本书", "你的外套", "家里的钥匙", "保温杯"]
    actions = ["放在桌上了", "装进包里了", "先替你收好了", "带在身上了", "放到门口柜子里了"]
    for item, action in itertools.product(items, actions):
        yield f"{item}我已经{action}，见面时提醒我给你。"

    activities = ["吃火锅", "看电影", "去散步", "买点水果", "在家做饭", "带孩子去公园"]
    times = ["今晚", "明天下午", "周六早上", "下班以后", "午饭之后"]
    for time, activity in itertools.product(times, activities):
        yield f"{time}一起{activity}吧，你有别的安排吗？"

    weather_changes = ["雨刚停", "外面已经不下雨了", "风小多了", "太阳出来了", "天气凉快了", "雪已经停了"]
    travel_plans = [
        "我准备走路过去，二十分钟左右到",
        "我现在出门，到了再给你消息",
        "我去车站找你，你先别走",
        "我顺路去接你，应该很快就到",
        "我们还是照常在公园见吧",
    ]
    for weather, plan in itertools.product(weather_changes, travel_plans):
        yield f"{weather}，{plan}。"

    dishes = ["饺子", "咖喱", "蛋糕", "炖菜", "红烧肉", "炒饭"]
    pickup_plans = [
        "今天做多了，给你留了一份，晚点来拿吧",
        "家里还剩不少，你下班后过来带一些走吧",
        "刚做好还热着，你有空就来尝尝",
        "我装好一盒了，见面的时候拿给你",
        "味道不错，特意给你留了一份",
    ]
    for dish, plan in itertools.product(dishes, pickup_plans):
        yield f"{dish}{plan}。"

    waiting_places = ["靠门的桌子", "二楼窗边", "大厅角落", "书架旁边", "咖啡店里面", "公园长椅"]
    arrival_plans = ["我们已经坐下了，你到了直接过来", "我在这里等你，快到时说一声", "位置给你留好了，进来就能看到", "大家都在这边，你不用着急", "你到了以后来找我们就好"]
    for place, plan in itertools.product(waiting_places, arrival_plans):
        yield f"我们在{place}，{plan}。"

    stored_items = ["红色外套", "围巾", "雨伞", "运动衫", "帽子", "帆布包"]
    return_plans = ["还放在我家，下次见面带给你", "落在我车里了，明天拿给你", "我替你收好了，周末记得带走", "还在客房里，见面时提醒我", "我先保管着，下次过去时给你"]
    for item, plan in itertools.product(stored_items, return_plans):
        yield f"你的{item}{plan}。"


def en_candidates() -> Iterable[str]:
    places = ["outside the office", "by the park gate", "near the coffee shop", "at the station exit", "in front of the bookstore", "downstairs"]
    questions = ["Should I come inside?", "How long will you be?", "Where should we meet?", "Do you want me to wait?", "Are you nearly here?"]
    for place, question in itertools.product(places, questions):
        yield f"I am {place} now. {question}"

    people = ["Dad", "Mum", "Anna", "David", "Maya", "Leo"]
    plans = ["have dinner together this weekend", "take a walk tomorrow", "come over after work", "leave early on Sunday", "cook at home tonight"]
    for person, plan in itertools.product(people, plans):
        yield f"{person} asked whether we want to {plan}. What do you think?"

    items = ["your umbrella", "the charger", "that book", "your coat", "the spare key", "the water bottle"]
    actions = ["left it on the table", "put it in my bag", "kept it somewhere safe", "brought it with me", "placed it by the door"]
    for item, action in itertools.product(items, actions):
        yield f"I {action}, so remind me to give you {item} when we meet."

    activities = ["make dinner", "watch a film", "take a walk", "buy some fruit", "visit the park", "get coffee"]
    times = ["tonight", "tomorrow afternoon", "Saturday morning", "after work", "after lunch"]
    for time, activity in itertools.product(times, activities):
        yield f"Do you want to {activity} {time}, or have you made other plans?"

    weather_changes = [
        "The rain has cleared",
        "It has stopped raining outside",
        "The wind has eased",
        "The sun is out again",
        "It feels cooler now",
        "The snow has stopped",
    ]
    travel_plans = [
        "I am walking over and should be there in about twenty minutes",
        "I am leaving now and will message you when I arrive",
        "I will meet you at the station, so please wait there",
        "I can pick you up on the way and should be there soon",
        "let us meet at the park as planned",
    ]
    for weather, plan in itertools.product(weather_changes, travel_plans):
        yield f"{weather}, so {plan}."

    dishes = ["dumplings", "curry", "cake", "stew", "pasta", "fried rice"]
    pickup_plans = [
        "I made too much, so I saved you a portion to pick up later",
        "there is plenty left at home, so come by after work and take some",
        "it is freshly made and still warm if you want to try some",
        "I packed a box for you and can give it to you when we meet",
        "it turned out well, and I kept a serving for you",
    ]
    for dish, plan in itertools.product(dishes, pickup_plans):
        yield f"I made {dish}; {plan}."

    waiting_places = ["at the table by the door", "upstairs by the window", "in the lobby corner", "beside the bookshelves", "inside the cafe", "on a park bench"]
    arrival_plans = [
        "we have already sat down, so come over when you get here",
        "I will wait here, so message me when you are close",
        "I saved you a seat and you will see us when you come in",
        "everyone is here, but there is no need to hurry",
        "just come and find us after you arrive",
    ]
    for place, plan in itertools.product(waiting_places, arrival_plans):
        yield f"We are {place}; {plan}."

    stored_items = ["red jacket", "scarf", "umbrella", "sweater", "hat", "canvas bag"]
    return_plans = [
        "is still at my apartment, and I will bring it when we meet again",
        "was left in my car, so I can give it to you tomorrow",
        "is safe with me; remember to take it this weekend",
        "is in the spare room, so remind me when we meet",
        "can stay with me until I come over next time",
    ]
    for item, plan in itertools.product(stored_items, return_plans):
        yield f"Your {item} {plan}."


def ja_candidates() -> Iterable[str]:
    places = ["会社の下", "公園の入口", "カフェの前", "駅の出口", "本屋の一階", "マンションの前"]
    questions = ["中まで行こうか？", "あとどのくらいかかる？", "どこで会う？", "ここで待っていようか？", "もうすぐ着く？"]
    for place, question in itertools.product(places, questions):
        yield f"今{place}にいるよ。{question}"

    people = ["父", "母", "姉", "兄", "美咲", "健太"]
    plans = ["週末に一緒にご飯を食べる", "明日散歩に行く", "仕事のあと家に来る", "日曜日は早めに出る", "今夜は家で料理する"]
    for person, plan in itertools.product(people, plans):
        yield f"{person}が{plan}のはどうかって。どう思う？"

    items = ["傘", "充電器", "あの本", "上着", "予備の鍵", "水筒"]
    actions = ["テーブルに置いた", "かばんに入れた", "大事にしまってある", "持ってきた", "玄関に置いた"]
    for item, action in itertools.product(items, actions):
        yield f"{item}は{action}よ。会ったとき渡すから声をかけてね。"

    activities = ["晩ご飯を作る", "映画を見る", "散歩する", "果物を買う", "公園へ行く", "コーヒーを飲む"]
    times = ["今夜", "明日の午後", "土曜日の朝", "仕事のあと", "昼ご飯のあと"]
    for time, activity in itertools.product(times, activities):
        yield f"{time}に一緒に{activity}？ほかに予定はある？"

    weather_changes = ["雨が上がった", "外はもう雨が降っていない", "風が弱くなった", "日が出てきた", "涼しくなった", "雪がやんだ"]
    travel_plans = [
        "歩いて向かうから二十分くらいで着くよ",
        "今から出るね、着いたら連絡するよ",
        "駅まで会いに行くから、そこで待っていてね",
        "途中で迎えに行くから、もう少し待っていて",
        "予定どおり公園で会おうね",
    ]
    for weather, plan in itertools.product(weather_changes, travel_plans):
        yield f"{weather}から、{plan}。"

    dishes = ["餃子", "カレー", "ケーキ", "煮物", "パスタ", "チャーハン"]
    pickup_plans = [
        "作りすぎたから、一人分取ってあるよ。あとで取りに来てね",
        "家にまだたくさんあるから、仕事のあと持って帰ってね",
        "できたてで温かいから、時間があれば食べに来てね",
        "一箱に詰めておいたから、会ったとき渡すね",
        "おいしくできたから、あなたの分を残してあるよ",
    ]
    for dish, plan in itertools.product(dishes, pickup_plans):
        yield f"{dish}を{plan}。"

    waiting_places = ["入口近くの席", "二階の窓際", "ロビーの隅", "本棚のそば", "カフェの中", "公園のベンチ"]
    arrival_plans = ["もう座っているから、着いたらこっちに来てね", "ここで待っているから、近くなったら連絡してね", "席を取ってあるから、入ればすぐ分かるよ", "みんなここにいるけど、急がなくて大丈夫だよ", "着いたあと私たちを探してね"]
    for place, plan in itertools.product(waiting_places, arrival_plans):
        yield f"私たちは{place}にいるよ。{plan}。"

    stored_items = ["赤い上着", "マフラー", "傘", "セーター", "帽子", "布のかばん"]
    return_plans = ["まだうちにあるから、次に会うとき持っていくね", "車に置いたままだから、明日渡すね", "預かっているから、週末に持って帰ってね", "客室にあるから、会ったとき声をかけてね", "次にそっちへ行くまで置いておくね"]
    for item, plan in itertools.product(stored_items, return_plans):
        yield f"あなたの{item}は{plan}。"


def load_holdout(path: Path) -> tuple[set[str], set[str]]:
    exact: set[str] = set()
    near: set[str] = set()
    with path.open(encoding="utf-8") as handle:
        for line in handle:
            if not line.strip():
                continue
            text = normalize(str(json.loads(line)["text"]))
            exact.add(text.lower())
            near.add(near_duplicate_signature(text))
    return exact, near


def generate_rows(per_language: int, seed: int, holdout: Path) -> list[dict[str, str]]:
    if per_language < 10:
        raise SystemExit("error: --per-language must be at least 10")
    holdout_exact, holdout_near = load_holdout(holdout)
    sources = {"zh": zh_candidates, "en": en_candidates, "ja": ja_candidates}
    rows: list[dict[str, str]] = []
    for offset, (language, source) in enumerate(sources.items()):
        unique: dict[str, str] = {}
        for candidate in source():
            text = normalize(candidate)
            near = near_duplicate_signature(text)
            if text.lower() in holdout_exact or near in holdout_near:
                continue
            unique.setdefault(near, text)
        candidates = list(unique.values())
        random.Random(seed + offset).shuffle(candidates)
        if len(candidates) < per_language:
            raise SystemExit(f"error: only {len(candidates)} isolated {language} rows are available")
        rows.extend(
            {"text": text, "label": ABSTAIN_LABEL, "language": language}
            for text in candidates[:per_language]
        )
    random.Random(seed).shuffle(rows)
    return rows


def main() -> None:
    arguments = parse_arguments()
    rows = generate_rows(arguments.per_language, arguments.seed, arguments.holdout)
    arguments.out.parent.mkdir(parents=True, exist_ok=True)
    payload = "\n".join(json.dumps(row, ensure_ascii=False, separators=(",", ":")) for row in rows)
    arguments.out.write_text(payload + "\n", encoding="utf-8")
    print(json.dumps({"rows": len(rows), "languages": dict(Counter(row["language"] for row in rows))}))


if __name__ == "__main__":
    main()
