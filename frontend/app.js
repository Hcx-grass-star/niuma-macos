import { evaluateIncome, validateSettings, menuBarContent, menuBarPresentation } from './income-engine.mjs';
import { holidayDataStatus } from './holiday-calendar.mjs';
import { initUpdates } from './updates.js';

/** 默认配置；工资为空时显示首次使用状态，不生成示例收入。 */
const defaults = {
  mode: 'monthly', salary: null, weekdays: [1, 2, 3, 4, 5], start: '09:00', end: '18:00', rests: [{ start: '12:00', end: '13:00' }], divisor: 'schedule', fixedDays: 22, encouragement: true,
  /** 是否在系统托盘悬停提示和菜单中显示当前收入。 */
  trayIncome: false,
  /** 新版托盘显示内容；空值沿用旧开关。 */
  trayContent: null,
  hidden: false,
  /** 收入面板的三块金额分别可见；旧配置默认全部显示。 */
  showCurrentIncome: true,
  /** 是否显示本月累计金额区域。 */
  showMonthlyIncome: true,
  /** 是否显示本年累计金额及说明。 */
  showYearlyIncome: true,
  /** 是否按内置中国大陆节假日及调休安排覆盖每周排班。 */
  chinaHolidayEnabled: false,
};
const storageKey = 'niuma.settings.v1';
/** 当前配置与隐私显示状态；重启后继续保护两个金额。 */
const state = { settings: loadSettings(), hidden: false };
state.hidden = state.settings?.hidden === true;
/** 最近一次成功或无需发送的托盘展示签名，避免重复调用原生层。 */
let lastTrayIncomeSignature = null;
const $ = (id) => document.getElementById(id);

