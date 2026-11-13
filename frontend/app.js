import { earnedBetween, evaluateIncome, validateSettings, menuBarContent, menuBarPresentation, nextIncomeBoundary } from './income-engine.mjs';
import { holidayDataStatus, isScheduledDate } from './holiday-calendar.mjs';
import { initCountdowns, countdownState, menuPresentation, chooseIncomeDisplay } from './countdowns.js';
import { initUpdates } from './updates.js';
import { emptyCheer, projectedEarned, settleCheer, shouldAutoWood, validateCheer, wishTotal } from './cheer-engine.mjs';

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
  /** 是否在应用运行期间提醒上班、休息和下班节点。 */
  workReminders: false,
  /** Windows 端的等价外观设置；玻璃材质只属于 macOS AppKit。 */
  appearance: { mode: 'system', tintHex: null },
};
const storageKey = 'niuma.settings.v1';
/** 打气配置独立存储，避免迁移或清除时覆盖工资设置。 */
const cheerStorageKey = 'niuma.cheer.v1';
/** 工作提醒与主题偏好沿用工资配置，旧配置缺少字段时使用关闭/系统默认。 */
const cheerState = {
  preferences: loadCheer(), report: null, page: 'income', merit: 0, awayAt: null, awayReasons: new Set(), lastSettlement: 0, woodTimer: null, reminderTimer: null,
};
/** 当前配置与隐私显示状态；重启后继续保护两个金额。 */
const state = { settings: loadSettings(), hidden: false };
state.hidden = state.settings?.hidden === true;
/** 最近一次成功或无需发送的托盘展示签名，避免重复调用原生层。 */
let lastTrayIncomeSignature = null;
/** 全应用收入和倒计时共用的唯一刷新任务。 */
let refreshTimer = null;
/** 原生窗口可见性由平台层确认，隐藏后停止页面刷新。 */
let nativeVisible = true;
/** 原生通信只发送最新状态，慢调用不会形成无限队列。 */
let pendingTray = null;
/** 同一时刻只执行一次原生托盘更新。 */
let trayBusy = false;
const $ = (id) => document.getElementById(id);

/** 从跨平台本地存储读取设置；损坏数据回退到首次使用状态。 */
function loadSettings() { try { const value = JSON.parse(localStorage.getItem(storageKey)) ?? {}; return { ...defaults, ...value, appearance: { ...defaults.appearance, ...(value.appearance ?? {}) } }; } catch { return { ...defaults, appearance: { ...defaults.appearance } }; } }
/** 将已验证配置保存到当前用户的本地 WebView 存储。 */
function saveSettings(settings) { localStorage.setItem(storageKey, JSON.stringify(settings)); }
/** 从独立存储读取打气配置；损坏时保留原文并显示可恢复错误。 */
function loadCheer() { try { const value = { ...emptyCheer(), ...(JSON.parse(localStorage.getItem(cheerStorageKey)) ?? {}) }; validateCheer(value); return value; } catch { return { ...emptyCheer(), loadError: '打气配置无法读取，原数据已保留；保存新设置后才会替换。' }; } }
/** 只在配置完整结算后写入打气数据，避免每秒刷新造成写盘。 */
function saveCheer(value) { const next = { ...value }; delete next.loadError; validateCheer(next); localStorage.setItem(cheerStorageKey, JSON.stringify(next)); cheerState.preferences = next; }

/** 将金额格式化为隐私安全的愿望文本；隐藏时不暴露金额和百分比。 */
function wishDisplay(value, hidden) { return hidden ? '••••' : money(value); }

