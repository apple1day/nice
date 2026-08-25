import { chromium, Page, BrowserContext } from '@playwright/test';
import * as path from 'path';
import * as fs from 'fs';

// 1. 设置目标文件夹路径
const TARGET_DIR = '/Users/even/mine/anxiong/mockapi/v3_shopify_mock';
const SCREENSHOT_DIR = path.join(__dirname, 'screenshots');

if (!fs.existsSync(SCREENSHOT_DIR)) {
  fs.mkdirSync(SCREENSHOT_DIR, { recursive: true });
}

// 辅助函数：安全读取文件夹下的代码文件（排除文件夹和二进制/备份文件）
function getCodeFiles(dirPath: string): { name: string; content: string }[] {
  if (!fs.existsSync(dirPath)) {
    console.error(`❌ 找不到目标目录: ${dirPath}`);
    return [];
  }

  const files = fs.readdirSync(dirPath);
  const result: { name: string; content: string }[] = [];

  // 需要忽略的文件夹或文件名模式
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

    // 只读取文本文件，跳过目录
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
  console.log('🚀 开始执行 ChatGPT 代码分析脚本');
  console.log('============================================================');

  // 1. 读取文件列表
  const codeFiles = getCodeFiles(TARGET_DIR);
  console.log(`📁 成功读取 ${codeFiles.length} 个代码文件`);

  if (codeFiles.length === 0) {
    console.log('❌ 没有找到可分析的代码文件，流程终止');
    return;
  }

  // 2. 启动浏览器
  const browser = await chromium.launch({
    headless: false, // 弹出界面方便观察/登录
    slowMo: 300,
    args: ['--start-maximized', '--disable-blink-features=AutomationControlled']
  });

  const context: BrowserContext = await browser.newContext({
    viewport: null
  });

  await context.addInitScript(() => {
    Object.defineProperty(navigator, 'webdriver', { get: () => undefined });
  });

  const page: Page = await context.newPage();
  page.setDefaultTimeout(60000); // 设置较长的超时（GPT 生成回答需要时间）

  try {
    // 3. 打开 ChatGPT
    console.log('🌐 正在打开 ChatGPT (https://chatgpt.com/)...');
    await page.goto('https://chatgpt.com/', { waitUntil: 'domcontentloaded' });

    console.log('⏳ 提示：如果弹出了 Cloudflare 验证或需要登录，请在打开的浏览器窗口中手动操作...');
    
    // 定位输入框：ChatGPT 使用的是 id 为 prompt-textarea 的 div 或 textarea
    const promptInput = page.locator('#prompt-textarea');
    await promptInput.waitFor({ state: 'visible', timeout: 60000 });
    console.log('✅ 成功检测到 ChatGPT 输入框');

    // 4. 发送初始指令
    const initPrompt = '你好，我接下来会依次发给你一系列 Python/SQL 项目代码文件，请帮我分析代码架构和主要功能。收到请回复“准备就绪”。';
    console.log('🤖 发送初始化指令...');
    await promptInput.fill(initPrompt);
    await page.keyboard.press('Enter');

    // 等待 GPT 回复（等待“发送/停止生成”按钮重置或回复元素出现）
    await page.waitForTimeout(5000);

    // 5. 依次输入代码文件并截图
    for (let i = 0; i < codeFiles.length; i++) {
      const { name, content } = codeFiles[i];
      console.log(`\n------------------------------------------------------------`);
      console.log(`[${i + 1}/${codeFiles.length}] 正在发送文件: ${name}`);

      // 构建 Prompt 格式
      const promptText = `【文件名: ${name}】\n请分析以下代码：\n\n\`\`\`python\n${content}\n\`\`\``;

      // 确保输入框可用
      await promptInput.waitFor({ state: 'visible' });
      
      // 使用 fill 将内容塞入输入框
      await promptInput.fill(promptText);
      await page.waitForTimeout(500);

      // 按 Enter 发送
      await page.keyboard.press('Enter');
      console.log(`📤 ${name} 已发送，等待 ChatGPT 生成分析结果...`);

      // 简单等待生成（根据代码长度可调整，这里设定等待 15 秒）
      await page.waitForTimeout(15000);

      // 截图保存结果
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
    await browser.close();
  }
})();