/** 从跨平台本地存储读取设置；损坏数据回退到首次使用状态。 */
function loadSettings() { try { return { ...defaults, ...(JSON.parse(localStorage.getItem(storageKey)) ?? {}) }; } catch { return { ...defaults }; } }
/** 将已验证配置保存到当前用户的本地 WebView 存储。 */
function saveSettings(settings) { localStorage.setItem(storageKey, JSON.stringify(settings)); }
/** 将金额格式化为人民币展示值，内部计算仍保留浮点精度。 */
function money(value) { return value == null ? '—' : `¥${value.toLocaleString('zh-CN', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`; }
/** 仅在托盘展示变化时同步原生提示和菜单；浏览器预览环境保持无副作用。 */
async function syncTrayIncome(snapshot, settings) {
  const presentation = menuBarPresentation(settings, snapshot);
  const enabled = presentation.amount != null;
  const text = enabled ? money(presentation.amount) : '';
  const signature = `${presentation.content}:${enabled}:${text}`;
  if (signature === lastTrayIncomeSignature) return;
  if (!window.__TAURI__?.core?.invoke) { lastTrayIncomeSignature = signature; return; }
  try {
    await window.__TAURI__.core.invoke('update_tray_income', { enabled, text, content: presentation.content });
    lastTrayIncomeSignature = signature;
  } catch (error) {
    console.error('托盘收入同步失败', error);
  }
}
/** 根据同一收入快照更新首页及用户启用的托盘金额。 */
function render() {
  const settings = state.settings?.salary == null ? null : state.settings;
  const snapshot = evaluateIncome(settings, new Date());
  const labels = { unconfigured: ['尚未设置', '等待设置', '设置一下，看看时间值多少钱。'], before: ['尚未上班', '等待上班时间', '慢慢来，今天也会有收获。'], working: ['上班中', '自动计算中', '每一秒，都在为生活攒一点底气。'], resting: ['休息中', '休息期间暂停计薪', '休息一下，生活也需要留白。'], finished: ['本班已结束', '本班计算完成', '今天的努力，已经攒起来了。'], off: ['休息日', '今天好好休息', '好好生活，也是一件正经事。'] };
  const [phase, , quote] = labels[snapshot.phase];
  const basis = settings?.chinaHolidayEnabled === true && ['节假日休息', '调休上班'].includes(snapshot.scheduleReason) ? ` · ${snapshot.scheduleReason}` : '';
  $('phase').textContent = phase + basis; $('phase').title = snapshot.scheduleReason ?? ''; $('quote').textContent = quote;
  $('current-income-section').hidden = state.settings?.showCurrentIncome === false;
  $('monthly-income-section').hidden = state.settings?.showMonthlyIncome === false;
  $('yearly-income-section').hidden = state.settings?.showYearlyIncome === false;
  $('status-dot').dataset.phase = snapshot.phase;
  $('quote').hidden = settings?.encouragement === false;
  $('amount').textContent = state.hidden ? '••••' : money(snapshot.amount);
  $('salary').type = state.hidden ? 'password' : 'number';
  $('month-amount').textContent = state.hidden ? '••••' : money(snapshot.monthToDateAmount);
  $('year-amount').textContent = state.hidden ? '••••' : money(snapshot.yearToDateAmount);
  $('hide').textContent = state.hidden ? '◎' : '◉'; $('hide').setAttribute('aria-label', state.hidden ? '显示金额' : '隐藏金额');
  void syncTrayIncome(snapshot, settings);
}
/** 保存成功后才切换两个金额的显示状态，避免重启后意外暴露收入。 */
function togglePrivacy() {
  const hidden = !state.hidden;
  try {
    const next = { ...state.settings, hidden };
    saveSettings(next);
    state.settings = next;
    state.hidden = hidden;
    render();
  } catch {
    window.alert('金额隐藏状态保存失败，请重试。');
  }
}
/** 根据设置状态切换月薪折算字段，避免日薪模式出现无效输入。 */
function updateDraftVisibility() { const monthly = $('mode').value === 'monthly'; $('divisor-wrap').hidden = !monthly; $('fixed-wrap').hidden = !monthly || $('divisor').value !== 'fixed'; $('rest-fields').hidden = !$('rest-enabled').checked; }
/** 用当前设置填充编辑表单，取消编辑不会改变已生效配置。 */
function openSettings() {
  const s = state.settings ?? defaults; $('show-current-income').checked = s.showCurrentIncome !== false; $('show-monthly-income').checked = s.showMonthlyIncome !== false; $('show-yearly-income').checked = s.showYearlyIncome !== false; $('mode').value = s.mode; $('salary').value = s.salary ?? ''; $('start').value = s.start; $('end').value = s.end; $('rest-enabled').checked = s.rests.length > 0; $('rest-start').value = s.rests[0]?.start ?? '12:00'; $('rest-end').value = s.rests[0]?.end ?? '13:00'; $('divisor').value = s.divisor; $('fixed-days').value = s.fixedDays; $('encouragement').checked = s.encouragement !== false; $('tray-content').value = menuBarContent(s); $('china-holiday').checked = s.chinaHolidayEnabled === true; updateHolidayStatus();
  document.querySelectorAll('.weekday').forEach((button) => { button.setAttribute('aria-pressed', String(s.weekdays.includes(Number(button.dataset.day)))); });
  $('error').hidden = true; $('home').hidden = true; $('settings').hidden = false; updateDraftVisibility();
}
/** 根据当前年份显示年度数据覆盖范围，缺失年份明确回退规则。 */
function updateHolidayStatus() { const status = holidayDataStatus(new Date().getFullYear(), $('china-holiday').checked); $('holiday-status').textContent = status.message; $('holiday-status').hidden = !status.message; }
/** 请求 Tauri 平台层切换登录启动；浏览器预览环境保持可用并跳过系统调用。 */
async function setAutostart(enabled) { if (window.__TAURI__?.core?.invoke) { try { await window.__TAURI__.core.invoke('set_autostart', { enabled }); } catch (error) { $('error').textContent = `自动启动设置失败：${error}`; $('error').hidden = false; } } }
/** 读取平台层实际登录启动状态；浏览器预览默认保持关闭。 */
async function loadAutostart() { if (window.__TAURI__?.core?.invoke) { try { $('autostart').checked = await window.__TAURI__.core.invoke('autostart_enabled'); } catch { $('autostart').checked = false; } } }
/** 连接无边框窗口按钮；关闭事件仍由 Rust 拦截并转换为隐藏到托盘。 */
function initWindowControls() {
  const appWindow = window.__TAURI__?.window?.getCurrentWindow?.();
  if (!appWindow) return;
  $('window-minimize').addEventListener('click', () => { void appWindow.minimize(); });
  $('window-close').addEventListener('click', () => { void appWindow.close(); });
}
/** 仅 Windows 显示宠物入口；失败时保留托盘入口并说明原因。 */
async function initDesktopPet() {
  if (!window.__TAURI__?.core?.invoke) return;
  try {
    const [, platform] = await window.__TAURI__.core.invoke('update_environment');
    if (platform !== 'windows') return;
    $('open-pet').hidden = false;
    $('open-pet').addEventListener('click', async () => {
      try { await window.__TAURI__.core.invoke('show_desktop_pet'); }
      catch { window.alert('桌面宠物暂时无法打开，请从托盘重试。'); }
    });
  } catch (error) { console.error('桌面宠物入口初始化失败', error); }
}
/** 接收其他窗口保存的隐私状态，确保主面板与宠物同时遮蔽金额。 */
function syncSettingsFromStorage(event) {
  if (event.key !== storageKey && event.key !== null) return;
  state.settings = loadSettings();
  state.hidden = state.settings.hidden === true;
  render();
}
/** 从表单构造设置、校验后原子保存，并返回收入面板。 */
function submitSettings(event) { event.preventDefault(); const next = { mode: $('mode').value, salary: Number($('salary').value), weekdays: [...document.querySelectorAll('.weekday[aria-pressed="true"]')].map((button) => Number(button.dataset.day)), start: $('start').value, end: $('end').value, rests: $('rest-enabled').checked ? [{ start: $('rest-start').value, end: $('rest-end').value }] : [], divisor: $('divisor').value, fixedDays: Number($('fixed-days').value), encouragement: $('encouragement').checked, trayIncome: $('tray-content').value !== 'icon', trayContent: $('tray-content').value, hidden: state.hidden, showCurrentIncome: $('show-current-income').checked, showMonthlyIncome: $('show-monthly-income').checked, showYearlyIncome: $('show-yearly-income').checked, chinaHolidayEnabled: $('china-holiday').checked }; try { validateSettings(next); saveSettings(next); state.settings = next; $('settings').hidden = true; $('home').hidden = false; render(); } catch (error) { $('error').textContent = error.message; $('error').hidden = false; } }
/** 初始化星期按钮，使用 JavaScript 的周日 0 到周六 6 编号。 */
function initWeekdays() { const names = ['日', '一', '二', '三', '四', '五', '六']; $('weekdays').innerHTML = names.map((name, day) => `<button class="weekday" type="button" data-day="${day}" aria-pressed="${defaults.weekdays.includes(day)}">${name}</button>`).join(''); document.querySelectorAll('.weekday').forEach((button) => button.addEventListener('click', () => button.setAttribute('aria-pressed', String(button.getAttribute('aria-pressed') !== 'true')))); }

