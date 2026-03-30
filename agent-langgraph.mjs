#!/usr/bin/env node
/**
 * mobile-use agent — LangGraph.js version
 * Same tools and capabilities as agent.mjs, orchestrated with LangGraph.
 *
 * Usage:
 *   node agent-langgraph.mjs "search for USC on maps" --phone --provider openai
 */
import 'dotenv/config';
import { exec, spawn } from 'child_process';
import { readFileSync, writeFileSync, unlinkSync, mkdirSync, readdirSync, existsSync } from 'fs';
import { tmpdir, homedir } from 'os';
import { join } from 'path';
import { z } from 'zod';
import { ChatOpenAI } from '@langchain/openai';
import { ChatGoogleGenerativeAI } from '@langchain/google-genai';
import { tool } from '@langchain/core/tools';
import { createReactAgent } from '@langchain/langgraph/prebuilt';
import { HumanMessage, SystemMessage } from '@langchain/core/messages';

// ─── Parse args ───
const args = process.argv.slice(2);
const flagArgs = new Set();
args.forEach((a, i) => { if (a.startsWith('--') && args[i + 1] && !args[i + 1].startsWith('--')) flagArgs.add(i + 1); });
const task = args.filter((a, i) => !a.startsWith('--') && !flagArgs.has(i)).join(' ');
const maxSteps = parseInt(args.find((_, i) => args[i - 1] === '--max-steps') || '25');
const provider = args.find((_, i) => args[i - 1] === '--provider') || 'gemini';
const defaultModel = provider === 'openai' ? 'gpt-5.4' : 'gemini-2.5-flash-lite';
const modelName = args.find((_, i) => args[i - 1] === '--model') || defaultModel;
const isPhone = args.includes('--phone');
const phoneDeviceId = args.find((_, i) => args[i - 1] === '--device-id') || '00008130-0008249124C1401C';
const driverPort = parseInt(args.find((_, i) => args[i - 1] === '--driver-port') || '6001');

if (!task) {
  console.log('Usage: node agent-langgraph.mjs "your task" [--phone] [--provider openai|gemini]');
  process.exit(1);
}

// ─── Provider setup ───
const LLM_CONFIG = {
  openai: { keyEnv: 'OPENAI_API_KEY' },
  gemini: { keyEnv: 'GEMINI_API_KEY' },
};
const llmConfig = LLM_CONFIG[provider];
if (!llmConfig) { console.log(`ERROR: Unknown provider "${provider}"`); process.exit(1); }
const apiKey = process.env[llmConfig.keyEnv];
if (!apiKey) { console.log(`ERROR: Set ${llmConfig.keyEnv}`); process.exit(1); }

// ─── Helpers ───
const sleep = (ms) => new Promise(r => setTimeout(r, ms));
function runShell(cmd, timeout = 30000) {
  return new Promise((resolve, reject) => {
    exec(cmd, { timeout }, (error, stdout) => {
      if (error) reject(new Error(error.message.slice(0, 200)));
      else resolve(stdout);
    });
  });
}

// ─── Device setup (same as agent.mjs) ───
console.log(`[Setup] Mode: ${isPhone ? 'Physical iPhone' : 'Simulator'} | Provider: ${provider} | Model: ${modelName}`);

// App map
const appMap = {};
const knownBundleIds = {
  Safari: 'com.apple.mobilesafari', Maps: 'com.apple.Maps', Messages: 'com.apple.MobileSMS',
  Calendar: 'com.apple.mobilecal', Photos: 'com.apple.mobileslideshow', Camera: 'com.apple.camera',
  Settings: 'com.apple.Preferences', Notes: 'com.apple.mobilenotes', Reminders: 'com.apple.reminders',
  Contacts: 'com.apple.MobileAddressBook', Phone: 'com.apple.mobilephone', Mail: 'com.apple.mobilemail',
  Weather: 'com.apple.weather', Clock: 'com.apple.mobiletimer', Files: 'com.apple.DocumentsApp',
  Spotify: 'com.spotify.client', Instagram: 'com.burbn.instagram', Snapchat: 'com.toyopagroup.picaboo',
  YouTube: 'com.google.ios.youtube', Gmail: 'com.google.Gmail', ChatGPT: 'com.openai.chat',
  LinkedIn: 'com.linkedin.LinkedIn', GitHub: 'com.github.stormbreaker.prod',
};

