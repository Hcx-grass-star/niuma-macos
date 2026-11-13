import { evaluateCountdowns, countdownText, menuCountdownText, validateCountdowns, nextRefreshDelay, removeCompletedCountdowns } from './countdown-engine.mjs';

/** 倒计时与工资分开保存，旧工资配置无需迁移。 */
const key = 'niuma.countdowns.v1';
/** 首次保持旧菜单栏收入开关，无事件时不创建示例。 */
const defaults = { events: [], menuMode: null, menuCountdownID: null, menuWidth: null };
/** 仅保存已成功写入存储的状态。 */
let preferences = { ...defaults };
/** 加载错误始终可见，保存前不覆盖原始数据。 */
let loadError = '';
/** 自动删除失败单独报告，不掩盖启动配置读取错误。 */
let cleanupError = '';
try {
  preferences = { ...defaults, ...JSON.parse(localStorage.getItem(key) ?? 'null') };
  validatePreferences(preferences);
} catch { loadError = '倒计时配置无法读取，原数据已保留；重新保存将替换倒计时配置。'; preferences = { ...defaults }; }
/** 编辑草稿不影响正在显示的事件。 */
let draft = [];
/** 保存后通知统一刷新调度器。 */
let changed = () => {};
/** 草稿取消后恢复原页面。 */
let returnToSettings = false;
/** Canvas 只用于测量菜单文本，不渲染动画或位图。 */
const measure = document.createElement('canvas').getContext('2d');
measure.font = '11px -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif';
const $ = id => document.getElementById(id);