/** 托盘菜单直接切换时也原子保存偏好，工资草稿不参与修改。 */
function changeTrayContent(content) {
  if (!['icon', 'current', 'month'].includes(content)) return;
  const next = { ...state.settings, trayContent: content, trayIncome: content !== 'icon' };
  try { saveSettings(next); state.settings = next; $('tray-content').value = content; lastTrayIncomeSignature = null; render(); }
  catch { window.alert('菜单栏显示设置保存失败，请重试。'); }
}
if (window.__TAURI__?.event?.listen) window.__TAURI__.event.listen('set-tray-content', (event) => changeTrayContent(event.payload));
initWeekdays(); initWindowControls(); $('open-settings').addEventListener('click', openSettings); $('back').addEventListener('click', () => { $('settings').hidden = true; $('home').hidden = false; render(); }); $('settings').addEventListener('submit', submitSettings); $('mode').addEventListener('change', updateDraftVisibility); $('divisor').addEventListener('change', updateDraftVisibility); $('rest-enabled').addEventListener('change', updateDraftVisibility); $('china-holiday').addEventListener('change', updateHolidayStatus); $('autostart').addEventListener('change', () => setAutostart($('autostart').checked)); $('hide').addEventListener('click', togglePrivacy);
if (window.__TAURI__?.event?.listen) window.__TAURI__.event.listen('open-settings', openSettings);
render(); if (state.settings?.salary == null) openSettings(); setInterval(render, 1000);
loadAutostart();
void initDesktopPet();
window.addEventListener('storage', syncSettingsFromStorage);
initUpdates();
