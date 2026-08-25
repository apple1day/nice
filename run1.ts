import { chromium, Page, BrowserContext } from '@playwright/test';
import * as path from 'path';
import * as fs from 'fs';

// 1. 设置目标文件夹路径与用户数据保存目录
const TARGET_DIR = '/Users/even/mine/anxiong/mockapi/v3_shopify_mock';
const SCREENSHOT_DIR = path.join(__dirname, 'screenshots');
// 持久化 Profile 存储路径（运行后会自动在项目目录下新建 .user_data 文件夹）
const USER_DATA_DIR = path.join(__dirname, '.user_data');

if (!fs.existsSync(SCREENSHOT_DIR)) {
  fs.mkdirSync(SCREENSHOT_DIR, { recursive: true });
}

// 辅助函数：安全读取文件夹下的代码文件
function getCodeFiles(dirPath: string): { name: string; content: string }[] {
  if (!fs.existsSync(dirPath)) {
    console.error(`❌ 找不到目标目录: ${dirPath}`);
    return [];
  }

  const files = fs.readdirSync(dirPath);
  const result: { name: string; content: string }[] = [];

  const ignorePatterns = [
    '__pycache__',
    'frontend',
    'node_modules',
    '.git',
    '.DS_Store',
    'package-lock.json',
    'fixtures.py.bak'
  ];

  for (const file of files) {
    if (ignorePatterns.includes(file) || file.endsWith('.png') || file.endsWith('.bak')) {
      continue;
    }

    const fullPath = path.join(dirPath, file);
    const stat = fs.statSync(fullPath);

    if (stat.isFile()) {
      try {
        const content = fs.readFileSync(fullPath, 'utf-8');
        result.push({ name: file, content });
      } catch (err) {
        console.warn(`⚠️ 无法读取文件 ${file}:`, err);
      }
    }
  }

  return result;
}

(async () => {
  console.log('============================================================');
  console.log('🚀 开始执行 ChatGPT 代码分析脚本（持久化模式）');
  console.log('============================================================');

  const codeFiles = getCodeFiles(TARGET_DIR);
  console.log(`📁 成功读取 ${codeFiles.length} 个代码文件`);

  if (codeFiles.length === 0) {
    console.log('❌ 没有找到可分析的代码文件，流程终止');
    return;
  }

  // 2. 关键：使用 launchPersistentContext 替代 chromium.launch()
  // 这会把 Cookies、LocalStorage、登录 Session 存到 USER_DATA_DIR 中
  console.log('🌐 正在启动带有 Cookie / Session 记忆功能的浏览器...');
  const context: BrowserContext = await chromium.launchPersistentContext(USER_DATA_DIR, {
    headless: false,
    channel: 'chrome', // 如果本地装了 Chrome，复用系统 Chrome 可以进一步减少被当作机器人的概率
    viewport: null,
    args: ['--start-maximized', '--disable-blink-features=AutomationControlled']
  });

  await context.addInitScript(() => {
    Object.defineProperty(navigator, 'webdriver', { get: () => undefined });
  });

  const page: Page = context.pages().length > 0 ? context.pages()[0] : await context.newPage();
  page.setDefaultTimeout(60000);

  try {
    console.log('🌐 正在打开 ChatGPT (https://chatgpt.com/)...');
    await page.goto('https://chatgpt.com/', { waitUntil: 'domcontentloaded' });

    // 3. 增强：定位输入框（ChatGPT 有时会更换 class，这里使用多选择器兼容模式）
    console.log('⏳ 正在检查登录状态和输入框...');
    const promptInput = page.locator('#prompt-textarea, [contenteditable="true"]').first();

    try {
      // 尝试等待输入框 10 秒
      await promptInput.waitFor({ state: 'visible', timeout: 10000 });
      console.log('✅ 已直接进入登录状态！');
    } catch {
      // 如果 10 秒内没找到输入框，说明还没登录，给予充足的时间让你在浏览器界面上手动完成登录
      console.log('\n============================================================');
      console.log('⚠️ 检测到尚未登录或被 Cloudflare 拦截。');
      console.log('👉 请在弹出的浏览器窗口中完成登录/验证操作！');
      console.log('👉 脚本正在等待输入框出现（最长等待 3 分钟）...');
      console.log('============================================================\n');

      await promptInput.waitFor({ state: 'visible', timeout: 180000 });
      console.log('✅ 登录完成，已检测到 ChatGPT 输入框！');
    }

    // 4. 发送初始指令
    const initPrompt = '你好，我接下来会依次发给你一系列 Python/SQL 项目代码文件，请帮我分析代码架构和主要功能。收到请回复“准备就绪”。';
    console.log('🤖 发送初始化指令...');
    await promptInput.fill(initPrompt);
    await page.keyboard.press('Enter');

    await page.waitForTimeout(5000);

    // 5. 依次输入代码文件并截图
    for (let i = 0; i < codeFiles.length; i++) {
      const { name, content } = codeFiles[i];
      console.log(`\n------------------------------------------------------------`);
      console.log(`[${i + 1}/${codeFiles.length}] 正在发送文件: ${name}`);

      const promptText = `【文件名: ${name}】\n请分析以下代码：\n\n\`\`\`python\n${content}\n\`\`\``;

      await promptInput.waitFor({ state: 'visible' });
      await promptInput.fill(promptText);
      await page.waitForTimeout(500);

      await page.keyboard.press('Enter');
      console.log(`📤 ${name} 已发送，等待 ChatGPT 生成分析结果...`);

      // 给生成回答预留时间（可根据需要微调）
      await page.waitForTimeout(15000);

      const sanitizeName = name.replace(/[^a-zA-Z0-9_-]/g, '_');
      const screenshotPath = path.join(SCREENSHOT_DIR, `${i + 1}_${sanitizeName}_analysis.png`);
      
      await page.screenshot({ path: screenshotPath, fullPage: false });
      console.log(`📸 已保存分析截图: ${screenshotPath}`);
    }

    console.log('\n============================================================');
    console.log('✅ 所有文件发送与分析截图完成！');
    console.log('============================================================');

  } catch (error) {
    console.error('❌ 运行过程中发生错误:', error);
  } finally {
    console.log('按任意键或者等待 10 秒后自动关闭浏览器...');
    await page.waitForTimeout(10000);
    await context.close();
  }
})();