/** 计算并显示愿望列表，进度使用保存检查点加当前未落盘的投影值。 */
function renderWishes() {
  const list = $('wish-list');
  list.replaceChildren();
  const preferences = cheerState.preferences;
  if (preferences.loadError) { list.textContent = preferences.loadError; return; }
  if (!preferences.wishes.length) { list.textContent = '还没有愿望，给接下来的努力定个小目标吧。'; return; }
  const settings = state.settings?.salary == null ? null : state.settings;
  for (const wish of preferences.wishes) {
    const total = wishTotal(preferences, wish, settings, new Date());
    const ratio = Math.min(1, Math.max(0, total / Number(wish.target)));
    const card = document.createElement('article'); card.className = 'wish-card';
    const title = document.createElement('strong'); title.textContent = wish.name;
    const detail = document.createElement('p'); detail.textContent = `${wishDisplay(total, state.hidden)} / ${wishDisplay(wish.target, state.hidden)}${state.hidden ? '' : ` · ${Math.round(ratio * 100)}%`}`;
    const progress = document.createElement('div'); progress.className = 'wish-progress';
    const fill = document.createElement('span'); fill.style.width = state.hidden ? '0%' : `${ratio * 100}%`; progress.append(fill);
    const actions = document.createElement('div'); actions.className = 'wish-actions';
    const edit = document.createElement('button'); edit.type = 'button'; edit.textContent = '编辑'; edit.addEventListener('click', () => openWishForm(wish));
    const remove = document.createElement('button'); remove.type = 'button'; remove.textContent = '删除'; remove.addEventListener('click', () => removeWish(wish.id));
    actions.append(edit, remove); card.append(title, detail, progress, actions); list.append(card);
  }
}

/** 根据当前页面和金额隐私状态刷新四页打气内容。 */
function renderCheer(snapshot) {
  const page = cheerState.page;
  document.querySelectorAll('#cheer-navigation button').forEach(button => { button.setAttribute('aria-selected', String(button.dataset.page === page)); });
  for (const id of ['income', 'report', 'wishes', 'wood']) $(`${id}-page`).hidden = id !== page;
  if (page === 'report') {
    $('reports-enabled').checked = cheerState.preferences.reportsEnabled === true;
    $('notifications-enabled').checked = cheerState.preferences.notificationsEnabled !== false;
    $('report-empty').hidden = Boolean(cheerState.report);
    $('report-card').hidden = !cheerState.report;
    if (cheerState.report) $('report-detail').textContent = `离开 ${Math.max(1, Math.round((cheerState.report.end - cheerState.report.start) / 60000))} 分钟，预估收入 +${state.hidden ? '••••' : money(cheerState.report.amount)}`;
    $('report-status').textContent = cheerState.preferences.loadError ?? '';
  }
  if (page === 'wishes') renderWishes();
  if (page === 'wood') {
    $('merit').textContent = `功德 ${cheerState.merit}`;
    $('auto-wood').checked = cheerState.preferences.autoWood === true;
    $('wood-sound').checked = cheerState.preferences.sound === true;
    $('wood-status').textContent = shouldAutoWood(cheerState.preferences.autoWood, snapshot.phase, nativeVisible && page === 'wood', Boolean(cheerState.awayAt)) ? '自动敲击中 · 每 1.5 秒一下' : cheerState.preferences.autoWood ? '自动已暂停 · 工作中展开本页恢复' : '自动敲击默认关闭。';
  }
  syncWoodfish(snapshot);
}

/** 保存当前检查点并按同一工资规则结算愿望累计。 */
function settleCheerNow(settings = state.settings, now = new Date()) {
  if (cheerState.preferences.loadError) return;
  try { const next = settleCheer(cheerState.preferences, settings?.salary == null ? null : settings, now); saveCheer(next); cheerState.lastSettlement = now.getTime(); }
  catch (error) { cheerState.preferences.loadError = error.message; }
}

/** 创建或编辑愿望表单；隐私模式禁止打开带金额的编辑内容。 */
function openWishForm(wish = null) {
  if (state.hidden) { window.alert('请先显示金额，再编辑愿望金额。'); return; }
  $('wish-form').hidden = false; $('wish-id').value = wish?.id ?? ''; $('wish-name').value = wish?.name ?? ''; $('wish-target').value = wish?.target ?? ''; $('wish-seed').value = wish?.seed ?? 0; $('wish-error').textContent = ''; $('wish-name').focus();
}

/** 保存愿望并为新愿望建立当前累计起点。 */
function submitWish(event) {
  event.preventDefault();
  const name = $('wish-name').value.trim(); const target = Number($('wish-target').value); const seed = Number($('wish-seed').value);
  const next = structuredClone(cheerState.preferences); const id = $('wish-id').value;
  const currentEarned = projectedEarned(next, state.settings?.salary == null ? null : state.settings, new Date());
  const existing = next.wishes.find(wish => wish.id === id);
  if (existing) Object.assign(existing, { name, target, seed });
  else next.wishes.push({ id: crypto.randomUUID(), name, target, seed, baseline: currentEarned });
  try { validateCheer(next); saveCheer(next); $('wish-form').hidden = true; render(); }
  catch (error) { $('wish-error').textContent = error.message; }
}

