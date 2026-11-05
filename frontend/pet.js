import { petItems, normalizePetPreferences, petPresentation } from './pet-display.mjs';

/** 与主面板共用同源配置，只读取实际工资，不生成演示收入。 */
const storageKey = 'niuma.settings.v1';
/** 浮窗偏好独立保存，工资表单保存不会覆盖显示内容。 */
const preferencesKey = 'niuma.pet.v1';
/** 读取主面板配置；无设置或损坏时只显示未配置状态。 */
function readSettings() {
  try { return JSON.parse(localStorage.getItem(storageKey)); }
  catch { return null; }
}
/** 读取浮窗偏好；旧版没有该键时保留原有收入及状态展示。 */
function readPreferences() {
  try { return normalizePetPreferences(JSON.parse(localStorage.getItem(preferencesKey))); }
  catch { return normalizePetPreferences(null); }
}
/** 按真实时钟计算同一班次收入；系统休眠恢复后直接重算，不累加计时。 */
function renderPet() {
  const settings = readSettings();
  const view = petPresentation(readPreferences(), settings);
  document.querySelector('.pet').dataset.phase = view.phase;
  document.querySelector('.pet').classList.toggle('only-pet', view.onlyPet);
  document.getElementById('pet-bubble').hidden = view.onlyPet;
  document.getElementById('pet-phase').textContent = view.status;
  document.getElementById('pet-phase').hidden = !view.status;
  document.getElementById('pet-message').textContent = view.message;
  document.getElementById('pet-message').hidden = !view.message;
  document.getElementById('pet-clock').textContent = view.clock;
  document.getElementById('pet-clock').hidden = !view.clock;
  document.getElementById('pet-custom-text').textContent = view.text;
  document.getElementById('pet-custom-text').hidden = !view.text;
  const metrics = document.getElementById('pet-details');
  metrics.hidden = view.metrics.length === 0;
  metrics.classList.toggle('multiple', view.metrics.length > 1);
  metrics.replaceChildren(...view.metrics.map((metric) => {
    const row = document.createElement('span');
    row.className = 'pet-metric';
    const label = document.createElement('span');
    label.className = 'caption'; label.textContent = metric.label;
    const value = document.createElement('strong');
    value.className = 'pet-value'; value.textContent = metric.value;
    if (metric.id === 'current') value.id = 'pet-amount';
    row.append(label, value);
    return row;
  }));
  const privacy = document.getElementById('pet-privacy');
  privacy.hidden = view.metrics.length === 0;
  privacy.disabled = settings?.salary == null;
  privacy.textContent = settings?.hidden === true ? '◎' : '◉';
  privacy.title = settings?.hidden === true ? '显示金额' : '隐藏金额';
  privacy.setAttribute('aria-label', privacy.title);
}
/** 打开显示草稿，定时刷新不会重置正在勾选或输入的内容。 */
function openPreferences() {
  const prefs = readPreferences();
  document.querySelectorAll('[name="pet-item"]').forEach((input) => { input.checked = prefs.items.includes(input.value); });
  document.getElementById('pet-text-input').value = prefs.text;
  document.getElementById('pet-preferences-error').hidden = true;
  document.querySelector('.pet').hidden = true;
  document.getElementById('pet-preferences').hidden = false;
  document.querySelector('[name="pet-item"]').focus();
}
/** 退出草稿后恢复浮窗；取消编辑不写入持久配置。 */
function closePreferences() {
  document.getElementById('pet-preferences').hidden = true;
  document.querySelector('.pet').hidden = false;
  renderPet();
  document.getElementById(document.querySelector('.pet').classList.contains('only-pet') ? 'pet-only-settings' : 'pet-settings').focus();
}
/** 保存独立显示偏好后立即生效；写入失败留在设置页并保留原配置。 */
function savePreferences(event) {
  event.preventDefault();
  const preferences = normalizePetPreferences({
    items: [...document.querySelectorAll('[name="pet-item"]:checked')].map((input) => input.value),
    text: document.getElementById('pet-text-input').value,
  });
  try {
    localStorage.setItem(preferencesKey, JSON.stringify(preferences));
    closePreferences();
  } catch {
    document.getElementById('pet-preferences-error').textContent = '显示设置保存失败，请重试';
    document.getElementById('pet-preferences-error').hidden = false;
  }
}
/** 根据同一显示项清单生成表单，后续增加内容时不再维护第二套选项。 */
function initPreferences() {
  const fields = document.getElementById('pet-item-fields');
  for (const [id, title] of Object.entries(petItems)) {
    const label = document.createElement('label');
    const input = document.createElement('input');
    input.type = 'checkbox'; input.name = 'pet-item'; input.value = id;
    label.append(input, document.createTextNode(title));
    fields.append(label);
  }
  document.getElementById('pet-settings').addEventListener('click', openPreferences);
  document.getElementById('pet-only-settings').addEventListener('click', openPreferences);
  document.getElementById('pet-cancel-preferences').addEventListener('click', closePreferences);
  document.getElementById('pet-preferences').addEventListener('submit', savePreferences);
  document.getElementById('pet-preferences').addEventListener('keydown', (event) => {
    if (event.key === 'Escape') { event.preventDefault(); closePreferences(); }
  });
}
/** 同步保存隐私开关，storage 事件通知主窗口；写入失败时不改变显示。 */
function togglePrivacy() {
  const settings = readSettings();
  if (settings?.salary == null) return;
  try {
    localStorage.setItem(storageKey, JSON.stringify({ ...settings, hidden: settings.hidden !== true }));
    renderPet();
  } catch { document.getElementById('pet-message').textContent = '隐藏状态保存失败，请重试'; }
}
/** 打开原有主窗口，浏览器预览则导航到同源收入页。 */
async function openDetails() {
  try {
    if (window.__TAURI__?.core?.invoke) await window.__TAURI__.core.invoke('show_income_window');
    else window.location.href = './index.html';
  } catch { document.getElementById('pet-message').textContent = '收入面板暂时无法打开'; }
}
/** 隐藏原生宠物窗口；主进程拦截关闭，因此托盘仍可恢复窗口。 */
async function hidePet() {
  try {
    const appWindow = window.__TAURI__?.window?.getCurrentWindow?.();
    if (appWindow) await appWindow.close();
    else document.getElementById('pet-message').textContent = 'Windows 版可隐藏到托盘';
  } catch { document.getElementById('pet-message').textContent = '暂时无法隐藏，请重试'; }
}

document.getElementById('pet-privacy').addEventListener('click', togglePrivacy);
document.getElementById('pet-details').addEventListener('click', openDetails);
document.getElementById('pet-close').addEventListener('click', hidePet);
initPreferences();
window.addEventListener('storage', renderPet);
window.addEventListener('focus', renderPet);
document.addEventListener('visibilitychange', renderPet);
renderPet();
setInterval(renderPet, 1000);