if (isPhone) {
  Object.assign(appMap, knownBundleIds);
} else {
  try {
    const raw = await runShell('xcrun simctl listapps booted');
    let name = '';
    for (const line of raw.split('\n')) {
      const nm = line.match(/CFBundleDisplayName\s*=\s*"?([^";]+)"?/);
      const id = line.match(/CFBundleIdentifier\s*=\s*"?([^";]+)"?/);
      if (nm) name = nm[1].trim();
      if (id && name) { appMap[name] = id[1].trim(); name = ''; }
    }
  } catch {}
}
console.log(`[Setup] Found ${Object.keys(appMap).length} apps`);

// Device connection (simplified from agent.mjs)
let currentAppId = null;
let phoneScreenWidth = 393;
let phoneScreenHeight = 852;

async function xctest(method, path, body = null) {
  const opts = { method, signal: AbortSignal.timeout(30000) };
  if (body !== null) { opts.headers = { 'Content-Type': 'application/json' }; opts.body = JSON.stringify(body); }
  const resp = await fetch(`http://localhost:${driverPort}${path}`, opts);
  return resp;
}

if (isPhone) {
  console.log('[Setup] Phone mode — testing XCTest runner...');
  try {
    const resp = await fetch(`http://localhost:${driverPort}/deviceInfo`, { signal: AbortSignal.timeout(3000) });
    if (resp.ok) {
      const info = await resp.json();
      phoneScreenWidth = info.widthPoints;
      phoneScreenHeight = info.heightPoints;
      console.log(`[Setup] XCTest OK | Screen: ${phoneScreenWidth}x${phoneScreenHeight}`);
    }
  } catch {
    console.log('[Setup] XCTest not responding. Warming up...');
    try {
      const fp = join(tmpdir(), `warm-${Date.now()}.yaml`);
      writeFileSync(fp, 'appId: any\n---\n- pressKey: space');
      await runShell(`maestro --driver-host-port ${driverPort} --device ${phoneDeviceId} test ${fp}`, 60000);
      try { unlinkSync(fp); } catch {}
      const resp = await fetch(`http://localhost:${driverPort}/deviceInfo`, { signal: AbortSignal.timeout(5000) });
      const info = await resp.json();
      phoneScreenWidth = info.widthPoints;
      phoneScreenHeight = info.heightPoints;
      console.log(`[Setup] XCTest warmed up | Screen: ${phoneScreenWidth}x${phoneScreenHeight}`);
    } catch (e) { console.log(`[Setup] WARNING: ${e.message}`); }
  }
}

// ─── Define LangGraph Tools ───
const openAppTool = tool(
  async ({ appName }) => {
    const bid = appMap[appName];
    if (!bid) return `App "${appName}" not found. Available: ${Object.keys(appMap).join(', ')}`;
    if (isPhone) {
      await xctest('POST', '/launchApp', { bundleId: bid });
    } else {
      await runShell(`xcrun simctl launch booted ${bid}`);
    }
    currentAppId = bid;
    return `Opened ${appName}`;
  },
  { name: 'openApp', description: `Open an app. Available: ${Object.keys(appMap).join(', ')}`, schema: z.object({ appName: z.string() }) }
);

const tapTool = tool(
  async ({ x, y, description }) => {
    if (x > 100 || y > 100) return `ERROR: Use percentages 0-100, not pixels. You sent ${x},${y}.`;
    if (isPhone) {
      const px = Math.round((x / 100) * phoneScreenWidth);
      const py = Math.round((y / 100) * phoneScreenHeight);
      await xctest('POST', '/touch', { x: px, y: py, duration: 0.1 });
    } else {
      const header = currentAppId ? `appId: ${currentAppId}\n---\n` : 'appId: any\n---\n';
      const fp = join(tmpdir(), `tap-${Date.now()}.yaml`);
      writeFileSync(fp, `${header}- tapOn:\n    point: "${x}%, ${y}%"`);
      await runShell(`maestro test ${fp}`, 30000);
      try { unlinkSync(fp); } catch {}
    }
    return `Tapped (${x}%, ${y}%)${description ? ' - ' + description : ''}`;
  },
  { name: 'tap', description: 'Tap at screen coordinates (percentages 0-100). x=0 left, x=100 right, y=0 top, y=100 bottom.', schema: z.object({ x: z.number(), y: z.number(), description: z.string().optional() }) }
);

