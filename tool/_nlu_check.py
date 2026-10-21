# -*- coding: utf-8 -*-
"""与 lib/services/medication_nlu.dart 逐行等价的镜像实现，仅用于验证解析规则。"""
import re

UNIT_TOKENS = ['毫升','毫克','微克','片剂','单位','μg','ug','ml','mL','mg','MG',
               '片','粒','颗','丸','袋','包','支','瓶','滴','喷','揿','iu','IU','g','G','U']
UNIT_NORM = {'毫升':'ml','ml':'ml','mL':'ml','毫克':'mg','mg':'mg','MG':'mg',
             '微克':'μg','ug':'μg','μg':'μg','克':'g','g':'g','G':'g',
             '片剂':'片','片':'片','粒':'粒','颗':'颗','丸':'丸','袋':'袋','包':'包',
             '支':'支','瓶':'瓶','滴':'滴','喷':'喷','揿':'喷','单位':'U','iu':'U','IU':'U','U':'U'}
PERIODS = ['凌晨','清晨','早上','早晨','清早','上午','中午','下午','傍晚','晚上','晚间','夜里','夜间','睡前']
PERIOD_DEFAULT = {'凌晨':(5,0),'清晨':(7,0),'早上':(8,0),'早晨':(8,0),'清早':(7,0),'上午':(9,0),
                  '中午':(12,0),'下午':(15,0),'傍晚':(18,0),'晚上':(20,0),'晚间':(20,0),
                  '夜里':(22,0),'夜间':(22,0),'睡前':(21,30)}
DEFAULT_DIST = {1:['08:00'],2:['08:00','20:00'],3:['08:00','12:30','19:00'],4:['08:00','12:00','17:00','21:00']}
LEXICON = {'二甲双胍':['二甲双胍','格华止'],'阿司匹林':['阿司匹林','拜阿司匹林','拜阿'],
           '氨氯地平':['氨氯地平','络活喜'],'硝苯地平':['硝苯地平','拜新同'],
           '缬沙坦':['缬沙坦','代文'],'美托洛尔':['美托洛尔','倍他乐克'],
           '阿托伐他汀':['阿托伐他汀','立普妥'],'左甲状腺素':['左甲状腺素','优甲乐'],
           '华法林':['华法林'],'氯吡格雷':['氯吡格雷','波立维'],'维生素D':['维生素d','维生素D']}
NOTES = ['饭前','饭后','餐前','餐后','随餐','空腹','睡前','早上空腹','餐中']

UP = '|'.join(UNIT_TOKENS)
PP = '|'.join(PERIODS)
RE_CLOCK = re.compile(r'(%s)?\s*(\d{1,2})\s*[:：]\s*(\d{1,2})' % PP)
RE_HOUR = re.compile(r'(%s)?\s*(\d{1,2})\s*点\s*(半|一刻|三刻|(\d{1,2})\s*分)?' % PP)
RE_PERIOD = re.compile(r'(%s)' % PP)
RE_EVERY = re.compile(r'(?:每|每隔)\s*(\d{1,2})\s*(?:个)?\s*小时')
RE_COUNT = re.compile(r'每天\s*(\d{1,2})\s*次')
RE_DOSE_HALF = re.compile(r'(\d+(?:\.\d+)?)\s*(%s)\s*半' % UP)
RE_HALF_DOSE = re.compile(r'半\s*(%s)' % UP)
RE_DOSE = re.compile(r'(\d+(?:\.\d+)?)\s*(%s)' % UP)
RE_CJK = re.compile(r'[\u4e00-\u9fa5]{2,}')

CN_DIGITS = {'零':0,'〇':0,'一':1,'二':2,'两':2,'三':3,'四':4,'五':5,'六':6,'七':7,'八':8,'九':9}
CN_UNITS = {'十':10,'廿':20,'百':100,'千':1000}


def cn_to_arabic(s):
    result, current = 0, 0
    for ch in s:
        if ch in CN_DIGITS:
            current = CN_DIGITS[ch]
        elif ch in CN_UNITS:
            u = CN_UNITS[ch]
            if current == 0:
                current = 1
            result = result + 20 if u == 20 else result + current * u
            current = 0
    return result + current


def convert_cn_numbers(s):
    out, i = [], 0
    while i < len(s):
        ch = s[i]
        if ch in CN_DIGITS or ch in CN_UNITS:
            j = i
            while j < len(s) and (s[j] in CN_DIGITS or s[j] in CN_UNITS):
                j += 1
            out.append(str(cn_to_arabic(s[i:j])))
            i = j
        else:
            out.append(ch)
            i += 1
    return ''.join(out)