/** 删除前要求用户确认，只移除目标本身。 */
function removeWish(id) {
  if (!window.confirm('删除这个愿望？工资和其他愿望不会改变。')) return;
  const next = structuredClone(cheerState.preferences); next.wishes = next.wishes.filter(wish => wish.id !== id);
  try { saveCheer(next); render(); } catch (error) { window.alert(error.message); }
}

/** 手动敲击增加当前会话功德，并按开关播放短促反馈。 */
function strikeWoodfish() {
  cheerState.merit += 1; $('woodfish').classList.add('struck'); setTimeout(() => $('woodfish').classList.remove('struck'), 120); render();
  if (cheerState.preferences.sound) { try { const context = new AudioContext(); const oscillator = context.createOscillator(); const gain = context.createGain(); oscillator.frequency.value = 240; gain.gain.setValueAtTime(.06, context.currentTime); gain.gain.exponentialRampToValueAtTime(.001, context.currentTime + .08); oscillator.connect(gain).connect(context.destination); oscillator.start(); oscillator.stop(context.currentTime + .08); } catch {} }
}

/** 只在工作中、木鱼页可见且未离开时维护自动敲击定时器。 */
function syncWoodfish(snapshot) {
  const active = shouldAutoWood(cheerState.preferences.autoWood, snapshot.phase, nativeVisible && cheerState.page === 'wood', Boolean(cheerState.awayAt));
  if (active && !cheerState.woodTimer) cheerState.woodTimer = setInterval(strikeWoodfish, 1500);
  if (!active && cheerState.woodTimer) { clearInterval(cheerState.woodTimer); cheerState.woodTimer = null; }
}

/** 返回时按两分钟门槛生成一条战报，重复离开原因只保留一次起点。 */
function returnFromAway(reason) {
  cheerState.awayReasons.delete(reason); if (cheerState.awayReasons.size || !cheerState.awayAt) return;
  const start = cheerState.awayAt; cheerState.awayAt = null; const end = new Date();
  if (!cheerState.preferences.reportsEnabled || end - start < 120000 || state.settings?.salary == null) return;
  try {
    const reportAmount = earnedBetween(state.settings, start, end);
    if (reportAmount > 0.005) { cheerState.report = { start, end, amount: reportAmount }; if (cheerState.preferences.notificationsEnabled !== false) notifyReport(); }
  } catch (error) { cheerState.report = null; console.warn('战报计算失败', error); }
  render();
}

/** 使用系统通知能力提示用户查看战报；通知内容不含金额和愿望名称。 */
function notifyReport() { try { if ('Notification' in window && Notification.permission === 'granted') new Notification('欢迎回来，辛苦了', { body: '离开期间，收入又向前走了一点。打开牛马上班查看战报。' }); else if ('Notification' in window && Notification.permission === 'default') void Notification.requestPermission(); } catch {} }

/** 进入或离开页面时记录一次离开会话，覆盖窗口隐藏和浏览器标签页切换。 */
function markAway(reason, away) { if (away) { if (!cheerState.awayReasons.size) cheerState.awayAt = new Date(); cheerState.awayReasons.add(reason); } else returnFromAway(reason); syncWoodfish({ phase: 'working' }); }