const inputTextTool = tool(
  async ({ text }) => {
    if (isPhone) {
      const appIds = currentAppId ? [currentAppId] : ['com.apple.springboard'];
      await xctest('POST', '/inputText', { text, appIds });
    } else {
      const header = currentAppId ? `appId: ${currentAppId}\n---\n` : 'appId: any\n---\n';
      const fp = join(tmpdir(), `input-${Date.now()}.yaml`);
      writeFileSync(fp, `${header}- inputText: "${text.replace(/"/g, '\\"')}"`);
      await runShell(`maestro test ${fp}`, 30000);
      try { unlinkSync(fp); } catch {}
    }
    return `Typed "${text}"`;
  },
  { name: 'inputText', description: 'Type text into focused field. Only after tapping a text field.', schema: z.object({ text: z.string() }) }
);

const pressKeyTool = tool(
  async ({ key }) => {
    if (isPhone) {
      await xctest('POST', '/pressKey', { key });
    } else {
      const header = currentAppId ? `appId: ${currentAppId}\n---\n` : 'appId: any\n---\n';
      const fp = join(tmpdir(), `key-${Date.now()}.yaml`);
      writeFileSync(fp, `${header}- pressKey: ${key}`);
      await runShell(`maestro test ${fp}`, 30000);
      try { unlinkSync(fp); } catch {}
    }
    return `Pressed ${key}`;
  },
  { name: 'pressKey', description: 'Press a key (enter, delete, tab, space, escape).', schema: z.object({ key: z.string() }) }
);

const scrollTool = tool(
  async () => {
    if (isPhone) {
      const midX = Math.round(phoneScreenWidth / 2);
      await xctest('POST', '/swipe', { startX: midX, startY: Math.round(phoneScreenHeight * 0.7), endX: midX, endY: Math.round(phoneScreenHeight * 0.3), duration: 0.3 });
    } else {
      const header = currentAppId ? `appId: ${currentAppId}\n---\n` : 'appId: any\n---\n';
      const fp = join(tmpdir(), `scroll-${Date.now()}.yaml`);
      writeFileSync(fp, `${header}- scroll`);
      await runShell(`maestro test ${fp}`, 30000);
      try { unlinkSync(fp); } catch {}
    }
    return 'Scrolled down';
  },
  { name: 'scroll', description: 'Scroll down to see more content.', schema: z.object({}) }
);

const takeScreenshotTool = tool(
  async () => {
    let b64;
    if (isPhone) {
      const resp = await xctest('GET', '/screenshot');
      const buf = Buffer.from(await resp.arrayBuffer());
      b64 = buf.toString('base64');
    } else {
      const p = join(tmpdir(), `ss-${Date.now()}.png`);
      await runShell(`xcrun simctl io booted screenshot "${p}"`, 10000);
      const buf = readFileSync(p);
      try { unlinkSync(p); } catch {}
      b64 = buf.toString('base64');
    }
    // Return as a message the agent can see
    return `Screenshot captured (${Math.round(b64.length * 3 / 4 / 1024)} KB). The image has been added to the conversation.`;
  },
  { name: 'takeScreenshot', description: 'Capture the current screen to see what is displayed. Use before tapping to understand the layout.', schema: z.object({}) }
);

const searchMapsTool = tool(
  async ({ query }) => {
    if (isPhone) {
      await xctest('POST', '/launchApp', { bundleId: 'com.apple.Maps' });
      currentAppId = 'com.apple.Maps';
      return `Opened Maps. Now tap the search bar and type "${query}" to search.`;
    }
    await runShell(`xcrun simctl openurl booted "maps://?q=${encodeURIComponent(query)}"`);
    currentAppId = 'com.apple.Maps';
    return `Searched Maps for "${query}"`;
  },
  { name: 'searchMaps', description: 'Search Apple Maps for a location.', schema: z.object({ query: z.string() }) }
);

const googleSearchTool = tool(
  async ({ query }) => {
    if (isPhone) {
      await xctest('POST', '/launchApp', { bundleId: 'com.apple.mobilesafari' });
      currentAppId = 'com.apple.mobilesafari';
      return `Opened Safari. Tap the address bar and search for "${query}".`;
    }
    await runShell(`xcrun simctl openurl booted "https://google.com/search?q=${encodeURIComponent(query)}"`);
    currentAppId = 'com.apple.mobilesafari';
    return `Searched Google for "${query}"`;
  },
  { name: 'googleSearch', description: 'Search Google in Safari.', schema: z.object({ query: z.string() }) }
);