/** 保存和启动共用严格校验，宽度只允许已约定范围。 */
function validatePreferences(value) {
  validateCountdowns(value.events);
  if (value.menuMode != null && !['icon', 'income', 'countdown', 'both'].includes(value.menuMode)) throw new Error('请选择有效的菜单栏内容。');
  if (value.menuWidth != null && (!Number.isFinite(value.menuWidth) || value.menuWidth < 60 || value.menuWidth > 240)) throw new Error('菜单栏宽度须为 60–240 pt。');
}
/** 只在文本改变时更新节点，避免相同 DOM 每秒重复布局。 */
function text(node, value) { if (node.textContent !== value) node.textContent = value; }
/** 先持久化到期删除再更新摘要；失败保留旧配置并显示原因。 */
export function countdownState(settings, now, visible) {
  const cleaned = removeCompletedCountdowns(preferences, now);
  if (cleaned !== preferences) {
    try {
      localStorage.setItem(key, JSON.stringify(cleaned));
      preferences = cleaned;
      cleanupError = '';
    } catch { cleanupError = '已完成倒计时删除失败，请检查存储后重试。'; }
    if (!$('countdown-settings').hidden && cleanupError) text($('countdown-error'), cleanupError);
  }
  const snapshots = evaluateCountdowns(preferences.events, settings?.salary == null ? null : settings, now);
  const primary = snapshots.find(s => s.id === preferences.menuCountdownID) ?? snapshots[0];
  const mode = preferences.menuMode ?? ((settings?.trayContent ?? (settings?.trayIncome ? 'current' : 'icon')) !== 'icon' ? 'income' : 'icon');
  const menuCountdown = mode === 'countdown' || mode === 'both';
  const menuIncome = mode === 'income' || mode === 'both';
  if (visible) {
    const summary = snapshots.slice(0, 3).map(s => `${s.title}：${countdownText(s)}`).join('\n');
    text($('countdown-summary'), loadError || cleanupError || summary);
    $('countdown-summary').hidden = !summary && !loadError && !cleanupError;
  }
  return { snapshots, primary, menuCountdown, menuIncome, width: preferences.menuWidth, delay: nextRefreshDelay(snapshots, visible, menuCountdown ? primary?.id : null, false) };
}
/** 固定宽度内保留时间，再截断标题；自动模式完整显示。 */
export function menuPresentation(info, income) {
  const countdown = info.menuCountdown && info.primary ? menuCountdownText(info.primary) : '';
  const full = [info.menuIncome ? income : '', countdown].filter(Boolean).join(' · ');
  if (info.width == null) return { full, text: full };
  const available = Math.max(24, info.width - 32);
  const fits = value => measure.measureText(value).width <= available;
  if (fits(full)) return { full, text: full };
  if (countdown) {
    const s = info.primary;
    const time = s.phase === 'pending' && s.remainingSeconds >= 86400 ? `${Math.ceil(s.remainingSeconds / 86400)}天` : countdownText(s);
    const title = [...s.title];
    while (title.length) {
      const value = `${title.join('')}… ${time}`;
      if (fits(value)) return { full, text: value };
      title.pop();
    }
    if (fits(time)) return { full, text: time };
    if (s.phase === 'pending' && s.remainingSeconds < 86400 && fits(time.slice(0, 5))) return { full, text: time.slice(0, 5) };
  }
  const characters = [...full];
  while (characters.length && !fits(`${characters.join('')}…`)) characters.pop();
  return { full, text: characters.length ? `${characters.join('')}…` : full ? '…' : '' };
}
/** 日期输入按用户本地时区展示，保存时转换为绝对时间。 */
function localDate(value) {
  const date = new Date(value);
  const pad = v => String(v).padStart(2, '0');
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}T${pad(date.getHours())}:${pad(date.getMinutes())}`;
}
/** 使用纯文本节点创建事件行，自定义标题不会作为 HTML 执行。 */
function renderRows() {
  const selected = $('countdown-primary').options.length ? $('countdown-primary').value : preferences.menuCountdownID;
  $('countdown-rows').replaceChildren();
  $('countdown-primary').replaceChildren(new Option('自动选择最近事件', ''));
  for (const event of draft) {
    const row = document.createElement('fieldset'); row.className = 'countdown-row';
    const enabled = document.createElement('input'); enabled.type = 'checkbox'; enabled.checked = event.enabled; enabled.setAttribute('aria-label', '启用倒计时');
    const title = document.createElement('input'); title.type = 'text'; title.value = event.title; title.maxLength = 32; title.setAttribute('aria-label', '倒计时标题');
    const type = document.createElement('select'); type.setAttribute('aria-label', '倒计时规则'); type.append(new Option('指定时间', 'fixed'), new Option('下一次下班', 'nextWorkEnd')); type.value = event.type;
    const date = document.createElement('input'); date.type = 'datetime-local'; date.value = localDate(event.targetAt ?? Date.now() + 86400000); date.hidden = event.type !== 'fixed'; date.setAttribute('aria-label', '目标时间');
    const remove = document.createElement('button'); remove.type = 'button'; remove.textContent = '删除';
    title.addEventListener('input', () => { event.title = title.value; updatePrimaryLabels(); });
    enabled.addEventListener('change', () => { event.enabled = enabled.checked; renderRows(); });
    type.addEventListener('change', () => { event.type = type.value; date.hidden = event.type !== 'fixed'; });
    date.addEventListener('change', () => { event.targetAt = new Date(date.value).getTime(); });
    remove.addEventListener('click', () => { draft = draft.filter(e => e.id !== event.id); renderRows(); });
    row.append(enabled, title, remove, type, date); $('countdown-rows').append(row);
    if (event.enabled) $('countdown-primary').add(new Option(event.title, event.id));
  }
  if (draft.some(e => e.id === selected && e.enabled)) $('countdown-primary').value = selected;
  $('countdown-add').disabled = draft.length >= 20;
}
/** 输入标题时不重建编辑框，避免光标跳动。 */
function updatePrimaryLabels() {
  for (const option of $('countdown-primary').options) {
    const event = draft.find(e => e.id === option.value);
    if (event) option.textContent = event.title;
  }
}
/** 打开独立草稿，固定倒计时不经过工资必填验证。 */
function open(settings) {
  countdownState(settings(), new Date(), false);
  returnToSettings = !$('settings').hidden;
  draft = preferences.events.map(event => ({ ...event }));
  $('menu-mode').value = preferences.menuMode ?? ((settings()?.trayContent ?? (settings()?.trayIncome ? 'current' : 'icon')) !== 'icon' ? 'income' : 'icon');
  const width = preferences.menuWidth;
  $('menu-width-mode').value = width == null ? 'auto' : [80, 120, 180].includes(width) ? String(width) : 'custom';
  $('menu-width-custom').value = String(width ?? 120);
  $('menu-width-custom').hidden = $('menu-width-mode').value !== 'custom';
  $('countdown-error').textContent = loadError || cleanupError;
  $('home').hidden = true; $('settings').hidden = true; $('countdown-settings').hidden = false;
  $('countdown-primary').replaceChildren();
  renderRows(); changed();
}
/** 返回进入前页面，不触发工资表单校验。 */
function back() {
  $('countdown-settings').hidden = true;
  $('settings').hidden = !returnToSettings; $('home').hidden = returnToSettings;
  changed();
}
/** 绑定增删保存和独立入口，回调交给统一调度器。 */
export function initCountdowns(onChange, settings) {
  changed = onChange;
  for (const id of ['open-countdowns', 'configure-menu']) $(id).addEventListener('click', () => open(settings));
  $('countdown-back').addEventListener('click', back);
  $('menu-width-mode').addEventListener('change', () => { $('menu-width-custom').hidden = $('menu-width-mode').value !== 'custom'; });
  $('countdown-add').addEventListener('click', () => {
    const preset = $('countdown-preset').value;
    draft.push({ id: crypto.randomUUID(), title: preset, type: preset === '下班' ? 'nextWorkEnd' : 'fixed', enabled: true, targetAt: Math.floor((Date.now() + 86400000) / 60000) * 60000 });
    renderRows();
  });
  $('countdown-settings').addEventListener('submit', event => {
    event.preventDefault();
    const value = $('menu-width-mode').value;
    const next = { events: draft.map(e => ({ ...e, title: e.title.trim() })), menuMode: $('menu-mode').value, menuCountdownID: $('countdown-primary').value || null, menuWidth: value === 'auto' ? null : Number(value === 'custom' ? $('menu-width-custom').value : value) };
    try {
      validatePreferences(next);
      const cleaned = removeCompletedCountdowns(next);
      localStorage.setItem(key, JSON.stringify(cleaned)); preferences = cleaned; loadError = ''; cleanupError = ''; back();
    }
    catch (error) { $('countdown-error').textContent = error.message; }
  });
}

/** 旧版托盘快捷选择显式覆盖展示模式，同时保留主倒计时和宽度。 */
export function chooseIncomeDisplay(enabled) {
  const next = { ...preferences, menuMode: enabled ? 'income' : 'icon' };
  localStorage.setItem(key, JSON.stringify(next));
  preferences = next;
}