/** 在计薪边界发送不含金额的工作提醒；提醒失败不影响收入计算。 */
function scheduleReminders() {
  if (cheerState.reminderTimer) { clearTimeout(cheerState.reminderTimer); cheerState.reminderTimer = null; }
  if (!state.settings?.workReminders || state.settings.salary == null) return;
  const now = new Date(); const parse = value => value.split(':').map(Number); const events = [];
  for (let offset = 0; offset <= 8; offset += 1) {
    const day = new Date(now.getFullYear(), now.getMonth(), now.getDate() + offset);
    if (!isScheduledDate(day, state.settings)) continue;
    const at = (value, extraDays = 0) => { const [hour, minute] = parse(value); const result = new Date(day); result.setDate(result.getDate() + extraDays); result.setHours(hour, minute, 0, 0); return result; };
    const startMinutes = parse(state.settings.start)[0] * 60 + parse(state.settings.start)[1]; const endMinutes = parse(state.settings.end)[0] * 60 + parse(state.settings.end)[1];
    const overnight = endMinutes < startMinutes;
    events.push({ at: at(state.settings.start), title: '该开始上班了', body: '新的一班开始了，按自己的节奏来。' });
    for (const rest of state.settings.rests ?? []) {
      events.push({ at: at(rest.start, Number(rest.start < state.settings.start ? 1 : 0)), title: '休息一下', body: '非计薪休息开始，先离开屏幕放松一下。' });
      events.push({ at: at(rest.end, Number(rest.end <= rest.start ? 1 : 0)), title: '休息结束', body: '休息结束，回来继续完成今天的安排。' });
    }
    events.push({ at: at(state.settings.end, overnight ? 1 : 0), title: '今天辛苦了', body: '今天的班结束了，可以安心收工。' });
  }
  const next = events.filter(event => event.at > now).sort((a, b) => a.at - b.at)[0]; if (!next) return;
  cheerState.reminderTimer = setTimeout(() => { notify(next.title, next.body); scheduleReminders(); }, Math.max(1000, next.at - now));
}

/** 统一发送不含工资信息的系统提示，浏览器预览环境忽略权限失败。 */
function notify(title, body) { try { if ('Notification' in window && Notification.permission === 'granted') new Notification(title, { body }); } catch {} }

