import { chromium, Page, BrowserContext } from '@playwright/test';
import * as path from 'path';
import * as fs from 'fs';

// 确保截图目录存在
const screenshotDir = path.join(__dirname, 'screenshots');
if (!fs.existsSync(screenshotDir)) {
  fs.mkdirSync(screenshotDir, { recursive: true });
}

const DEMO_URL = 'https://www.baidu.com';
const SEARCH_KEYWORD = 'Playwright TypeScript 自动化';

(async () => {
  console.log('============================================================');
  console.log('🚀 Playwright TypeScript 自动化演示开始');
  console.log('============================================================');

  // 1. 启动浏览器（默认使用有头模式，方便观察）
  // 注意：如果想使用本地已安装的系统 Chrome，可在 launch 中添加 `channel: 'chrome'`
  const browser = await chromium.launch({
    headless: false,
    slowMo: 300, // 每次操作延迟 300ms，方便肉眼观察
    args: ['--start-maximized', '--disable-blink-features=AutomationControlled']
  });

  // 2. 创建上下文并注入抹除自动化特征的脚本
  const context: BrowserContext = await browser.newContext({
    viewport: null // 配合 --start-maximized 实现窗口最大化
  });

  await context.addInitScript(() => {
    Object.defineProperty(navigator, 'webdriver', { get: () => undefined });
  });

  const page: Page = await context.newPage();
  page.setDefaultTimeout(30000);

  try {
    // ---- 步骤 1: 打开百度首页 ----
    console.log(`[步骤 1/5] 打开 ${DEMO_URL} ...`);
    await page.goto(DEMO_URL, { waitUntil: 'domcontentloaded' });
    
    const pageTitle = await page.title();
    console.log(`         ✅ 页面标题: ${pageTitle}`);
    
    const step1Path = path.join(screenshotDir, 'step1_baidu_home.png');
    await page.screenshot({ path: step1Path });
    console.log(`         📸 截图已保存: ${step1Path}`);

    // ---- 步骤 2: 输入搜索词并搜索 ----
    console.log(`[步骤 2/5] 搜索关键词: ${SEARCH_KEYWORD} ...`);
    const searchInput = page.locator('#kw');
    await searchInput.fill(SEARCH_KEYWORD, { force: true });
    await page.waitForTimeout(300);
    await searchInput.press('Enter');

    // ---- 步骤 3: 等待搜索结果 ----
    console.log('[步骤 3/5] 等待搜索结果加载...');
    const resultContainer = page.locator('#content_left');
    await resultContainer.waitFor({ state: 'attached', timeout: 20000 });

    const step2Path = path.join(screenshotDir, 'step2_search_results.png');
    await page.screenshot({ path: step2Path });
    console.log(`         📸 截图已保存: ${step2Path}`);

    // ---- 步骤 4: 提取前 5 条结果标题 ----
    console.log('[步骤 4/5] 提取前 5 条搜索结果标题...');
    const results = page.locator('#content_left .result.c-container');
    const count = await results.count();
    console.log(`         共找到 ${count} 条搜索结果`);

    const titles: string[] = [];
    for (let i = 0; i < Math.min(count, 5); i++) {
      try {
        const titleEl = results.nth(i).locator('h3').first();
        const text = (await titleEl.innerText({ timeout: 1500 })).trim();
        if (text) {
          titles.push(text);
          console.log(`           ${i + 1}. ${text.slice(0, 50)}${text.length > 50 ? '...' : ''}`);
        }
      } catch (e) {
        // 忽略单项获取失败
      }
    }

    // ---- 步骤 5: 点击第一条结果 ----
    if (titles.length > 0) {
      console.log('[步骤 5/5] 点击第一条搜索结果进入新标签页...');
      const firstLink = results.nth(0).locator('h3 a').first();

      // 监听新窗口打开事件
      const [newPage] = await Promise.all([
        context.waitForEvent('page', { timeout: 8000 }).catch(() => null),
        firstLink.click({ force: true })
      ]);

      const targetPage = newPage || page;
      await targetPage.waitForLoadState('domcontentloaded').catch(() => {});

      const detailTitle = await targetPage.title().catch(() => '(获取失败)');
      console.log(`         ✅ 详情页标题: ${detailTitle}`);
      console.log(`         ✅ 详情页 URL: ${targetPage.url()}`);

      const step3Path = path.join(screenshotDir, 'step3_detail_page.png');
      await targetPage.screenshot({ path: step3Path });
      console.log(`         📸 截图已保存: ${step3Path}`);
    }

    console.log('============================================================');
    console.log('✅ 所有流程执行完毕！');
    console.log('============================================================');

  } catch (error) {
    console.error('❌ 执行失败:', error);
  } finally {
    // 稍等 2 秒后关闭浏览器，方便观察结果
    await page.waitForTimeout(2000);
    await browser.close();
    console.log('👋 浏览器已关闭。');
  }
})();