const taskCompleteTool = tool(
  async ({ summary }) => summary,
  { name: 'taskComplete', description: 'Call when the task is fully completed and verified on screen.', schema: z.object({ summary: z.string() }) }
);

const tools = [
  openAppTool, tapTool, inputTextTool, pressKeyTool, scrollTool,
  takeScreenshotTool, searchMapsTool, googleSearchTool, taskCompleteTool,
];

// ─── Create LLM ───
let llm;
if (provider === 'openai') {
  llm = new ChatOpenAI({ modelName, apiKey, temperature: 0 });
} else {
  llm = new ChatGoogleGenerativeAI({ modelName, apiKey, temperature: 0 });
}

// ─── System Prompt ───
const systemPrompt = `You are an AI agent controlling a ${isPhone ? 'physical iPhone' : 'iOS simulator'}. Complete the user's task.

AVAILABLE APPS: ${Object.keys(appMap).join(', ')}

STRATEGY:
1. Use openApp to launch the right app, then takeScreenshot to see the screen.
2. Use tap/inputText/pressKey to interact with the UI.
3. Coordinates are PERCENTAGES 0-100, NOT pixels.
4. After completing the task, takeScreenshot to verify, then call taskComplete.

RULES:
- Always takeScreenshot before tapping to see what's on screen
- After inputText, press enter or tap submit
- iOS Photos: most recent is BOTTOM-RIGHT
- iOS Maps: search bar is at BOTTOM
- If stuck, try a different approach`;

// ─── Create LangGraph Agent ───
console.log('[LangGraph] Creating agent...');
const agent = createReactAgent({
  llm,
  tools,
  prompt: systemPrompt,
});

// ─── Run ───
const totalStart = Date.now();
console.log(`\n${'='.repeat(50)}`);
console.log(`  Task:      ${task}`);
console.log(`  Model:     ${modelName} (${provider})`);
console.log(`  Device:    ${isPhone ? 'Physical iPhone' : 'Simulator'}`);
console.log(`  Framework: LangGraph.js`);
console.log(`${'='.repeat(50)}\n`);

try {
  let stepCount = 0;
  const stream = await agent.stream(
    { messages: [new HumanMessage(task)] },
    { recursionLimit: maxSteps * 2 }
  );

  for await (const event of stream) {
    // Agent node output
    if (event.agent) {
      const msg = event.agent.messages?.[event.agent.messages.length - 1];
      if (msg?.tool_calls?.length) {
        for (const tc of msg.tool_calls) {
          console.log(`[Tool Call] ${tc.name}(${JSON.stringify(tc.args)})`);
        }
      } else if (msg?.content) {
        console.log(`[AI] ${typeof msg.content === 'string' ? msg.content.slice(0, 200) : 'responded'}`);
      }
    }

    // Tool node output
    if (event.tools) {
      stepCount++;
      const elapsed = ((Date.now() - totalStart) / 1000).toFixed(1);
      for (const msg of event.tools.messages || []) {
        const content = typeof msg.content === 'string' ? msg.content : JSON.stringify(msg.content);
        console.log(`[Tool Result] ${content.slice(0, 150)}`);

        // Check for taskComplete
        if (msg.name === 'taskComplete') {
          const totalTime = ((Date.now() - totalStart) / 1000).toFixed(1);
          console.log(`\n${'='.repeat(50)}`);
          console.log(`  ✅ TASK COMPLETED`);
          console.log(`  ${content}`);
          console.log(`  Steps: ${stepCount} | Total time: ${totalTime}s`);
          console.log(`${'='.repeat(50)}`);
          process.exit(0);
        }
      }
      console.log(`[Step ${stepCount}] (${elapsed}s total)`);
    }
  }

  const totalTime = ((Date.now() - totalStart) / 1000).toFixed(1);
  console.log(`\n${'='.repeat(50)}`);
  console.log(`  ⏱️ AGENT FINISHED (${totalTime}s, ${stepCount} steps)`);
  console.log(`${'='.repeat(50)}`);

} catch (e) {
  console.log(`\n❌ ERROR: ${e.message}`);
  process.exit(1);
}
