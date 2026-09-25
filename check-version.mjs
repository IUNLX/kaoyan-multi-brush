#!/usr/bin/env node
/**
 * 版本一致性校验脚本 —— 《版本更新规范.md》第四步 ⑤
 *
 * 用法：node check-version.mjs
 * 退出码：0 = 全部一致；1 = 存在不一致（不得提交）
 *
 * 校验内容：
 *   1. HTML 内联脚本语法正确
 *   2. APP_VERSION 为完整三段式语义化版本号
 *   3. VERSION_HISTORY 首条与 APP_VERSION 一致
 *   4. VERSION_HISTORY 日期格式合法、版本严格递减、无重复
 *   5. CHANGELOG.md 最新版本区段与 APP_VERSION 一致，且保留 [未发布] 区段
 *   6. README.md 的当前版本与 APP_VERSION 一致
 *   7. 版本号没有在其它位置被硬编码（页面标题、版本标签）
 */

import fs from 'node:fs';
import vm from 'node:vm';
import path from 'node:path';

const HTML = '考研真题多刷记录.html';
const CHANGELOG = 'CHANGELOG.md';
const README = 'README.md';
const LINK = '考研真题多刷记录.html - 快捷方式.lnk';

const results = [];
const ok = (label, detail = '') => results.push({ level: 'ok', label, detail });
const fail = (label, detail = '') => results.push({ level: 'fail', label, detail });
const warn = (label, detail = '') => results.push({ level: 'warn', label, detail });

function readIfExists(file) {
  try {
    return fs.readFileSync(path.resolve(file), 'utf8');
  } catch {
    return null;
  }
}

const SEMVER = /^(\d+)\.(\d+)\.(\d+)$/;
const parseSemver = (v) => {
  const m = SEMVER.exec(v);
  return m ? [Number(m[1]), Number(m[2]), Number(m[3])] : null;
};
/** a 是否严格大于 b */
function semverGt(a, b) {
  for (let i = 0; i < 3; i++) {
    if (a[i] !== b[i]) return a[i] > b[i];
  }
  return false;
}

// ---------- 读取主文件 ----------
const html = readIfExists(HTML);
if (!html) {
  console.error(`❌ 找不到主文件 ${HTML}，请在项目根目录执行本脚本。`);
  process.exit(1);
}

// ---------- 1. 语法检查 ----------
const scriptMatch = html.match(/<script>([\s\S]*?)<\/script>/);
let script = '';
if (!scriptMatch) {
  fail('内联脚本语法', '未找到 <script> 块');
} else {
  script = scriptMatch[1];
  try {
    new vm.Script(script, { filename: 'inline.js' });
    ok('内联脚本语法', '解析通过');
  } catch (e) {
    fail('内联脚本语法', e.message);
  }
}

// ---------- 2. APP_VERSION ----------
const appVerMatch = script.match(/var\s+APP_VERSION\s*=\s*'([^']*)'/);
let appVersion = null;
if (!appVerMatch) {
  fail('APP_VERSION 定义', "未找到 var APP_VERSION='...'");
} else {
  appVersion = appVerMatch[1];
  if (SEMVER.test(appVersion)) {
    ok('APP_VERSION 格式', `v${appVersion}（三段式）`);
  } else {
    fail('APP_VERSION 格式', `「${appVersion}」不是完整的 主.次.修订 三段式，例如应为 1.1.0`);
  }
}

// ---------- 3 & 4. VERSION_HISTORY ----------
const histMatch = script.match(/var\s+VERSION_HISTORY\s*=\s*\[([\s\S]*?)\n\s*\];/);
let history = [];
if (!histMatch) {
  fail('VERSION_HISTORY 定义', '未找到 var VERSION_HISTORY=[...]');
} else {
  history = [...histMatch[1].matchAll(/version\s*:\s*'([^']*)'\s*,\s*date\s*:\s*'([^']*)'/g)].map((m) => ({
    version: m[1],
    date: m[2],
  }));

  if (!history.length) {
    fail('VERSION_HISTORY 内容', '没有解析到任何版本条目');
  } else {
    // 首条必须等于 APP_VERSION
    if (appVersion && history[0].version === appVersion) {
      ok('版本历史首条', `v${history[0].version}（与 APP_VERSION 一致）`);
    } else {
      fail(
        '版本历史首条',
        `VERSION_HISTORY 首条为 v${history[0].version}，但 APP_VERSION 为 v${appVersion}；新版本必须插到数组开头`,
      );
    }

    // 日期格式
    const badDates = history.filter((h) => !/^\d{4}-\d{2}-\d{2}$/.test(h.date));
    if (badDates.length) {
      fail('版本历史日期格式', `${badDates.map((h) => `v${h.version}→${h.date}`).join('、')} 不是 YYYY-MM-DD`);
    } else {
      ok('版本历史日期格式', `${history.length} 条均为 YYYY-MM-DD`);
    }

    // 版本号合法性 + 严格递减 + 无重复
    const parsed = history.map((h) => ({ ...h, sv: parseSemver(h.version) }));
    const invalid = parsed.filter((h) => !h.sv);
    if (invalid.length) {
      fail('版本历史版本号格式', `${invalid.map((h) => h.version).join('、')} 不是三段式`);
    }

    const seen = new Set();
    const dup = parsed.filter((h) => (seen.has(h.version) ? true : (seen.add(h.version), false)));
    if (dup.length) fail('版本历史重复', dup.map((h) => `v${h.version}`).join('、'));
    else ok('版本历史无重复', `${history.length} 条版本号唯一`);

    if (invalid.length === 0) {
      let outOfOrder = null;
      for (let i = 0; i + 1 < parsed.length; i++) {
        if (!semverGt(parsed[i].sv, parsed[i + 1].sv)) {
          outOfOrder = `v${parsed[i].version} 未高于其后的 v${parsed[i + 1].version}`;
          break;
        }
      }
      if (outOfOrder) fail('版本历史顺序', `${outOfOrder}（数组必须从新到旧排列）`);
      else ok('版本历史顺序', '从新到旧严格递减');
    }
  }
}