def normalize(raw):
    s = raw.strip()
    buf = []
    for ch in s:
        code = ord(ch)
        if 0xFF01 <= code <= 0xFF5E:
            buf.append(chr(code - 0xFEE0))
        elif code == 0x3000:
            buf.append(' ')
        else:
            buf.append(ch)
    s = ''.join(buf)
    s = s.replace('三餐后', '每天三次 饭后').replace('三餐前', '每天三次 饭前')
    s = s.replace('三餐', '每天三次')
    s = s.replace('早中晚', '早上 中午 晚上').replace('早晚', '早上 晚上')
    s = re.sub(r'一日|一天|1天|每天|每日|天天', '每天', s)
    s = re.sub(r'[，,。、；;！!？?]', ' ', s)
    s = re.sub(r'\s+', ' ', s).strip()
    return convert_cn_numbers(s)


def to_hm(h, m):
    h = h % 24
    if m >= 60:
        h = (h + m // 60) % 24
        m = m % 60
    return '%02d:%02d' % (h, m)


def apply_period(period, hour):
    if not period:
        return hour
    if period in ('下午','傍晚','晚上','晚间','夜里','夜间','睡前'):
        return hour + 12 if 1 <= hour <= 11 else hour
    if period == '中午':
        return hour + 12 if hour <= 3 else hour
    return hour


def consume(work, regex, on_match):
    while True:
        m = regex.search(work)
        if not m:
            return work
        on_match(m)
        work = work[:m.start()] + ' ' + work[m.end():]


STOP_PREFIXES = ['我','要','该','吃','喝','服用','记得','提醒','帮我','帮','请','这个','那个',
                 '还有','然后','和','跟','每次','每天','现在','医生','开','说','一共',
                 '早上','晚上','中午','下午','上午','睡前','饭后','饭前','空腹','随餐']


def strip_stopwords(s):
    changed = True
    while changed and len(s) > 2:
        changed = False
        for p in STOP_PREFIXES:
            if s.startswith(p) and len(s) - len(p) >= 2:
                s = s[len(p):]; changed = True
            if s.endswith(p) and len(s) - len(p) >= 2:
                s = s[:len(s)-len(p)]; changed = True
    return s


def parse(raw):
    d = {'raw': raw, 'name': None, 'dosageValue': None, 'dosageUnit': None,
         'times': [], 'note': None, 'issues': [], 'conf': {}, 'uncertain': set(),
         'frequency': 'daily', 'intervalHours': None}
    lex_name = None
    low_raw = raw.lower()
    for canonical, aliases in LEXICON.items():
        for a in aliases:
            if a.lower() in low_raw and (lex_name is None or len(canonical) > len(lex_name)):
                lex_name = canonical
    source = normalize(raw)
    work = source

    m = RE_EVERY.search(work)
    if m:
        h = int(m.group(1))
        if 0 < h <= 24:
            d['frequency'] = 'interval'; d['intervalHours'] = h
            work = work[:m.start()] + ' ' + work[m.end():]

    count = None
    m = RE_COUNT.search(work)
    if m:
        count = int(m.group(1))
        work = work[:m.start()] + ' ' + work[m.end():]

    def on_clock(m):
        h = apply_period(m.group(1), int(m.group(2)))
        d['times'].append(to_hm(h, int(m.group(3))))
    work = consume(work, RE_CLOCK, on_clock)

    def on_hour(m):
        h = int(m.group(2)); suffix = m.group(3); mi = 0
        if suffix == '半': mi = 30
        elif suffix == '一刻': mi = 15
        elif suffix == '三刻': mi = 45
        elif m.group(4): mi = int(m.group(4))
        d['times'].append(to_hm(apply_period(m.group(1), h), mi))
    work = consume(work, RE_HOUR, on_hour)

    if not d['times']:
        if '睡前' in source:
            work = re.sub(r'晚上|晚间|夜里|夜间', ' ', work)
        def on_period(m):
            hh, mm = PERIOD_DEFAULT[m.group(1)]
            d['times'].append(to_hm(hh, mm))
        work = consume(work, RE_PERIOD, on_period)

    def on_dose_half(m):
        d['dosageValue'] = float(m.group(1)) + 0.5
        d['dosageUnit'] = UNIT_NORM.get(m.group(2), m.group(2))
    work = consume(work, RE_DOSE_HALF, on_dose_half)

    if d['dosageValue'] is None:
        def on_dose(m):
            d['dosageValue'] = float(m.group(1))
            d['dosageUnit'] = UNIT_NORM.get(m.group(2), m.group(2))
        work = consume(work, RE_DOSE, on_dose)

    if d['dosageValue'] is None:
        def on_half(m):
            d['dosageValue'] = 0.5
            d['dosageUnit'] = UNIT_NORM.get(m.group(1), m.group(1))
        work = consume(work, RE_HALF_DOSE, on_half)

    for w in NOTES:
        if w in source:
            d['note'] = w
            break

    hit = lex_name
    low = source.lower()
    if hit is None:
        for canonical, aliases in LEXICON.items():
            for a in aliases:
                if a.lower() in low and (hit is None or len(canonical) > len(hit)):
                    hit = canonical
    if hit:
        d['name'] = hit; d['conf']['name'] = 0.95
    else:
        runs = sorted(RE_CJK.findall(work), key=len, reverse=True)
        guess = None
        for r in runs:
            c = strip_stopwords(r)
            if len(c) >= 2:
                guess = c; break
        if guess:
            d['name'] = guess; d['conf']['name'] = 0.55; d['uncertain'].add('name')
        else:
            d['conf']['name'] = 0

    if not d['times']:
        n = count or 1
        d['times'] = DEFAULT_DIST.get(n, [to_hm(8 + i * 3, 0) for i in range(n)])
        d['conf']['times'] = 0.6; d['uncertain'].add('times')
        if d['frequency'] == 'interval' and d['intervalHours']:
            d['issues'].append('已按早上 8 点开始、每隔 %d 小时提醒，请确认起始时间' % d['intervalHours'])
        else:
            d['issues'].append('没听到具体钟点，已按每天 %d 次的常用时间预填，请确认' % n)
    else:
        d['conf']['times'] = 0.9
        if count is not None and len(d['times']) != count:
            d['issues'].append('听到每天 %d 次，但只识别到 %d 个时间点，请确认' % (count, len(d['times'])))
            d['uncertain'].add('times')

    if d['dosageValue'] is None or d['dosageUnit'] is None:
        d['conf']['dosage'] = 0; d['uncertain'].add('dosage')
        d['issues'].append('没听清每次吃多少，请补充（如「一片」「两粒」）')
    else:
        d['conf']['dosage'] = 0.95

    if not d['name']:
        d['issues'].append('没听清药名，请重说或手动填写')

    uniq = []
    for t in d['times']:
        if t not in uniq:
            uniq.append(t)
    d['times'] = sorted(uniq)
    return d


CASES = [
    ('二甲双胍 每天两次 早晚各一片 饭后吃', '二甲双胍', (1.0, '片'), ['08:00', '20:00'], 0),
    ('三餐后各一片 阿卡波糖', '阿卡波糖', (1.0, '片'), ['08:00', '12:30', '19:00'], 1),
    ('降压药一片 早上八点', '降压药', (1.0, '片'), ['08:00'], 0),
    ('每八小时一次，两粒', None, (2.0, '粒'), None, 2),
    ('阿司匹林一百毫克 饭后 一天一次', '阿司匹林', (100.0, 'mg'), ['08:00'], 1),
    ('睡前一片 阿托伐他汀', '阿托伐他汀', (1.0, '片'), ['21:30'], 0),
    ('优甲乐 早上七点半 半片', '左甲状腺素', (0.5, '片'), ['07:30'], 0),
    ('一天三次 二甲双胍 每次一片', '二甲双胍', (1.0, '片'), ['08:00', '12:30', '19:00'], 1),
    ('晚上八点吃一片降压药', '降压药', (1.0, '片'), ['20:00'], 0),
    ('格华止 8:30 和 20:30 各一片', '二甲双胍', (1.0, '片'), ['08:30', '20:30'], 0),
    ('一天两次 拜新同 两片 早上和晚上', '硝苯地平', (2.0, '片'), ['08:00', '20:00'], 0),
    ('每次半片 一天一次', None, (0.5, '片'), ['08:00'], 2),
    ('一片半 晚上睡前', None, (1.5, '片'), ['21:30'], 1),
    ('络活喜 每天一次 早上7点 5毫克', '氨氯地平', (5.0, 'mg'), ['07:00'], 0),
    ('十二点吃两片', None, (2.0, '片'), ['12:00'], 1),
]

ok = 0
for text, name, dose, times, max_issues in CASES:
    r = parse(text)
    problems = []
    if name and r['name'] != name:
        problems.append('药名=%s 期望=%s' % (r['name'], name))
    if r['dosageValue'] is None or abs(r['dosageValue'] - dose[0]) > 1e-9 or r['dosageUnit'] != dose[1]:
        problems.append('剂量=%s%s 期望=%s%s' % (r['dosageValue'], r['dosageUnit'], dose[0], dose[1]))
    if times and r['times'] != times:
        problems.append('时间=%s 期望=%s' % (r['times'], times))
    if len(r['issues']) > max_issues:
        problems.append('issues=%s' % r['issues'])
    status = 'PASS' if not problems else 'FAIL'
    if not problems:
        ok += 1
    print('[%s] %s' % (status, text))
    if problems:
        for p in problems:
            print('    - ' + p)
        print('    raw=%s' % r['raw'])
print('\n%d/%d 通过' % (ok, len(CASES)))
