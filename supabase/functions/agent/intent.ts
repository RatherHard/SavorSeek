/**
 * Intent 需求理解（规则版）。
 *
 * MVP 先用确定性规则抽取硬约束（菜系关键词、时段、预算、忌口、人数），
 * 保证“每人 150 元”“不吃辣”这类硬约束绝不丢失。LLM 抽取是后续增强，
 * 接入后只替换本模块，编排层与数据契约不变。
 *
 * 设计依据：multi-agent-arch.md 第 1 节（Agent 理解需求）、
 * 对接设计 5.2 节（constraints 中的硬性条件由确定性规则引擎校验）。
 */
import type { ParsedIntent } from './types.ts';

const MEAL_PERIODS: Array<[RegExp, ParsedIntent['mealPeriod']]> = [
  [/早餐|早点|早饭/, 'breakfast'],
  [/午餐|午饭|正餐(?!晚)/, 'lunch'],
  [/下午茶|下午茶点/, 'afternoon_tea'],
  [/晚餐|晚饭|晚膳/, 'dinner'],
  [/宵夜|夜宵|深夜/, 'late_night'],
];

const AVOID_ITEMS = ['辣', '香菜', '花生', '海鲜', '羊肉', '蒜', '葱', '糖'];

const CUISINE_KEYWORDS = [
  '烧烤',
  '火锅',
  '川菜',
  '粤菜',
  '湘菜',
  '东北菜',
  '日料',
  '寿司',
  '拉面',
  '面馆',
  '小吃',
  '海鲜',
  '烤肉',
  '饺子',
  '包子',
  '奶茶',
  '咖啡',
  '甜品',
  '烘焙',
  '早茶',
  '西餐',
  '披萨',
  '意面',
  '牛排',
  '素食',
];

const AREA_HINT =
  /(宽窄巷子|春熙路|太古里|解放碑|观音桥|外滩|南京路|五道口|三里屯|王府井|鼓浪屿|曾厝垵|中央大街|夫子庙|西湖|上下九|江汉路|黄兴路)/u;

const CITY_HINTS = [
  '北京',
  '上海',
  '广州',
  '深圳',
  '成都',
  '杭州',
  '南京',
  '重庆',
  '西安',
  '武汉',
  '长沙',
  '大连',
  '厦门',
  '青岛',
  '天津',
  '苏州',
  '昆明',
  '贵阳',
  '兰州',
  '沈阳',
  '哈尔滨',
  '郑州',
  '济南',
  '福州',
  '合肥',
  '宁波',
  '无锡',
  '佛山',
  '东莞',
];

/**
 * 从队长指令抽取结构化意图。
 *
 * context 中的结构化字段（mapViewport、constraints）优先于文本猜测：
 * 文本只补足结构化输入没有覆盖的部分。
 */
export function parseCommandIntent(
  rawText: string,
  context: Record<string, unknown>,
  constraints: Record<string, unknown>,
): ParsedIntent {
  const intent: ParsedIntent = {
    keywords: null,
    city: null,
    area: null,
    mealPeriod: null,
    partySize: null,
    budgetPerPersonMinor: null,
    avoid: [],
    needRoute: /路线|安排.{0,6}(行程|路线)|顺路|一路|规划/u.test(rawText),
  };

  // 1. 结构化 constraints 优先。
  const mealPeriod = constraints['mealPeriod'];
  if (typeof mealPeriod === 'string' && isMealPeriod(mealPeriod)) {
    intent.mealPeriod = mealPeriod;
  }
  const budget = constraints['budget'];
  if (isRecord(budget)) {
    const maxMinor = budget['maxMinor'];
    if (typeof maxMinor === 'number' && Number.isFinite(maxMinor) && maxMinor > 0) {
      intent.budgetPerPersonMinor = Math.trunc(maxMinor);
    }
  }
  const partySize = constraints['partySize'];
  if (typeof partySize === 'number' && Number.isInteger(partySize) && partySize > 0) {
    intent.partySize = partySize;
  }
  const keywords = constraints['keywords'];
  if (typeof keywords === 'string' && keywords.trim().length > 0) {
    intent.keywords = keywords.trim();
  }
  const city = constraints['city'];
  if (typeof city === 'string' && city.trim().length > 0) {
    intent.city = city.trim();
  }

  // 2. 文本补充缺失字段。
  if (intent.mealPeriod === null) {
    for (const [pattern, period] of MEAL_PERIODS) {
      if (pattern.test(rawText)) {
        intent.mealPeriod = period;
        break;
      }
    }
  }

  if (intent.budgetPerPersonMinor === null) {
    const perPerson = rawText.match(/(?:人均|每人)\s*(?:不超过|最多|低于)?\s*(\d+(?:\.\d+)?)(?:元|块)?/u)
      ?? rawText.match(/(?:一位|一个人)\s*(?:不超过|最多|低于)?\s*(\d+(?:\.\d+)?)\s*(?:元|块)/u);
    if (perPerson) {
      intent.budgetPerPersonMinor = Math.round(Number(perPerson[1]) * 100);
    } else {
      const bare = rawText.match(/(\d+(?:\.\d+)?)\s*(?:元|块)/u);
      if (bare) {
        intent.budgetPerPersonMinor = Math.round(Number(bare[1]) * 100);
      }
    }
  }

  if (intent.partySize === null) {
    const partyMatch = rawText.match(/(\d+)\s*个?人/u);
    if (partyMatch) {
      intent.partySize = Number(partyMatch[1]);
    } else if (/两个人|俩人|二人/u.test(rawText)) {
      intent.partySize = 2;
    } else if (/三个人|仨人/u.test(rawText)) {
      intent.partySize = 3;
    } else if (/四个人/u.test(rawText)) {
      intent.partySize = 4;
    } else if (/一个人|独自|单独/u.test(rawText)) {
      intent.partySize = 1;
    }
  }

  intent.avoid = AVOID_ITEMS.filter((item) =>
    new RegExp(`(?:不吃|不要|忌|别放|不碰|不能吃)\\S{0,4}${item}|${item}(?:过敏|不(?:能|要)吃)`, 'u').test(rawText)
  );
  const noSpicyAll = /不吃辣|不要辣|忌辣|不辣|微辣都不要/u.test(rawText);
  if (noSpicyAll && !intent.avoid.includes('辣')) {
    intent.avoid.push('辣');
  }

  if (intent.city === null) {
    for (const candidate of CITY_HINTS) {
      if (rawText.includes(candidate)) {
        intent.city = candidate;
        break;
      }
    }
  }

  if (intent.city !== null) {
    const afterCity = rawText.split(intent.city)[1] ?? '';
    const areaMatch = afterCity.match(AREA_HINT);
    if (areaMatch) {
      intent.area = areaMatch[1];
    }
  }
  if (intent.area === null) {
    const areaMatch = rawText.match(AREA_HINT);
    if (areaMatch) {
      intent.area = areaMatch[1];
    }
  }

  if (intent.keywords === null) {
    const found = CUISINE_KEYWORDS.filter((word) => rawText.includes(word));
    if (found.length > 0) {
      intent.keywords = found.join(' ');
    }
  }

  return intent;
}

function isMealPeriod(value: string): value is NonNullable<ParsedIntent['mealPeriod']> {
  return ['breakfast', 'lunch', 'afternoon_tea', 'dinner', 'late_night'].includes(value);
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}
