import { evaluateIncome } from './income-engine.mjs';

/** 显示项的稳定编号与中文名称；用于设置选项和浮窗指标。 */
export const petItems = {
  current: '当前已赚', month: '本月预估已赚', year: '本年预估已赚',
  status: '工作状态', clock: '当前时间',
};
/** 沿用原来的收入和状态展示，旧版本无需迁移工资设置。 */
export const defaultPetPreferences = {
  /** 勾选的显示项；空数组表示仅保留宠物。 */
  items: ['current', 'status'],
  /** 用户自己的陪伴文字，留空时使用所选状态的默认文案。 */
  text: '',
};
/** 各工作阶段的状态和陪伴文案，缺少工资时明确提示设置。 */
const phases = {
  unconfigured: ['尚未设置', '先设置工资和作息吧'],
  before: ['尚未上班', '养足精神，等会儿一起赚'],
  working: ['上班中', '每一秒，都在攒一点底气'],
  resting: ['休息中', '暂停计薪，歇一会儿吧'],
  finished: ['本班已结束', '今天辛苦啦，下班快乐'],
  off: ['休息日', '今天的任务：好好生活'],
};

/** 兼容缺失或损坏的偏好，过滤未知项，保留明确选择的空数组。 */
export function normalizePetPreferences(value) {
  const items = Array.isArray(value?.items) ? value.items : defaultPetPreferences.items;
  return {
    items: Object.keys(petItems).filter((item) => items.includes(item)),
    text: typeof value?.text === 'string' ? value.text.replace(/\s+/g, ' ').trim().slice(0, 40) : '',
  };
}

/** 从同一收入核心产生可选内容；所有收入项统一遮蔽，自定义文字仅作为纯文本。 */
export function petPresentation(preferences, settings, now = new Date()) {
  const prefs = normalizePetPreferences(preferences);
  let snapshot;
  try { snapshot = evaluateIncome(settings?.salary == null ? null : settings, now); }
  catch { snapshot = evaluateIncome(null, now); }
  const [phase, message] = phases[snapshot.phase];
  const values = { current: snapshot.amount, month: snapshot.monthToDateAmount, year: snapshot.yearToDateAmount };
  const metrics = Object.keys(values).filter((item) => prefs.items.includes(item)).map((item) => ({
    id: item,
    label: petItems[item],
    value: settings?.hidden === true ? '••••' : values[item] == null ? '—' : `¥${values[item].toLocaleString('zh-CN', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`,
  }));
  const showStatus = prefs.items.includes('status');
  return {
    phase: snapshot.phase, status: showStatus ? phase : '', metrics,
    message: showStatus && settings?.encouragement !== false ? message : '',
    clock: prefs.items.includes('clock') ? now.toLocaleTimeString('zh-CN', { hour12: false }) : '',
    text: prefs.text,
    onlyPet: prefs.items.length === 0 && !prefs.text,
  };
}