/** 切换收入、战报、愿望和木鱼页面；切页会重新计算自动敲击状态。 */
function selectCheerPage(page) { if (!['income', 'report', 'wishes', 'wood'].includes(page)) return; if (cheerState.page !== page) { if (page === 'report') settleCheerNow(); cheerState.page = page; } render(); }
/** 将金额格式化为人民币展示值，内部计算仍保留浮点精度。 */
function money(value) { return value == null ? '—' : `¥${value.toLocaleString('zh-CN', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`; }
/** 只把变化后的文本提交原生层，串行发送并合并等待中的更新。 */
async function syncTrayIncome(presentation) {
  pendingTray = presentation;
  if (trayBusy) return;
  trayBusy = true;
  try {
    while (pendingTray) {
      const value = pendingTray; pendingTray = null;
      const signature = JSON.stringify(value);
      if (signature === lastTrayIncomeSignature) continue;
      if (window.__TAURI__?.core?.invoke) await window.__TAURI__.core.invoke('update_tray_display', { text: value.text, fullText: value.full, content: value.content });
      lastTrayIncomeSignature = signature;
    }
  } catch (error) { console.error('托盘显示同步失败', error); }
  finally { trayBusy = false; }
}
/** 只写变化的文本，不反复触发相同的布局与辅助功能播报。 */
function setText(id, value) { if ($(id).textContent !== value) $(id).textContent = value; }
/** 根据同一收入快照更新首页及用户启用的托盘金额。 */
function render() {
  clearTimeout(refreshTimer); refreshTimer = null;
  const now = new Date();
  const homeVisible = nativeVisible && !$('home').hidden;
  const info = countdownState(state.settings, now, homeVisible);
  const settings = state.settings?.salary == null ? null : state.settings;
  const snapshot = evaluateIncome(settings, now);
  $('salary').type = state.hidden ? 'password' : 'number';
  if (homeVisible) {
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
    $('month-amount').textContent = state.hidden ? '••••' : money(snapshot.monthToDateAmount);
    $('year-amount').textContent = state.hidden ? '••••' : money(snapshot.yearToDateAmount);
    $('hide').textContent = state.hidden ? '◎' : '◉'; $('hide').setAttribute('aria-label', state.hidden ? '显示金额' : '隐藏金额');
    renderCheer(snapshot);
  }
  const income = menuBarPresentation({ ...state.settings, trayContent: menuBarContent(state.settings) === 'icon' ? 'current' : menuBarContent(state.settings) }, snapshot);
  const presentation = menuPresentation(info, state.hidden ? '' : income.amount == null ? '' : money(income.amount));
  presentation.content = info.menuIncome ? income.content : 'icon';
  void syncTrayIncome(presentation);
  const incomeVisible = (homeVisible || info.menuIncome) && !state.hidden && settings;
  let delay = info.delay;
  if (incomeVisible) {
    const incomeDelay = snapshot.phase === 'working' ? 1 : Math.max(0.1, (nextIncomeBoundary(settings, now) - now.getTime()) / 1000);
    delay = delay == null ? incomeDelay : Math.min(delay, incomeDelay);
  }
  // 浏览器计时器最多接受 32 位毫秒；长目标分段等待，避免溢出后变成密集刷新。
  if (delay != null) refreshTimer = setTimeout(render, Math.min(delay * 1000, 2147483647));
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
  const s = state.settings ?? defaults; $('show-current-income').checked = s.showCurrentIncome !== false; $('show-monthly-income').checked = s.showMonthlyIncome !== false; $('show-yearly-income').checked = s.showYearlyIncome !== false; $('mode').value = s.mode; $('salary').value = s.salary ?? ''; $('start').value = s.start; $('end').value = s.end; $('rest-enabled').checked = s.rests.length > 0; $('rest-start').value = s.rests[0]?.start ?? '12:00'; $('rest-end').value = s.rests[0]?.end ?? '13:00'; $('divisor').value = s.divisor; $('fixed-days').value = s.fixedDays; $('encouragement').checked = s.encouragement !== false; $('work-reminders').checked = s.workReminders === true; $('appearance-mode').value = s.appearance?.mode ?? 'system'; $('appearance-tint').value = s.appearance?.tintHex ?? ''; $('tray-content').value = menuBarContent(s); $('china-holiday').checked = s.chinaHolidayEnabled === true; updateHolidayStatus();
  document.querySelectorAll('.weekday').forEach((button) => { button.setAttribute('aria-pressed', String(s.weekdays.includes(Number(button.dataset.day)))); });
  $('error').hidden = true; $('home').hidden = true; $('settings').hidden = false; updateDraftVisibility(); render();
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
function submitSettings(event) { event.preventDefault(); const next = { mode: $('mode').value, salary: Number($('salary').value), weekdays: [...document.querySelectorAll('.weekday[aria-pressed="true"]')].map((button) => Number(button.dataset.day)), start: $('start').value, end: $('end').value, rests: $('rest-enabled').checked ? [{ start: $('rest-start').value, end: $('rest-end').value }] : [], divisor: $('divisor').value, fixedDays: Number($('fixed-days').value), encouragement: $('encouragement').checked, workReminders: $('work-reminders').checked, appearance: { mode: $('appearance-mode').value, tintHex: $('appearance-tint').value.trim() || null }, trayIncome: $('tray-content').value !== 'icon', trayContent: $('tray-content').value, hidden: state.hidden, showCurrentIncome: $('show-current-income').checked, showMonthlyIncome: $('show-monthly-income').checked, showYearlyIncome: $('show-yearly-income').checked, chinaHolidayEnabled: $('china-holiday').checked }; try { if (next.appearance.tintHex && !/^[0-9a-f]{6}$/i.test(next.appearance.tintHex)) throw new Error('面板染色必须是六位十六进制 RGB 颜色。'); settleCheerNow(state.settings); validateSettings(next); saveSettings(next); state.settings = next; settleCheerNow(next); applyAppearance(next.appearance); scheduleReminders(); $('settings').hidden = true; $('home').hidden = false; render(); } catch (error) { $('error').textContent = error.message; $('error').hidden = false; } }

/** 应用 Windows 端可实现的主题与背景染色偏好。 */
function applyAppearance(appearance = defaults.appearance) { const root = document.documentElement; root.dataset.appearance = appearance.mode ?? 'system'; root.style.setProperty('--niuma-tint', appearance.tintHex ? `#${appearance.tintHex}` : ''); }

/** 清除本应用拥有的前端配置，并关闭系统登录启动。 */
async function resetSettings() { if (!window.confirm('清除工资、倒计时、愿望和更新设置？此操作无法撤销。')) return; try { localStorage.removeItem(storageKey); localStorage.removeItem(cheerStorageKey); localStorage.removeItem('niuma.countdowns.v1'); localStorage.removeItem('niuma.updates.v1'); if (window.__TAURI__?.core?.invoke) await window.__TAURI__.core.invoke('set_autostart', { enabled: false }); window.location.reload(); } catch { $('error').textContent = '清除设置失败，请检查存储后重试。'; $('error').hidden = false; } }
/** 初始化星期按钮，使用 JavaScript 的周日 0 到周六 6 编号。 */
function initWeekdays() { const names = ['日', '一', '二', '三', '四', '五', '六']; $('weekdays').innerHTML = names.map((name, day) => `<button class="weekday" type="button" data-day="${day}" aria-pressed="${defaults.weekdays.includes(day)}">${name}</button>`).join(''); document.querySelectorAll('.weekday').forEach((button) => button.addEventListener('click', () => button.setAttribute('aria-pressed', String(button.getAttribute('aria-pressed') !== 'true')))); }

/** 托盘菜单直接切换时也原子保存偏好，工资草稿不参与修改。 */
function changeTrayContent(content) {
  if (!['icon', 'current', 'month'].includes(content)) return;
  const next = { ...state.settings, trayContent: content, trayIncome: content !== 'icon' };
  try { chooseIncomeDisplay(content !== 'icon'); saveSettings(next); state.settings = next; $('tray-content').value = content; lastTrayIncomeSignature = null; render(); }
  catch { window.alert('菜单栏显示设置保存失败，请重试。'); }
}
if (window.__TAURI__?.event?.listen) window.__TAURI__.event.listen('set-tray-content', (event) => changeTrayContent(event.payload));
initWeekdays(); initWindowControls(); applyAppearance(state.settings?.appearance); $('open-settings').addEventListener('click', openSettings); $('back').addEventListener('click', () => { $('settings').hidden = true; $('home').hidden = false; render(); }); $('settings').addEventListener('submit', submitSettings); $('mode').addEventListener('change', updateDraftVisibility); $('divisor').addEventListener('change', updateDraftVisibility); $('rest-enabled').addEventListener('change', updateDraftVisibility); $('china-holiday').addEventListener('change', updateHolidayStatus); $('autostart').addEventListener('change', () => setAutostart($('autostart').checked)); $('hide').addEventListener('click', togglePrivacy); $('reset-settings').addEventListener('click', resetSettings);
document.querySelectorAll('#cheer-navigation button').forEach(button => button.addEventListener('click', () => selectCheerPage(button.dataset.page)));
$('reports-enabled').addEventListener('change', () => { const next = { ...cheerState.preferences, reportsEnabled: $('reports-enabled').checked }; try { saveCheer(next); } catch (error) { $('report-status').textContent = error.message; } render(); });
$('notifications-enabled').addEventListener('change', () => { const next = { ...cheerState.preferences, notificationsEnabled: $('notifications-enabled').checked }; try { saveCheer(next); } catch (error) { $('report-status').textContent = error.message; } render(); });
$('wish-add').addEventListener('click', () => openWishForm()); $('wish-form').addEventListener('submit', submitWish); $('wish-cancel').addEventListener('click', () => { $('wish-form').hidden = true; }); $('woodfish').addEventListener('click', strikeWoodfish); $('woodfish').addEventListener('keydown', event => { if (event.code === 'Space') { event.preventDefault(); strikeWoodfish(); } });
$('auto-wood').addEventListener('change', () => { try { saveCheer({ ...cheerState.preferences, autoWood: $('auto-wood').checked }); render(); } catch {} }); $('wood-sound').addEventListener('change', () => { try { saveCheer({ ...cheerState.preferences, sound: $('wood-sound').checked }); render(); } catch {} });
if (window.__TAURI__?.event?.listen) window.__TAURI__.event.listen('open-settings', openSettings);
initCountdowns(render, () => state.settings);
render(); if (state.settings?.salary == null) openSettings();
/** 平台通知直接重新读取可见性，不依赖隐藏 WebView 的秒级轮询。 */
async function refreshVisibility() {
  try { nativeVisible = await window.__TAURI__.core.invoke('main_window_visible'); }
  catch { nativeVisible = !document.hidden; }
  render();
}
if (window.__TAURI__?.event?.listen) {
  void window.__TAURI__.event.listen('window-state-changed', refreshVisibility);
  void refreshVisibility();
} else document.addEventListener('visibilitychange', () => { nativeVisible = !document.hidden; render(); });
window.addEventListener('focus', () => { if (window.__TAURI__) void refreshVisibility(); else render(); });

loadAutostart(); scheduleReminders();
void initDesktopPet();
window.addEventListener('storage', syncSettingsFromStorage);
initUpdates();
document.addEventListener('visibilitychange', () => markAway('document', document.hidden));
window.addEventListener('blur', () => markAway('window', true)); window.addEventListener('focus', () => markAway('window', false));
window.addEventListener('beforeunload', () => settleCheerNow());
