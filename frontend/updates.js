import { checkForUpdate, shouldCheckAutomatically } from './update-check.mjs';

/** 更新偏好独立存储，避免改动或上传工资与排班。 */
const preferenceKey = 'niuma.updates.v1';
/** 版本检查状态；只在检查时请求网络，不参与收入的秒级刷新。 */
const state = { preferences: loadPreferences(), version: null, platform: null, checking: false, installing: false, release: null, status: '尚未检查更新。', cleanupWarning: '' };

/** 读取检查开关和最近自动尝试时间，旧用户默认开启。 */
function loadPreferences() {
  try {
    const value = JSON.parse(localStorage.getItem(preferenceKey));
    return { enabled: value?.enabled !== false, lastAttempt: Number.isFinite(value?.lastAttempt) ? value.lastAttempt : null };
  } catch { return { enabled: true, lastAttempt: null }; }
}

/** 保存成功后再发布新偏好，存储失败时保留旧开关和检查时间。 */
function savePreferences(next) {
  localStorage.setItem(preferenceKey, JSON.stringify(next));
  state.preferences = next;
}

/** 原生环境从应用包读取版本；浏览器预览从构建时生成的清单读取版本。 */
async function loadEnvironment() {
  if (window.__TAURI__?.core?.invoke) {
    [state.version, state.platform] = await window.__TAURI__.core.invoke('update_environment');
  } else {
    const response = await fetch('./app-version.json');
    if (!response.ok) throw new Error('无法读取当前版本，请重新构建应用。');
    state.version = (await response.json()).version;
    state.platform = navigator.userAgent.includes('Windows') ? 'windows' : 'macos';
  }
}

/** 同步设置状态及新版提示；远端说明只作为纯文本显示。 */
function render() {
  document.getElementById('automatic-updates').checked = state.preferences.enabled;
  document.getElementById('check-updates').disabled = state.checking || state.installing;
  document.getElementById('app-version').textContent = `当前版本：${state.version ?? '读取中'}`;
  document.getElementById('update-status').textContent = [state.status, state.cleanupWarning].filter(Boolean).join('\n');
  document.getElementById('update-banner').hidden = !state.release;
  document.getElementById('update-download').hidden = !state.release;
  document.getElementById('update-manual').hidden = !state.release || !window.__TAURI__?.core?.invoke;
  document.getElementById('update-manual').disabled = state.installing;
  document.getElementById('update-notes').hidden = !state.release;
  document.getElementById('update-notes').textContent = state.release?.notes ?? '';
  document.getElementById('update-title').textContent = state.release ? `发现新版本 ${state.release.version}` : '';
  for (const id of ['update-download', 'banner-download']) {
    document.getElementById(id).disabled = state.installing;
    document.getElementById(id).textContent = window.__TAURI__?.core?.invoke ? '安装更新' : '前往下载';
  }
}

/** 自动失败只记录界面状态；手动检查可随时发起，但不能并发重复请求。 */
async function check(manual = false) {
  if (state.checking || state.installing) return;
  if (!manual && !shouldCheckAutomatically(state.preferences.enabled, state.preferences.lastAttempt)) return;
  state.checking = true;
  state.release = null;
  state.status = '正在检查更新…';
  render();
  try {
    if (!state.version) await loadEnvironment();
    if (!manual) {
      if (!state.preferences.enabled) return;
      savePreferences({ ...state.preferences, lastAttempt: Date.now() });
    }
    const result = await checkForUpdate({ currentVersion: state.version, platform: state.platform });
    state.release = result.release ?? null;
    const messages = { upToDate: '已是最新版。', unpublished: '暂无可用正式版本，请稍后重试。', unavailable: '新版尚未提供当前平台安装包。' };
    state.status = result.status === 'available' ? `发现新版本 ${result.release.version}` : messages[result.status];
  } catch (error) { state.status = error.message ?? '检查更新失败，请稍后重试。'; }
  finally { state.checking = false; render(); }
}

/** 用户主动点击后才通过系统浏览器前往已校验的本项目发布页。 */
async function openDownload() {
  if (!state.release) return;
  try {
    if (window.__TAURI__?.core?.invoke) await window.__TAURI__.core.invoke('open_release_page', { url: state.release.url });
    else window.open(state.release.url, '_blank', 'noopener,noreferrer');
  } catch { state.status = '无法打开下载页面，请重试。'; render(); }
}

/** 用户点击后由后端校验签名并原位安装；失败允许重试，收入和工资存储不参与安装。 */
async function installUpdate() {
  if (!state.release || state.installing) return;
  if (!window.__TAURI__?.core?.invoke) { await openDownload(); return; }
  state.installing = true;
  state.status = '正在下载并安装更新…';
  render();
  try {
    await window.__TAURI__.core.invoke('install_update');
    state.status = '更新已安装，正在重新启动…';
  } catch (error) {
    state.status = typeof error === 'string' ? error : '更新未完成，请重试或手动下载安装。';
  } finally { state.installing = false; render(); }
}

/** 只有正式应用能调用清理助手；新版 UI 已经加载后才执行，失败时保留可见提示。 */
async function prepareInstallation() {
  if (!window.__TAURI__?.core?.invoke) return;
  if (window.__TAURI__.event?.listen) await window.__TAURI__.event.listen('update-progress', (event) => {
    if (state.installing) { state.status = `正在下载更新 ${event.payload}%…`; render(); }
  });
  try { await window.__TAURI__.core.invoke('cleanup_old_versions'); }
  catch { state.cleanupWarning = '新版正常运行，旧版本清理未完成，请退出旧版后重试。'; render(); }
}

/** 安装独立事件与低频任务，开关立即生效且工资草稿无需保存。 */
export function initUpdates() {
  document.getElementById('automatic-updates').addEventListener('change', (event) => {
    try { savePreferences({ ...state.preferences, enabled: event.target.checked }); }
    catch { state.status = '更新检查偏好保存失败，请重试。'; }
    render();
    if (state.preferences.enabled) void check();
  });
  document.getElementById('check-updates').addEventListener('click', () => check(true));
  document.getElementById('update-download').addEventListener('click', installUpdate);
  document.getElementById('banner-download').addEventListener('click', installUpdate);
  document.getElementById('update-manual').addEventListener('click', openDownload);
  document.getElementById('banner-details').addEventListener('click', () => document.getElementById('open-settings').click());
  window.addEventListener('focus', () => check());
  setInterval(() => check(), 86400000);
  render();
  void loadEnvironment().then(async () => { render(); await prepareInstallation(); return check(); }).catch(() => { state.status = '无法读取当前版本，请重新构建应用。'; render(); });
}
