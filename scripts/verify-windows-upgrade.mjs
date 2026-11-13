import { execFileSync } from 'node:child_process';
import { mkdtemp, readdir, symlink, writeFile, rm, unlink } from 'node:fs/promises';
import { resolve, join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { readFile } from 'node:fs/promises';

/** 安装验收只允许 GitHub 托管的临时 Windows runner，绝不在开发者电脑自动安装或卸载。 */
const isolatedRunner = process.platform === 'win32' && process.env.GITHUB_ACTIONS === 'true' && process.env.RUNNER_ENVIRONMENT === 'github-hosted';
if (isolatedRunner) {
  const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
  /** 当前构建的正式版本，供升级验收匹配安装器和注册表版本。 */
  const currentVersion = JSON.parse(await readFile(join(root, 'package.json'), 'utf8')).version;
  const workspace = await mkdtemp(join(process.env.RUNNER_TEMP, 'niuma-upgrade-'));
  const baseline = join(workspace, 'baseline');
  const target = resolve(root, 'src-tauri/target');
  const bundles = join(target, 'release/bundle/nsis');
  const current = (await readdir(bundles)).find((name) => name.endsWith('.exe') && name.includes(currentVersion));
  if (!current) throw new Error('当前正式安装包不存在。');
  try {
    execFileSync('git', ['fetch', '--depth', '1', 'origin', 'refs/tags/v0.2.1:refs/tags/v0.2.1'], { cwd: root, stdio: 'inherit' });
    execFileSync('git', ['worktree', 'add', '--detach', baseline, 'v0.2.1'], { cwd: root, stdio: 'inherit' });
    await symlink(resolve(root, 'node_modules'), join(baseline, 'node_modules'), 'junction');
    execFileSync('cmd.exe', ['/d', '/s', '/c', 'npm run tauri:build'], { cwd: baseline, stdio: 'inherit', env: { ...process.env, CARGO_TARGET_DIR: target } });
    const previous = (await readdir(bundles)).find((name) => name.endsWith('.exe') && name.includes('0.2.1'));
    if (!previous) throw new Error('未构建出真实 0.2.1 基线安装包。');
    const script = join(workspace, 'verify.ps1');
    // UTF-8 BOM 确保 Windows PowerShell 5 能正确读取中文产品名。
    await writeFile(script, '\ufeff' + String.raw`param([string]$OldInstaller, [string]$NewInstaller, [string]$InstallPath)
$ErrorActionPreference = 'Stop'
function ProductEntries {
    @(Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -eq '牛马上班' })
}
function InstalledBinary {
    @(Get-ChildItem $InstallPath -Filter '*.exe' | Where-Object { $_.Name -notmatch 'uninstall' -and $_.VersionInfo.ProductVersion })[0]
}
function InstallPackage([string]$File, [string[]]$Arguments) {
    $process = Start-Process -FilePath $File -ArgumentList $Arguments -Wait -PassThru
    if ($process.ExitCode -ne 0) { throw "Installer failed: $($process.ExitCode)" }
}
if ((ProductEntries).Count -ne 0 -or (Test-Path $InstallPath)) { throw 'Runner already contains this application; refusing to change it.' }
$data = Join-Path $env:LOCALAPPDATA 'com.hcxgrassstar.niuma'
if (Test-Path $data) { throw 'Runner already contains application data; refusing to change it.' }
$sentinel = Join-Path $data 'niuma-upgrade-test.txt'
try {
    InstallPackage $OldInstaller @('/S', "/D=$InstallPath")
    $before = InstalledBinary
    if (!$before -or !$before.VersionInfo.ProductVersion.StartsWith('0.2.1')) { throw 'Baseline executable is not 0.2.1.' }
    New-Item -ItemType Directory -Path $data -Force | Out-Null
    [IO.File]::WriteAllText($sentinel, 'salary-and-schedule-must-stay')
    # 新安装器不传自定义目录，验证能沿用注册表中的旧位置。
    InstallPackage $NewInstaller @('/S')
    $after = InstalledBinary
    if (!$after -or !$after.VersionInfo.ProductVersion.StartsWith('${currentVersion}')) { throw 'New installer did not replace the old executable in place.' }
    $entries = @(ProductEntries)
    if ($entries.Count -ne 1 -or !$entries[0].DisplayVersion.StartsWith('${currentVersion}')) { throw 'Upgrade left duplicate uninstall entries or an old version.' }
    if ([IO.File]::ReadAllText($sentinel) -ne 'salary-and-schedule-must-stay') { throw 'Upgrade changed persisted application data.' }
    Write-Host 'PASS: Windows NSIS 0.2.1 -> ${currentVersion}; same installation path, single uninstall entry, old executable replaced, application data retained.'
} finally {
    $entry = @(ProductEntries) | Select-Object -First 1
    if ($entry -and $entry.UninstallString) {
        $uninstaller = $entry.UninstallString.Trim('"')
        if (Test-Path $uninstaller) { Start-Process -FilePath $uninstaller -ArgumentList '/S' -Wait | Out-Null }
    }
    if (Test-Path $sentinel) { Remove-Item $sentinel -Force }
    if ((Test-Path $data) -and !(Get-ChildItem $data -Force)) { Remove-Item $data -Force }
}
`, 'utf8');
    execFileSync('powershell.exe', ['-NoProfile', '-NonInteractive', '-File', script, join(bundles, previous), join(bundles, current), join(workspace, 'installed')], { stdio: 'inherit' });
  } finally {
    await unlink(join(baseline, 'node_modules')).catch(() => {});
    try { execFileSync('git', ['worktree', 'remove', '--force', baseline], { cwd: root, stdio: 'ignore' }); } catch { /* 尚未创建时无需移除。 */ }
    for (const folder of ['nsis', 'msi']) {
      const output = join(target, 'release/bundle', folder);
      for (const name of await readdir(output).catch(() => [])) if (name.includes('0.2.1')) await rm(join(output, name), { force: true });
    }
    await rm(workspace, { recursive: true, force: true });
  }
}