// ---------- 5. CHANGELOG ----------
const changelog = readIfExists(CHANGELOG);
if (!changelog) {
  fail('CHANGELOG.md', '文件不存在');
} else {
  if (/^##\s*\[未发布\]/m.test(changelog)) {
    ok('CHANGELOG [未发布]', '区段存在');
  } else {
    fail('CHANGELOG [未发布]', '缺少 ## [未发布] 区段，请保留该区段用于收集下次改动');
  }

  const released = [...changelog.matchAll(/^##\s*\[(\d+\.\d+\.\d+)\]\s*-\s*(\d{4}-\d{2}-\d{2})/gm)].map((m) => ({
    version: m[1],
    date: m[2],
  }));

  if (!released.length) {
    fail('CHANGELOG 版本区段', '没有找到任何 ## [x.y.z] - YYYY-MM-DD 区段');
  } else if (appVersion && released[0].version !== appVersion) {
    fail(
      'CHANGELOG 最新版本',
      `CHANGELOG 最新为 v${released[0].version}，但 APP_VERSION 为 v${appVersion}；请把 [未发布] 下移为新版本区段`,
    );
  } else {
    ok('CHANGELOG 最新版本', `v${released[0].version} - ${released[0].date}`);
  }
}

// ---------- 6. README ----------
const readme = readIfExists(README);
if (!readme) {
  fail('README.md', '文件不存在');
} else {
  const m = readme.match(/当前版本\s*\*\*v?([\d.]+)\*\*\s*[（(](\d{4}-\d{2}-\d{2})[）)]/);
  if (!m) {
    fail('README 当前版本', '未找到「当前版本 **vX.Y.Z**（YYYY-MM-DD）」格式的版本行');
  } else if (appVersion && m[1] !== appVersion) {
    fail('README 当前版本', `README 为 v${m[1]}，但 APP_VERSION 为 v${appVersion}`);
  } else {
    ok('README 当前版本', `v${m[1]}（${m[2]}）`);
  }
}

// ---------- 7. 版本号不得在别处硬编码 ----------
const titleMatch = html.match(/<title>([\s\S]*?)<\/title>/);
if (titleMatch && /v?\d+\.\d+\.\d+/.test(titleMatch[1])) {
  fail('页面标题硬编码版本', `<title> 中出现版本号：${titleMatch[1].trim()}`);
} else {
  ok('页面标题', '未硬编码版本号（由 renderAppVersion() 渲染）');
}

const tagMatch = html.match(/<span class="version" id="appVersionTag">([\s\S]*?)<\/span>/);
if (!tagMatch) {
  fail('首页版本标签', '未找到 <span class="version" id="appVersionTag">');
} else if (/v?\d+\.\d+\.\d+/.test(tagMatch[1])) {
  fail('首页版本标签硬编码', `标签内写死了「${tagMatch[1].trim()}」，应留给 JS 渲染`);
} else {
  ok('首页版本标签', '占位正确，由 JS 渲染');
}

if (!/function\s+renderAppVersion\s*\(/.test(script)) {
  fail('renderAppVersion()', '未找到该函数，版本号无法渲染到界面');
} else {
  ok('renderAppVersion()', '存在');
}

// ---------- 8. 版本功能所需元素齐全 ----------
const requiredIds = [
  ['appVersionTag', '首页版本标签'],
  ['appVersionCard', '版本卡片当前版本'],
  ['btnVersionInfo', '查看版本历史按钮'],
  ['btnExportVersion', '导出版本记录按钮'],
];
const htmlOnly = html.replace(/<script>[\s\S]*?<\/script>/, '');
const presentIds = new Set([...htmlOnly.matchAll(/\bid=["']([^"']+)["']/g)].map((m) => m[1]));
const missingIds = requiredIds.filter(([id]) => !presentIds.has(id));
if (missingIds.length) {
  fail('版本功能元素', `页面缺少 ${missingIds.map(([id, name]) => `#${id}（${name}）`).join('、')}`);
} else {
  ok('版本功能元素', `${requiredIds.length} 个元素齐全`);
}

// ---------- 附加提醒（不算失败） ----------
if (fs.existsSync(path.resolve(LINK))) {
  warn('本机快捷方式', `${LINK} 存在于工作目录，提交时请勿勾选（建议加入 .gitignore）`);
}

// ---------- 输出 ----------
const icon = { ok: '✅', fail: '❌', warn: '⚠️ ' };
console.log('\n版本一致性校验（规范见《版本更新规范.md》）\n' + '─'.repeat(52));
for (const r of results) {
  console.log(`${icon[r.level]} ${r.label}${r.detail ? '：' + r.detail : ''}`);
}
console.log('─'.repeat(52));

const failed = results.filter((r) => r.level === 'fail');
if (failed.length) {
  console.log(`\n❌ 校验未通过：${failed.length} 项不一致，请修正后再提交。\n`);
  process.exit(1);
}
console.log(`\n✅ 全部一致：当前版本 v${appVersion}，可以提交。\n`);
