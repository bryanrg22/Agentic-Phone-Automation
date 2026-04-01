#!/usr/bin/env node
/**
 * mobile-use agent with tools + Maestro MCP server
 * Just describe what you want — the AI picks the right app and action.
 * Maestro boots once, all taps/inputs are fast after that.
 */
import 'dotenv/config';
import { exec, spawn } from 'child_process';
import { readFileSync, writeFileSync, unlinkSync, mkdirSync, readdirSync, existsSync } from 'fs';
import { tmpdir, homedir } from 'os';
import { join } from 'path';

// ─── Parse args ───
const args = process.argv.slice(2);
// Filter out flag values (words that follow --flag) from the task
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
const agentMode = args.find((_, i) => args[i - 1] === '--agent-mode') || 'single-image';
const visionEveryK = parseInt(args.find((_, i) => args[i - 1] === '--vision-every-k') || '5');
const grounding = args.find((_, i) => args[i - 1] === '--grounding') || 'baseline'; // baseline | grid | zoomclick
const useCompression = args.includes('--compress');

if (!task) {
  console.log('Usage: node agent.mjs "your task" [--max-steps N] [--model MODEL] [--provider openai|gemini] [--phone] [--grounding baseline|grid|zoomclick]');
  console.log('\nExamples:');
  console.log('  node agent.mjs "search for USC on Maps"');
  console.log('  node agent.mjs "search for USC on Maps" --provider openai');
  console.log('  node agent.mjs "search for USC on Maps" --phone --grounding grid');
  console.log('  node agent.mjs "search for USC on Maps" --phone --grounding zoomclick');
  process.exit(1);
}

// ─── Provider config ───
const LLM_CONFIG = {
  openai: {
    url: 'https://api.openai.com/v1/chat/completions',
    keyEnv: 'OPENAI_API_KEY',
    keyHint: 'https://platform.openai.com/api-keys',
  },
  gemini: {
    url: 'https://generativelanguage.googleapis.com/v1beta/openai/chat/completions',
    keyEnv: 'GEMINI_API_KEY',
    keyHint: 'https://aistudio.google.com/apikey',
  },
};

const llmConfig = LLM_CONFIG[provider];
if (!llmConfig) { console.log(`ERROR: Unknown provider "${provider}". Use: openai or gemini`); process.exit(1); }

const apiKey = process.env[llmConfig.keyEnv];
if (!apiKey) { console.log(`ERROR: Set ${llmConfig.keyEnv} (${llmConfig.keyHint})`); process.exit(1); }

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

// ─── Grid overlay (draws percentage grid lines + labels on screenshot) ───
async function addGridOverlay(imageBuffer) {
  const sharp = (await import('sharp')).default;
  const metadata = await sharp(imageBuffer).metadata();
  const w = metadata.width;
  const h = metadata.height;

  // Create SVG overlay with grid lines every 10% and labels every 20%
  const lines = [];
  const labels = [];

  // Vertical lines
  for (let pct = 10; pct <= 90; pct += 10) {
    const x = Math.round((pct / 100) * w);
    const opacity = pct % 20 === 0 ? 0.4 : 0.2;
    const strokeW = pct % 20 === 0 ? 2 : 1;
    lines.push(`<line x1="${x}" y1="0" x2="${x}" y2="${h}" stroke="rgba(255,255,0,${opacity})" stroke-width="${strokeW}"/>`);
    if (pct % 20 === 0) {
      labels.push(`<text x="${x + 4}" y="28" fill="rgba(255,255,0,0.8)" font-size="24" font-family="Arial" font-weight="bold">${pct}</text>`);
    }
  }

  // Horizontal lines
  for (let pct = 10; pct <= 90; pct += 10) {
    const y = Math.round((pct / 100) * h);
    const opacity = pct % 20 === 0 ? 0.4 : 0.2;
    const strokeW = pct % 20 === 0 ? 2 : 1;
    lines.push(`<line x1="0" y1="${y}" x2="${w}" y2="${y}" stroke="rgba(255,255,0,${opacity})" stroke-width="${strokeW}"/>`);
    if (pct % 20 === 0) {
      labels.push(`<text x="4" y="${y - 6}" fill="rgba(255,255,0,0.8)" font-size="24" font-family="Arial" font-weight="bold">${pct}</text>`);
    }
  }

  const svg = `<svg width="${w}" height="${h}">${lines.join('')}${labels.join('')}</svg>`;

  const result = await sharp(imageBuffer)
    .composite([{ input: Buffer.from(svg), top: 0, left: 0 }])
    .png()
    .toBuffer();

  return result;
}

// ─── ZoomClick (crop region, send zoomed view, get refined coordinates) ───
async function zoomAndRefine(screenshotBuffer, roughX, roughY, screenW, screenH) {
  const sharp = (await import('sharp')).default;
  const metadata = await sharp(screenshotBuffer).metadata();
  const imgW = metadata.width;
  const imgH = metadata.height;

  // Convert percentage to pixel in image space
  const pixX = Math.round((roughX / 100) * imgW);
  const pixY = Math.round((roughY / 100) * imgH);

  // Crop a region around the rough point (25% of screen in each direction)
  const cropSize = Math.round(Math.min(imgW, imgH) * 0.25);
  const cropX = Math.max(0, Math.min(imgW - cropSize, pixX - Math.round(cropSize / 2)));
  const cropY = Math.max(0, Math.min(imgH - cropSize, pixY - Math.round(cropSize / 2)));
  const cropW = Math.min(cropSize, imgW - cropX);
  const cropH = Math.min(cropSize, imgH - cropY);

  // Crop and resize to 2x for clarity
  const croppedBuffer = await sharp(screenshotBuffer)
    .extract({ left: cropX, top: cropY, width: cropW, height: cropH })
    .resize(cropW * 2, cropH * 2, { kernel: 'lanczos3' })
    .png()
    .toBuffer();

  // Return the cropped image + metadata for mapping coordinates back
  return {
    buffer: croppedBuffer,
    cropX, cropY, cropW, cropH,
    imgW, imgH,
    // To convert from zoomed percentage back to full-screen percentage:
    mapBack: (zoomedPctX, zoomedPctY) => {
      const localPixX = (zoomedPctX / 100) * cropW;
      const localPixY = (zoomedPctY / 100) * cropH;
      const fullPixX = cropX + localPixX;
      const fullPixY = cropY + localPixY;
      return {
        x: Math.round((fullPixX / imgW) * 100),
        y: Math.round((fullPixY / imgH) * 100),
      };
    },
  };
}

// ─── Maestro MCP Server ───
class MaestroMCP {
  constructor() {
    this.process = null;
    this.buffer = '';
    this.nextId = 1;
    this.pending = new Map();
    this.deviceId = null;
    this.ready = false;
  }

  async start() {
    return new Promise((resolve, reject) => {
      this.process = spawn('maestro', ['mcp'], { stdio: ['pipe', 'pipe', 'pipe'] });
      this.process.stderr.on('data', () => {}); // suppress warnings

      this.process.stdout.on('data', (data) => {
        this.buffer += data.toString();
        const lines = this.buffer.split('\n');
        this.buffer = lines.pop() || ''; // keep incomplete line
        for (const line of lines) {
          if (!line.trim()) continue;
          try {
            const msg = JSON.parse(line.trim());
            if (msg.id && this.pending.has(msg.id)) {
              this.pending.get(msg.id)(msg);
              this.pending.delete(msg.id);
            }
          } catch {}
        }
      });

      this.process.on('error', reject);

      // Initialize MCP protocol
      this._call('initialize', {
        protocolVersion: '2024-11-05',
        capabilities: {},
        clientInfo: { name: 'mobile-use', version: '1.0' },
      }).then(() => {
        this.ready = true;
        resolve();
      }).catch(reject);
    });
  }

  _call(method, params) {
    return new Promise((resolve, reject) => {
      const id = this.nextId++;
      const timeout = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`MCP timeout: ${method}`));
      }, 60000);

      this.pending.set(id, (msg) => {
        clearTimeout(timeout);
        if (msg.error) reject(new Error(msg.error.message || JSON.stringify(msg.error)));
        else resolve(msg.result);
      });

      this.process.stdin.write(JSON.stringify({ jsonrpc: '2.0', id, method, params }) + '\n');
    });
  }

  async callTool(name, args) {
    const result = await this._call('tools/call', { name, arguments: args });
    const content = result?.content?.[0];
    if (content?.type === 'image') {
      return { type: 'image', data: content.data, mimeType: content.mimeType };
    }
    const text = content?.text || '';
    // Check for success/failure
    if (text.includes('"success":true') || text.includes('success')) return { type: 'text', text };
    if (text.includes('Failed') || text.includes('Error')) throw new Error(text.slice(0, 200));
    return { type: 'text', text };
  }

  async detectDevice(preferPhysical = false) {
    const result = await this.callTool('list_devices', {});
    const devices = JSON.parse(result.text);
    const dev = preferPhysical
      ? devices.devices?.find(d => d.connected && d.type !== 'simulator') || devices.devices?.find(d => d.connected)
      : devices.devices?.find(d => d.connected && d.type === 'simulator') || devices.devices?.find(d => d.connected);
    if (dev) {
      this.deviceId = dev.device_id;
      return dev;
    }
    throw new Error('No connected device found');
  }

  async tap(text) {
    return this.callTool('tap_on', { device_id: this.deviceId, text });
  }

  async tapById(id) {
    return this.callTool('tap_on', { device_id: this.deviceId, id });
  }

  async inputText(text) {
    return this.callTool('input_text', { device_id: this.deviceId, text });
  }

  async screenshot() {
    return this.callTool('take_screenshot', { device_id: this.deviceId });
  }

  async viewHierarchy() {
    return this.callTool('inspect_view_hierarchy', { device_id: this.deviceId });
  }

  async back() {
    return this.callTool('back', { device_id: this.deviceId });
  }

  async launchApp(appId) {
    return this.callTool('launch_app', { device_id: this.deviceId, appId });
  }

  async runFlow(yaml) {
    return this.callTool('run_flow', { device_id: this.deviceId, flow_yaml: yaml });
  }

  stop() {
    if (this.process) {
      this.process.kill();
      this.process = null;
    }
  }
}

// ─── Setup ───
console.log(`[Setup] Mode: ${isPhone ? 'Physical iPhone' : 'Simulator'}`);
console.log('[Setup] Detecting apps...');
const appMap = {};
const knownBundleIds = {
  Safari: 'com.apple.mobilesafari', Maps: 'com.apple.Maps', Messages: 'com.apple.MobileSMS',
  Calendar: 'com.apple.mobilecal', Photos: 'com.apple.mobileslideshow', Camera: 'com.apple.camera',
  Settings: 'com.apple.Preferences', Notes: 'com.apple.mobilenotes', Reminders: 'com.apple.reminders',
  Contacts: 'com.apple.MobileAddressBook', Phone: 'com.apple.mobilephone', Mail: 'com.apple.mobilemail',
  Weather: 'com.apple.weather', Clock: 'com.apple.mobiletimer', Files: 'com.apple.DocumentsApp',
  News: 'com.apple.news', Health: 'com.apple.Health', Wallet: 'com.apple.Passbook',
  Shortcuts: 'com.apple.shortcuts', Music: 'com.apple.Music', Podcasts: 'com.apple.podcasts',
  'App Store': 'com.apple.AppStore', Calculator: 'com.apple.calculator', Compass: 'com.apple.compass',
  'Voice Memos': 'com.apple.VoiceMemos', Measure: 'com.apple.measure', TV: 'com.apple.tv',
  Passwords: 'com.apple.Passwords', Clips: 'com.apple.clips',
  // Common third-party apps
  Spotify: 'com.spotify.client', Instagram: 'com.burbn.instagram', Snapchat: 'com.toyopagroup.picaboo',
  TikTok: 'com.zhiliaoapp.musically', YouTube: 'com.google.ios.youtube', Gmail: 'com.google.Gmail',
  WhatsApp: 'net.whatsapp.WhatsApp', Telegram: 'ph.telegra.Telegraph', Discord: 'com.hammerandchisel.discord',
  Uber: 'com.ubercab.UberClient', Starbucks: 'com.starbucks.mystarbucks', Amazon: 'com.amazon.Amazon',
  Twitter: 'com.atebits.Tweetie2', Reddit: 'com.reddit.Reddit', Netflix: 'com.netflix.Netflix',
  Notion: 'notion.id', Slack: 'com.tinyspeck.chatlyio', ChatGPT: 'com.openai.chat',
  LinkedIn: 'com.linkedin.LinkedIn', GitHub: 'com.github.stormbreaker.prod', Zoom: 'us.zoom.videomeetings',
  Outlook: 'com.microsoft.Office.Outlook', 'Google Calendar': 'com.google.calendar',
  'Nike Run Club': 'com.nike.nrc', Robinhood: 'com.robinhood.release.Robinhood',
  GroupMe: 'com.groupme.iphone', Expedia: 'com.expedia.app',
  SNKRS: 'com.nike.snkrs', Supreme: 'com.supremenewyork.supreme',
};

if (isPhone) {
  // Known bundle IDs for common apps (used to map detected app names to bundle IDs)
  // Start with known apps, then detect more from home screen after XCTest warms up
  Object.assign(appMap, knownBundleIds);
} else {
  const appListRaw = await runShell('xcrun simctl listapps booted');
  const lines = appListRaw.split('\n');
  let currentName = '';
  for (const line of lines) {
    const nm = line.match(/CFBundleDisplayName\s*=\s*"?([^";]+)"?/);
    const id = line.match(/CFBundleIdentifier\s*=\s*"?([^";]+)"?/);
    if (nm) currentName = nm[1].trim();
    if (id && currentName) {
      const bid = id[1].trim();
      if (!bid.includes('Preview') && !bid.includes('PreviewShell') && currentName !== 'Watch' && currentName !== 'Web') {
        appMap[currentName] = bid;
      }
      currentName = '';
    }
  }
}
const appListStr = Object.entries(appMap).map(([n, id]) => `${n}: ${id}`).join('\n');
console.log(`[Setup] Found ${Object.keys(appMap).length} apps`);

// Start Maestro
let maestro;
let currentAppId = null;
let phoneScreenWidth = 393; // iPhone 15 Pro default
let phoneScreenHeight = 852;

if (isPhone) {
  // Phone mode: Direct HTTP to XCTest runner on port 6001 (via maestro-ios-device bridge)
  const XCTEST_URL = `http://localhost:${driverPort}`;
  console.log('[Setup] Phone mode — direct HTTP to XCTest runner on port ' + driverPort);
  console.log('[Setup] Make sure maestro-ios-device bridge is running:');
  console.log('[Setup]   maestro-ios-device --team-id C924TNC23B --device ' + phoneDeviceId);

  // Helper for XCTest HTTP calls
  async function xctest(method, path, body = null) {
    const opts = { method, signal: AbortSignal.timeout(30000) };
    if (body !== null) {
      opts.headers = { 'Content-Type': 'application/json' };
      opts.body = JSON.stringify(body);
    }
    const resp = await fetch(`${XCTEST_URL}${path}`, opts);
    if (!resp.ok && resp.status !== 200) {
      const errText = await resp.text().catch(() => '');
      throw new Error(`XCTest ${path} failed (${resp.status}): ${errText.slice(0, 150)}`);
    }
    return resp;
  }

  // Create phone wrapper using direct HTTP (no JVM, ~100ms per call)
  maestro = {
    deviceId: phoneDeviceId,
    async runFlow(yaml) {
      // runFlow is only used as fallback — for direct HTTP, use specific methods
      const flowPath = join(tmpdir(), `maestro-flow-${Date.now()}.yaml`);
      writeFileSync(flowPath, yaml);
      const cmd = `maestro --driver-host-port ${driverPort} --device ${phoneDeviceId} test ${flowPath}`;
      return new Promise((resolve, reject) => {
        exec(cmd, { timeout: 60000 }, (error, stdout) => {
          try { unlinkSync(flowPath); } catch {}
          if (error) reject(new Error(`Maestro: ${error.message.slice(0, 200)}`));
          else resolve({ type: 'text', text: stdout || 'ok' });
        });
      });
    },
    async launchApp(appId) {
      await xctest('POST', '/launchApp', { bundleId: appId });
      return { type: 'text', text: 'ok' };
    },
    async inputText(text) {
      const appIds = currentAppId ? [currentAppId] : ['com.apple.springboard'];
      await xctest('POST', '/inputText', { text, appIds });
      return { type: 'text', text: 'ok' };
    },
    async tap(text) {
      // Text-based tap via Maestro CLI fallback (direct HTTP doesn't have text search)
      const flowPath = join(tmpdir(), `maestro-flow-${Date.now()}.yaml`);
      const header = currentAppId ? `appId: ${currentAppId}\n---\n` : 'appId: any\n---\n';
      writeFileSync(flowPath, `${header}- tapOn:\n    text: "${text.replace(/"/g, '\\"')}"`);
      const cmd = `maestro --driver-host-port ${driverPort} --device ${phoneDeviceId} test ${flowPath}`;
      return new Promise((resolve, reject) => {
        exec(cmd, { timeout: 60000 }, (error) => {
          try { unlinkSync(flowPath); } catch {}
          if (error) reject(new Error(`Maestro tap failed: ${error.message.slice(0, 150)}`));
          else resolve({ type: 'text', text: 'ok' });
        });
      });
    },
    async touchPoint(x, y, duration = 0.1) {
      await xctest('POST', '/touch', { x, y, duration });
      return { type: 'text', text: 'ok' };
    },
    async pressKey(key) {
      await xctest('POST', '/pressKey', { key });
      return { type: 'text', text: 'ok' };
    },
    async swipe(startX, startY, endX, endY, duration = 0.3) {
      await xctest('POST', '/swipe', { startX, startY, endX, endY, duration });
      return { type: 'text', text: 'ok' };
    },
    async viewHierarchy() {
      const appIds = currentAppId ? [currentAppId] : ['com.apple.springboard'];
      const resp = await xctest('POST', '/viewHierarchy', { appIds, excludeKeyboardElements: false });
      const text = await resp.text();
      return { type: 'text', text };
    },
    async screenshot() {
      const resp = await xctest('GET', '/screenshot');
      const arrayBuf = await resp.arrayBuffer();
      const buffer = Buffer.from(arrayBuf);
      return { type: 'image', data: buffer.toString('base64') };
    },
    async eraseText(chars) {
      const appIds = currentAppId ? [currentAppId] : ['com.apple.springboard'];
      await xctest('POST', '/eraseText', { charactersToErase: chars, appIds });
      return { type: 'text', text: 'ok' };
    },
    async deviceInfo() {
      const resp = await xctest('GET', '/deviceInfo');
      return await resp.json();
    },
    stop() {},
  };

  // Check if XCTest runner is already alive (from a previous run)
  console.log('[Setup] Checking XCTest runner...');
  const warmStart = Date.now();
  let runnerAlive = false;
  try {
    const resp = await fetch(`http://localhost:${driverPort}/deviceInfo`, { signal: AbortSignal.timeout(3000) });
    if (resp.ok) runnerAlive = true;
  } catch {}

  if (!runnerAlive) {
    // Need to wake it up with one Maestro CLI call (the only JVM hit)
    console.log('[Setup] Waking up XCTest runner (one-time, ~5s)...');
    try {
      const flowPath = join(tmpdir(), `maestro-warm-${Date.now()}.yaml`);
      writeFileSync(flowPath, 'appId: any\n---\n- pressKey: space');
      const cmd = `maestro --driver-host-port ${driverPort} --device ${phoneDeviceId} test ${flowPath}`;
      await new Promise((resolve, reject) => {
        exec(cmd, { timeout: 60000 }, (error) => {
          try { unlinkSync(flowPath); } catch {}
          // Ignore errors — the runner starts regardless
          resolve();
        });
      });
    } catch {}
  }
  console.log(`[Setup] XCTest runner ready (${((Date.now() - warmStart) / 1000).toFixed(1)}s)`);

  // Verify direct HTTP works
  console.log('[Setup] Testing direct HTTP...');
  try {
    const infoStart = Date.now();
    const info = await maestro.deviceInfo();
    phoneScreenWidth = info.widthPoints;
    phoneScreenHeight = info.heightPoints;
    console.log(`[Setup] Direct HTTP OK (${((Date.now() - infoStart) / 1000).toFixed(1)}s) | Screen: ${phoneScreenWidth}x${phoneScreenHeight}`);

    // Test screenshot
    const ssStart = Date.now();
    await maestro.screenshot();
    console.log(`[Setup] Screenshot OK (${((Date.now() - ssStart) / 1000).toFixed(1)}s)`);

    // Auto-detect apps from home screen
    console.log('[Setup] Detecting installed apps from home screen...');
    try {
      // Go to home screen first
      await maestro.pressKey('home').catch(() => {});
      await sleep(500);
      const hier = await maestro.viewHierarchy();
      const hierText = hier.text || '';
      const detectedApps = [];
      try {
        const json = JSON.parse(hierText);
        function findApps(node) {
          if (!node) return;
          if (node.label && node.label.trim()) detectedApps.push(node.label.trim());
          if (node.children) node.children.forEach(findApps);
        }
        findApps(json?.axElement || json);
      } catch {}
      // Filter to likely app names (exclude noise like times, percentages, etc.)
      const appNoise = ['Dock', 'Search', 'Horizontal scroll bar', 'Vertical scroll bar', 'Current Location',
        'TOMORROW', 'Today', 'Utilities folder', 'Zoom lens', 'Location Services', 'High of', 'Low of'];
      const detected = [...new Set(detectedApps)].filter(name =>
        name.length > 1 && name.length < 30 &&
        !appNoise.some(n => name.includes(n)) &&
        !name.match(/^\d/) && !name.includes('°') && !name.includes('http') &&
        !name.includes('battery') && !name.includes('signal') && !name.includes('Wi-Fi') &&
        !name.includes('PM') && !name.includes('AM') && !name.includes('scroll bar')
      );
      // Add detected apps that aren't already in appMap
      for (const name of detected) {
        if (!appMap[name] && knownBundleIds[name]) {
          appMap[name] = knownBundleIds[name];
        }
      }
      // Update the app list string
      const updatedAppListStr = Object.entries(appMap).map(([n, id]) => `${n}: ${id}`).join('\n');
      console.log(`[Setup] Detected ${detected.length} apps on home screen, ${Object.keys(appMap).length} total with bundle IDs`);
    } catch (e) {
      console.log(`[Setup] App detection skipped: ${e.message}`);
    }
  } catch (e) {
    console.log(`[Setup] Direct HTTP failed: ${e.message}`);
    console.log('[Setup] Falling back to Maestro CLI (slower).');
  }
} else {
  // Simulator mode: use MCP server
  console.log('[Setup] Starting Maestro MCP server...');
  maestro = new MaestroMCP();
  const mcpStart = Date.now();
  await maestro.start();
  const device = await maestro.detectDevice();
  console.log(`[Setup] Maestro ready (${((Date.now() - mcpStart) / 1000).toFixed(1)}s) | Device: ${device.name}`);

  console.log('[Setup] Warming up device connection...');
  const warmStart = Date.now();
  try { await maestro.viewHierarchy(); } catch {}
  console.log(`[Setup] Device warmed up (${((Date.now() - warmStart) / 1000).toFixed(1)}s)`);
}

// Cleanup on exit
process.on('exit', () => maestro.stop());
process.on('SIGINT', () => { maestro.stop(); process.exit(0); });
process.on('SIGTERM', () => { maestro.stop(); process.exit(0); });

// ─── Tool definitions ───
const toolDefs = [
  { name: 'searchMaps', description: 'Search Apple Maps for a location or place. Instant.', parameters: { type: 'object', properties: { query: { type: 'string', description: 'Place to search' } }, required: ['query'] } },
  { name: 'getDirections', description: 'Get directions to a destination on Apple Maps. Instant.', parameters: { type: 'object', properties: { destination: { type: 'string', description: 'Destination' } }, required: ['destination'] } },
  { name: 'openURL', description: 'Open a URL in Safari. Instant.', parameters: { type: 'object', properties: { url: { type: 'string', description: 'URL (with or without https://)' } }, required: ['url'] } },
  { name: 'googleSearch', description: 'Search Google in Safari. Instant.', parameters: { type: 'object', properties: { query: { type: 'string', description: 'Search query' } }, required: ['query'] } },
  { name: 'composeMessage', description: 'Open Messages to compose a new text. Optionally pre-fill body.', parameters: { type: 'object', properties: { body: { type: 'string', description: 'Message body (optional)' } } } },
  { name: 'setAppearance', description: 'Switch dark mode or light mode. Instant.', parameters: { type: 'object', properties: { mode: { type: 'string', enum: ['dark', 'light'], description: 'Appearance mode' } }, required: ['mode'] } },
  { name: 'setLocation', description: 'Set GPS location. Instant.', parameters: { type: 'object', properties: { latitude: { type: 'number' }, longitude: { type: 'number' }, name: { type: 'string', description: 'Location name' } }, required: ['latitude', 'longitude'] } },
  ...(!isPhone ? [{ name: 'copyToClipboard', description: 'Copy text to device clipboard.', parameters: { type: 'object', properties: { text: { type: 'string' } }, required: ['text'] } }] : []),
  { name: 'openApp', description: `Open an app by name. Available: ${Object.keys(appMap).join(', ')}`, parameters: { type: 'object', properties: { appName: { type: 'string', description: 'App name' } }, required: ['appName'] } },
  { name: 'takeScreenshot', description: 'Capture the current screen. NOTE: screenshots are auto-captured after action tools (tap, type, etc.) so you usually do NOT need to call this separately. Only use for initial observation or to verify final task completion.', parameters: { type: 'object', properties: {} } },
  { name: 'getUIElements', description: 'Get all UI elements on screen with their text, IDs, and positions. Use this to find exact buttons/fields before tapping. More accurate than guessing coordinates from a screenshot.', parameters: { type: 'object', properties: {} } },
  { name: 'tap', description: 'Tap at screen coordinates. MUST be percentages 0-100 (NOT pixels). x=0 left edge, x=50 center, x=100 right edge. y=0 top, y=50 middle, y=100 bottom. Example: center of screen is x=50,y=50.', parameters: { type: 'object', properties: { x: { type: 'number', description: 'X percentage 0-100' }, y: { type: 'number', description: 'Y percentage 0-100' }, description: { type: 'string' } }, required: ['x', 'y'] } },
  { name: 'tapText', description: 'Tap on visible text on screen. Uses fuzzy matching.', parameters: { type: 'object', properties: { text: { type: 'string' } }, required: ['text'] } },
  { name: 'inputText', description: 'Type text into focused field. Only after tapping a text field.', parameters: { type: 'object', properties: { text: { type: 'string' } }, required: ['text'] } },
  { name: 'pressKey', description: 'Press a key (enter, delete, tab, etc).', parameters: { type: 'object', properties: { key: { type: 'string' } }, required: ['key'] } },
  { name: 'scroll', description: 'Scroll down.', parameters: { type: 'object', properties: {} } },
  { name: 'swipe', description: 'Swipe gesture. Coordinates as percentages.', parameters: { type: 'object', properties: { startX: { type: 'number' }, startY: { type: 'number' }, endX: { type: 'number' }, endY: { type: 'number' } }, required: ['startX', 'startY', 'endX', 'endY'] } },
  { name: 'hideKeyboard', description: 'Dismiss the keyboard.', parameters: { type: 'object', properties: {} } },
  { name: 'typeAndSubmit', description: 'Tap a text field, type text, and press enter/send — all in one step. Use this instead of separate tap + inputText + pressKey calls. Much faster for search bars, message fields, form inputs. This tool HANDLES SENDING — do NOT tap the send button after calling this. Instead, take a screenshot to verify the message was sent.', parameters: { type: 'object', properties: { elementText: { type: 'string', description: 'Text of the field to tap (e.g. "Search", "Message") — uses tapText' }, text: { type: 'string', description: 'Text to type' }, submitKey: { type: 'string', description: 'Key to press after typing (default: enter). Use "send" for Messages blue arrow.' } }, required: ['elementText', 'text'] } },
  ...(grounding === 'zoomclick' ? [{
    name: 'zoomAndTap',
    description: 'Zoom into a region of the screen for precise tapping. Use this instead of tap when: (1) targeting small icons, (2) multiple elements are close together, (3) you need precision. Provide the rough area to zoom into, and you will get a zoomed view to tap more precisely.',
    parameters: { type: 'object', properties: { x: { type: 'number', description: 'Rough X percentage (0-100) of the area to zoom into' }, y: { type: 'number', description: 'Rough Y percentage (0-100) of the area to zoom into' }, description: { type: 'string', description: 'What you are trying to tap' } }, required: ['x', 'y', 'description'] }
  }] : []),
  { name: 'saveMemory', description: 'Save a fact about the user to persistent memory. Use when you learn: user preferences, which contact they mean, their address, habits, or any reusable personal info. Also save after askUser resolves ambiguity so you do not ask again next time.', parameters: { type: 'object', properties: { fact: { type: 'string', description: 'The fact to remember (e.g. "Kenny = Kenny Frias", "Home address: 123 Main St")' } }, required: ['fact'] } },
  { name: 'recallMemory', description: 'Read all saved memory. Use at the start of tasks involving personal info if you need to check what you know.', parameters: { type: 'object', properties: {} } },
  { name: 'recallHistory', description: 'Read past task history. Use when the user asks about previous tasks, what you did earlier, or wants to repeat a past action.', parameters: { type: 'object', properties: {} } },
  { name: 'webSearch', description: 'Search the web for information. Use when you encounter an unfamiliar app, game, or interface and need to understand how it works before interacting. Also useful for looking up facts, instructions, or context the user might expect you to know.', parameters: { type: 'object', properties: { query: { type: 'string', description: 'Search query (e.g. "how to play LinkedIn Pinpoint game")' } }, required: ['query'] } },
  { name: 'askUser', description: 'Ask the user a question when you need confirmation or clarification. Use ONLY when: multiple contacts/results match, about to send a message/email/call, about to delete data, about to make a purchase, or genuinely uncertain. Do NOT use for routine actions like tapping, scrolling, or opening apps.', parameters: { type: 'object', properties: { question: { type: 'string', description: 'The question to ask the user' }, options: { type: 'array', items: { type: 'string' }, description: 'List of options for the user to choose from (2-4 options)' } }, required: ['question', 'options'] } },
  { name: 'taskComplete', description: 'Task is done. Call when verified complete.', parameters: { type: 'object', properties: { summary: { type: 'string' } }, required: ['summary'] } },
  { name: 'taskFailed', description: 'Task cannot be completed.', parameters: { type: 'object', properties: { reason: { type: 'string' } }, required: ['reason'] } },
];

const openaiTools = toolDefs.map(t => ({ type: 'function', function: { name: t.name, description: t.description, parameters: t.parameters } }));

// ─── Tool executor ───
async function executeTool(name, args) {
  switch (name) {
    // === INSTANT TOOLS ===
    case 'searchMaps': {
      if (isPhone) {
        await maestro.launchApp('com.apple.Maps');
        currentAppId = 'com.apple.Maps';
        return `Opened Maps. Now use takeScreenshot, then tap the search bar and type "${args.query}" to search.`;
      }
      await runShell(`xcrun simctl openurl booted "maps://?q=${encodeURIComponent(args.query)}"`);
      currentAppId = 'com.apple.Maps';
      return `Searched Maps for "${args.query}"`;
    }
    case 'getDirections': {
      if (isPhone) {
        await maestro.launchApp('com.apple.Maps');
        currentAppId = 'com.apple.Maps';
        return `Opened Maps. Now search for "${args.destination}" and tap Directions.`;
      }
      await runShell(`xcrun simctl openurl booted "maps://?daddr=${encodeURIComponent(args.destination)}"`);
      currentAppId = 'com.apple.Maps';
      return `Getting directions to "${args.destination}"`;
    }
    case 'openURL': {
      if (isPhone) {
        await maestro.launchApp('com.apple.mobilesafari');
        currentAppId = 'com.apple.mobilesafari';
        const url = args.url.startsWith('http') ? args.url : `https://${args.url}`;
        return `Opened Safari. Now tap the address bar and type "${url}" to navigate.`;
      }
      const url = args.url.startsWith('http') ? args.url : `https://${args.url}`;
      await runShell(`xcrun simctl openurl booted "${url}"`);
      currentAppId = 'com.apple.mobilesafari';
      return `Opened ${url}`;
    }
    case 'googleSearch': {
      if (isPhone) {
        await maestro.launchApp('com.apple.mobilesafari');
        currentAppId = 'com.apple.mobilesafari';
        return `Opened Safari. Now tap the address bar, type "google.com", navigate there, then search for "${args.query}".`;
      }
      await runShell(`xcrun simctl openurl booted "https://google.com/search?q=${encodeURIComponent(args.query)}"`);
      currentAppId = 'com.apple.mobilesafari';
      return `Searched Google for "${args.query}"`;
    }
    case 'composeMessage': {
      if (isPhone) {
        await maestro.launchApp('com.apple.MobileSMS');
        currentAppId = 'com.apple.MobileSMS';
        return `Opened Messages. Now tap compose to start a new message.`;
      }
      const link = args.body ? `sms:&body=${encodeURIComponent(args.body)}` : 'sms:';
      await runShell(`xcrun simctl openurl booted "${link}"`);
      currentAppId = 'com.apple.MobileSMS';
      return args.body ? `Opened Messages with: "${args.body}"` : 'Opened Messages';
    }
    case 'setAppearance': {
      if (isPhone) return `Cannot toggle appearance on physical device. Navigate to Settings > Display & Brightness manually.`;
      await runShell(`xcrun simctl ui booted appearance ${args.mode}`);
      return `Switched to ${args.mode} mode`;
    }
    case 'setLocation': {
      if (isPhone) return `Cannot set location on physical device.`;
      await runShell(`xcrun simctl location booted set ${args.latitude},${args.longitude}`);
      return `Location set to ${args.name || `${args.latitude},${args.longitude}`}`;
    }
    case 'copyToClipboard': {
      if (isPhone) return `Cannot copy to clipboard on physical device.`;
      await runShell(`printf '%s' "${args.text.replace(/"/g, '\\"')}" | xcrun simctl pbcopy booted`);
      return `Copied to clipboard`;
    }
    case 'openApp': {
      const bid = appMap[args.appName];
      if (!bid) return `App "${args.appName}" not found. Available: ${Object.keys(appMap).join(', ')}`;
      if (isPhone) {
        await maestro.launchApp(bid);
      } else {
        await runShell(`xcrun simctl launch booted ${bid}`);
      }
      currentAppId = bid;
      return `Opened ${args.appName}`;
    }

    // === SCREENSHOT & UI INSPECTION ===
    case 'takeScreenshot': return '__SCREENSHOT__';
    case 'getUIElements': {
      const result = await maestro.viewHierarchy();
      const text = result.text || '';
      const noise = ['scroll bar', 'battery', 'Cellular', 'Wi-Fi bars', 'PM', 'AM', 'No signal', 'Not charging', 'signal strength', 'battery power', 'location services', 'Location tracking'];
      const found = [];
      const screenW = isPhone ? phoneScreenWidth : 402;
      const screenH = isPhone ? phoneScreenHeight : 874;

      // Try JSON format first (direct HTTP viewHierarchy returns nested JSON)
      try {
        const json = JSON.parse(text);
        function collectLabels(node) {
          if (!node) return;
          if (node.label && node.label.trim()) {
            const label = node.label.trim();
            if (!noise.some(n => label.includes(n))) {
              let entry;
              if (node.frame) {
                const pctX = Math.round((node.frame.X + node.frame.Width / 2) / screenW * 100);
                const pctY = Math.round((node.frame.Y + node.frame.Height / 2) / screenH * 100);
                entry = `- "${label}" at (${pctX}%, ${pctY}%)`;
              } else {
                entry = `- "${label}"`;
              }
              if (!found.some(f => f.startsWith(`- "${label}"`))) found.push(entry);
            }
          }
          if (node.children) node.children.forEach(collectLabels);
        }
        collectLabels(json?.axElement || json);
      } catch {
        // Fall back to CSV/regex format (MCP style)
        const boundsRegex = /\[(\d+),(\d+)\]\[(\d+),(\d+)\]/;
        for (const line of text.split('\n')) {
          const labelMatch = line.match(/accessibilityText[="] *:? *"?([^";,\n]+)/);
          if (!labelMatch) continue;
          const label = labelMatch[1].trim();
          if (!label) continue;
          if (noise.some(n => label.includes(n))) continue;
          const bm = line.match(boundsRegex);
          let entry;
          if (bm) {
            const pctX = Math.round(((parseInt(bm[1]) + parseInt(bm[3])) / 2) / screenW * 100);
            const pctY = Math.round(((parseInt(bm[2]) + parseInt(bm[4])) / 2) / screenH * 100);
            entry = `- "${label}" at (${pctX}%, ${pctY}%)`;
          } else {
            entry = `- "${label}"`;
          }
          if (!found.some(f => f.startsWith(`- "${label}"`))) found.push(entry);
        }
      }
      return `Tappable elements on screen:\n${found.join('\n')}\n\nUse tap(x, y) with the coordinates above for precise tapping, or tapText("exact text") to tap by label.`;
    }

    // === INTERACTION TOOLS ===
    case 'tap': {
      if (args.x > 100 || args.y > 100) {
        return `ERROR: Coordinates must be percentages 0-100, not pixels. You sent x=${args.x}, y=${args.y}. Divide by screen size to get percentages. Example: bottom-right corner is x=95, y=95.`;
      }
      if (isPhone && maestro.touchPoint) {
        // Direct HTTP: convert percentage to pixel coordinates
        const px = Math.round((args.x / 100) * phoneScreenWidth);
        const py = Math.round((args.y / 100) * phoneScreenHeight);
        await maestro.touchPoint(px, py);
      } else {
        const header = currentAppId ? `appId: ${currentAppId}\n---\n` : 'appId: any\n---\n';
        await maestro.runFlow(`${header}- tapOn:\n    point: "${args.x}%, ${args.y}%"`);
      }
      return `Tapped (${args.x}%, ${args.y}%)${args.description ? ' - ' + args.description : ''}`;
    }
    case 'tapText': {
      // Find element bounds from view hierarchy, then tap by coordinates (much faster than text search)
      const hierarchy = await maestro.viewHierarchy();
      const hText = hierarchy.text || '';
      // Support both CSV format (bounds in brackets) and JSON format
      const boundsRegex = /\[(\d+),(\d+)\]\[(\d+),(\d+)\]/;
      const frameRegex = /"X"\s*:\s*([\d.]+).*?"Y"\s*:\s*([\d.]+).*?"Width"\s*:\s*([\d.]+).*?"Height"\s*:\s*([\d.]+)/;
      let tapped = false;

      // Try CSV format first (MCP style)
      const hLines = hText.split('\n');
      const csvMatch = hLines.find(l => l.includes(`accessibilityText=${args.text}`));
      if (csvMatch) {
        const bm = csvMatch.match(boundsRegex);
        if (bm) {
          const screenW = isPhone ? phoneScreenWidth : 402;
          const screenH = isPhone ? phoneScreenHeight : 874;
          const cx = Math.round(((parseInt(bm[1]) + parseInt(bm[3])) / 2) / screenW * 100);
          const cy = Math.round(((parseInt(bm[2]) + parseInt(bm[4])) / 2) / screenH * 100);
          if (isPhone && maestro.touchPoint) {
            await maestro.touchPoint(parseInt(bm[1]) + parseInt(bm[3]) >> 1, parseInt(bm[2]) + parseInt(bm[4]) >> 1);
          } else {
            const header = currentAppId ? `appId: ${currentAppId}\n---\n` : 'appId: any\n---\n';
            await maestro.runFlow(`${header}- tapOn:\n    point: "${cx}%, ${cy}%"`);
          }
          return `Tapped "${args.text}" at (${cx}%, ${cy}%)`;
        }
      }

      // Try JSON format (direct HTTP viewHierarchy returns nested JSON)
      try {
        const jsonData = JSON.parse(hText);
        function findElement(node) {
          if (!node) return null;
          if (node.label === args.text || node.title === args.text || node.identifier === args.text) return node;
          if (node.children) {
            for (const child of node.children) {
              const found = findElement(child);
              if (found) return found;
            }
          }
          return null;
        }
        const el = findElement(jsonData?.axElement || jsonData);
        if (el && el.frame) {
          const cx = Math.round(el.frame.X + el.frame.Width / 2);
          const cy = Math.round(el.frame.Y + el.frame.Height / 2);
          if (isPhone && maestro.touchPoint) {
            await maestro.touchPoint(cx, cy);
          } else {
            const pctX = Math.round(cx / (isPhone ? phoneScreenWidth : 402) * 100);
            const pctY = Math.round(cy / (isPhone ? phoneScreenHeight : 874) * 100);
            const header = currentAppId ? `appId: ${currentAppId}\n---\n` : 'appId: any\n---\n';
            await maestro.runFlow(`${header}- tapOn:\n    point: "${pctX}%, ${pctY}%"`);
          }
          return `Tapped "${args.text}" at pixel (${cx}, ${cy})`;
        }
      } catch {}

      // Element not in hierarchy — return immediately so AI can try a different approach
      return `ERROR: Element "${args.text}" not found in view hierarchy. Use getUIElements to see available elements, or use tap with coordinates instead.`;
    }
    case 'inputText': {
      await maestro.inputText(args.text);
      return `Typed "${args.text}"`;
    }
    case 'pressKey': {
      if (isPhone && maestro.pressKey) {
        await maestro.pressKey(args.key);
      } else {
        const header = currentAppId ? `appId: ${currentAppId}\n---\n` : 'appId: any\n---\n';
        await maestro.runFlow(`${header}- pressKey: ${args.key}`);
      }
      return `Pressed ${args.key}`;
    }
    case 'scroll': {
      if (isPhone && maestro.swipe) {
        // Simulate scroll: swipe from center-bottom to center-top
        const midX = Math.round(phoneScreenWidth / 2);
        await maestro.swipe(midX, Math.round(phoneScreenHeight * 0.7), midX, Math.round(phoneScreenHeight * 0.3));
      } else {
        const header = currentAppId ? `appId: ${currentAppId}\n---\n` : 'appId: any\n---\n';
        await maestro.runFlow(`${header}- scroll`);
      }
      return 'Scrolled down';
    }
    case 'swipe': {
      if (isPhone && maestro.swipe) {
        const sx = Math.round((args.startX / 100) * phoneScreenWidth);
        const sy = Math.round((args.startY / 100) * phoneScreenHeight);
        const ex = Math.round((args.endX / 100) * phoneScreenWidth);
        const ey = Math.round((args.endY / 100) * phoneScreenHeight);
        await maestro.swipe(sx, sy, ex, ey);
      } else {
        const header = currentAppId ? `appId: ${currentAppId}\n---\n` : 'appId: any\n---\n';
        await maestro.runFlow(`${header}- swipe:\n    start: "${args.startX}%, ${args.startY}%"\n    end: "${args.endX}%, ${args.endY}%"`);
      }
      return 'Swiped';
    }
    case 'hideKeyboard': {
      // Tap somewhere outside the keyboard to dismiss it
      if (isPhone && maestro.touchPoint) {
        await maestro.touchPoint(Math.round(phoneScreenWidth / 2), 50);
      } else {
        await maestro.runFlow('- hideKeyboard');
      }
      return 'Keyboard hidden';
    }
    case 'typeAndSubmit': {
      // Compound tool: tap field + type + submit in one call
      // Step 1: Tap the text field
      try {
        await executeTool('tapText', { text: args.elementText });
      } catch {
        // Fallback: try tapping by coordinates if text tap fails
      }
      await sleep(500);
      // Step 2: Type the text
      await executeTool('inputText', { text: args.text });
      await sleep(300);
      // Step 3: Submit
      const key = args.submitKey || 'enter';
      if (key === 'send') {
        // iOS Messages: find the send button via hierarchy (position changes when keyboard is open)
        let sendTapped = false;
        try {
          const hier = await maestro.viewHierarchy();
          const hText = hier.text || '';
          const screenW = isPhone ? phoneScreenWidth : 402;
          const screenH = isPhone ? phoneScreenHeight : 874;
          // Search hierarchy for send button (label varies: "Send", "sendButton", arrow icon)
          try {
            const json = JSON.parse(hText);
            function findSend(node) {
              if (!node) return null;
              const label = (node.label || node.identifier || '').toLowerCase();
              if ((label.includes('send') || label === 'arrow.up.circle.fill') && node.frame) return node;
              if (node.children) {
                for (const child of node.children) {
                  const found = findSend(child);
                  if (found) return found;
                }
              }
              return null;
            }
            const sendEl = findSend(json?.axElement || json);
            if (sendEl && sendEl.frame) {
              const cx = Math.round(sendEl.frame.X + sendEl.frame.Width / 2);
              const cy = Math.round(sendEl.frame.Y + sendEl.frame.Height / 2);
              const pctX = Math.round(cx / screenW * 100);
              const pctY = Math.round(cy / screenH * 100);
              console.log(`[typeAndSubmit] Send button found at (${pctX}%, ${pctY}%) — label: "${sendEl.label || sendEl.identifier}"`);
              if (isPhone && maestro.touchPoint) {
                await maestro.touchPoint(cx, cy);
              } else {
                const header = currentAppId ? `appId: ${currentAppId}\n---\n` : 'appId: any\n---\n';
                await maestro.runFlow(`${header}- tapOn:\n    point: "${pctX}%, ${pctY}%"`);
              }
              sendTapped = true;
              await sleep(500); // Wait for send animation to complete
            }
          } catch {}
        } catch {}
        // Fallback: use pressKey enter if hierarchy lookup failed
        if (!sendTapped) {
          console.log('[typeAndSubmit] Send button NOT found in hierarchy — falling back to pressKey enter');
          await executeTool('pressKey', { key: 'enter' });
        }
      } else {
        await executeTool('pressKey', { key });
      }
      return key === 'send'
        ? `Message sent: "${args.text}" — the send button was tapped automatically. Do NOT tap send again. Take a screenshot to verify.`
        : `Typed "${args.text}" into "${args.elementText}" and submitted via ${key}`;
    }
    case 'zoomAndTap': {
      // ZoomClick: crop around rough area, send zoomed image to AI for precise targeting
      // Step 1: Get current screenshot
      const ssResult = await maestro.screenshot();
      const ssBuffer = Buffer.from(ssResult.data, 'base64');

      // Step 2: Crop and zoom
      const zoom = await zoomAndRefine(ssBuffer, args.x, args.y, phoneScreenWidth, phoneScreenHeight);
      const zoomedB64 = zoom.buffer.toString('base64');

      // Step 3: Ask AI for precise coordinates in zoomed view
      const zoomMessages = [
        { role: 'system', content: `You are looking at a ZOOMED-IN portion of a mobile screen. The user wants to tap: "${args.description}". This zoomed view shows the area around (${args.x}%, ${args.y}%) of the full screen. Respond with ONLY a JSON object: {"x": <percentage 0-100 within THIS zoomed image>, "y": <percentage 0-100 within THIS zoomed image>}` },
        { role: 'user', content: [
          { type: 'image_url', image_url: { url: `data:image/png;base64,${zoomedB64}` } },
          { type: 'text', text: `Where exactly is "${args.description}" in this zoomed view? Respond with {"x": N, "y": N} as percentages within this image.` }
        ]}
      ];

      const zoomResp = await fetch(llmConfig.url, {
        method: 'POST',
        headers: { 'Authorization': `Bearer ${apiKey}`, 'Content-Type': 'application/json' },
        body: JSON.stringify({ model: modelName, messages: zoomMessages }),
      });
      const zoomData = await zoomResp.json();
      const zoomText = zoomData.choices?.[0]?.message?.content || '';
      const zoomMatch = zoomText.match(/\{[\s\S]*\}/);

      if (zoomMatch) {
        const zoomCoords = JSON.parse(zoomMatch[0]);
        // Map back to full-screen coordinates
        const fullCoords = zoom.mapBack(zoomCoords.x, zoomCoords.y);
        console.log(`[ZoomClick] Rough (${args.x}%,${args.y}%) → Zoomed (${zoomCoords.x}%,${zoomCoords.y}%) → Final (${fullCoords.x}%,${fullCoords.y}%)`);

        // Execute the tap
        if (isPhone && maestro.touchPoint) {
          const px = Math.round((fullCoords.x / 100) * phoneScreenWidth);
          const py = Math.round((fullCoords.y / 100) * phoneScreenHeight);
          await maestro.touchPoint(px, py);
        } else {
          const header = currentAppId ? `appId: ${currentAppId}\n---\n` : 'appId: any\n---\n';
          await maestro.runFlow(`${header}- tapOn:\n    point: "${fullCoords.x}%, ${fullCoords.y}%"`);
        }
        return `ZoomTapped "${args.description}" at (${fullCoords.x}%, ${fullCoords.y}%) [refined from rough (${args.x}%, ${args.y}%)]`;
      }
      // Fallback: use rough coordinates
      if (isPhone && maestro.touchPoint) {
        const px = Math.round((args.x / 100) * phoneScreenWidth);
        const py = Math.round((args.y / 100) * phoneScreenHeight);
        await maestro.touchPoint(px, py);
      }
      return `Tapped "${args.description}" at rough (${args.x}%, ${args.y}%) [zoom refinement failed]`;
    }

    // === MEMORY ===
    case 'saveMemory': {
      // Defer actual write to after task completion — just queue it
      pendingMemories.push(args.fact);
      console.log(`[Memory] Queued: "${args.fact}" (will save after task completes)`);
      return `Will remember: "${args.fact}"`;
    }
    case 'recallMemory': {
      const memFile = join(import.meta.dirname || '.', 'memories', 'user.md');
      if (existsSync(memFile)) {
        const content = readFileSync(memFile, 'utf-8');
        console.log(`[Memory] Recalled ${content.split('\n').length - 1} facts`);
        return content || '(no memories saved yet)';
      }
      return '(no memories saved yet)';
    }
    case 'recallHistory': {
      const logFile = join(import.meta.dirname || '.', 'logs', 'tasks.jsonl');
      if (existsSync(logFile)) {
        const lines = readFileSync(logFile, 'utf-8').trim().split('\n');
        const recent = lines.slice(-10).map(l => {
          const e = JSON.parse(l);
          return `[${e.timestamp.split('T')[0]}] "${e.task}" — ${e.success ? 'completed' : 'failed'} in ${e.steps} steps (${e.time}s)`;
        }).join('\n');
        console.log(`[History] Recalled ${lines.length} tasks`);
        return `Recent task history:\n${recent}`;
      }
      return '(no task history yet)';
    }

    // === WEB SEARCH ===
    case 'webSearch': {
      const braveKey = process.env.BRAVE_API_KEY;
      if (!braveKey) {
        return 'ERROR: BRAVE_API_KEY not set in .env. Cannot perform web search.';
      }
      try {
        const url = new URL('https://api.search.brave.com/res/v1/web/search');
        url.searchParams.set('q', args.query);
        url.searchParams.set('count', '5');
        const res = await fetch(url, {
          headers: {
            'Accept': 'application/json',
            'Accept-Encoding': 'gzip',
            'X-Subscription-Token': braveKey,
          },
        });
        if (!res.ok) {
          return `ERROR: Brave Search API returned ${res.status}`;
        }
        const data = await res.json();
        const results = (data.web?.results ?? []).slice(0, 5);
        if (results.length === 0) return 'No search results found.';
        const formatted = results.map((r, i) => `${i + 1}. ${r.title}\n   ${r.url}\n   ${r.description || ''}`).join('\n\n');
        console.log(`[WebSearch] "${args.query}" → ${results.length} results`);
        return `Web search results for "${args.query}":\n\n${formatted}`;
      } catch (e) {
        return `ERROR: Web search failed: ${e.message}`;
      }
    }

    // === HUMAN-IN-THE-LOOP ===
    case 'askUser': {
      console.log(`[askUser] "${args.question}" — options: ${args.options.join(', ')}`);

      // Signal the question via stdout so the server can parse it and update agentState
      console.log(`__ASK_USER__:${JSON.stringify({ question: args.question, options: args.options })}`);
      console.log(`[askUser] Waiting for user response...`);

      // Wait for a response file (server writes it when user responds)
      const responseFile = join(tmpdir(), 'agent-user-response.json');
      try { unlinkSync(responseFile); } catch {}

      const userChoice = await new Promise((resolve) => {
        const interval = setInterval(() => {
          try {
            const data = readFileSync(responseFile, 'utf-8');
            const { choice } = JSON.parse(data);
            clearInterval(interval);
            try { unlinkSync(responseFile); } catch {}
            resolve(choice);
          } catch {
            // File doesn't exist yet — keep waiting
          }
        }, 500);
      });

      console.log(`[askUser] User responded: "${userChoice}"`);
      return `User chose: "${userChoice}"`;
    }

    // === COMPLETION ===
    case 'taskComplete': return `__DONE__:${args.summary}`;
    case 'taskFailed': return `__FAILED__:${args.reason}`;
    default: return `Unknown tool: ${name}`;
  }
}

// ─── LLM API call (supports OpenAI + Gemini via OpenAI-compatible endpoint) ───
async function callLLM(messages) {
  const resp = await fetch(llmConfig.url, {
    method: 'POST',
    headers: { 'Authorization': `Bearer ${apiKey}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ model: modelName, messages, tools: openaiTools, tool_choice: 'auto' }),
  });
  if (!resp.ok) {
    const err = await resp.text();
    throw new Error(`API error ${resp.status}: ${err.slice(0, 200)}`);
  }
  return await resp.json();
}

// ─── Load persistent memory ───
const memDir = join(import.meta.dirname || '.', 'memories');
let memoryContext = '';
try {
  const memFile = join(memDir, 'user.md');
  if (existsSync(memFile)) {
    const content = readFileSync(memFile, 'utf-8').trim();
    if (content && content !== '# User Memory') {
      memoryContext = content;
      console.log(`[Memory] Loaded ${content.split('\n').length - 1} facts`);
    }
  }
} catch {}

// ─── System prompt ───
const systemPrompt = `<SYSTEM_CAPABILITY>
* You are an AI agent controlling an iPhone 15 Pro running iOS 26 (latest, with Liquid Glass design).
* You see real iOS screenshots and interact with native iOS apps via tool calls.
* You understand iOS UI patterns: translucent navigation bars at top, tab bars at bottom, swipe gestures, modal sheets, the status bar, the home indicator, and standard Apple app layouts.
* Coordinates are PERCENTAGES (0-100), NOT pixels. x=0 is left edge, x=100 is right edge, y=0 is top, y=100 is bottom.
* After EVERY action, take a screenshot to verify it worked before moving on. If it didn't work, try a different approach.
* ALWAYS chain multiple tool calls in a single response when they are independent. For example: openApp + takeScreenshot, saveMemory + tapText, tapText + inputText. Do NOT make one tool call per response when you can batch them. This is critical for speed.
* The current date is ${new Date().toLocaleDateString()}.
</SYSTEM_CAPABILITY>

${memoryContext ? `<USER_MEMORY>
${memoryContext}
Use these facts when relevant. Save new facts with saveMemory.
</USER_MEMORY>

` : ''}<AVAILABLE_APPS>
${appListStr}
</AVAILABLE_APPS>

<STRATEGY>
${isPhone ? `1. Use openApp to launch the right app for the task.
2. Every screenshot automatically includes UI elements with exact coordinates. Use these coordinates with tap(x, y) for precise tapping — do NOT guess coordinates from the screenshot.
3. If you need to refresh UI elements without a screenshot, call getUIElements.
4. After completing actions: takeScreenshot to VERIFY the task is actually done, then taskComplete.
NOTE: This is a PHYSICAL iPhone. Deep link shortcuts (searchMaps, googleSearch, openURL) will open the app but you must then navigate the UI manually.`
: `1. Use INSTANT tools when possible: searchMaps, googleSearch, openURL, getDirections, composeMessage, setAppearance, setLocation. These complete in one step.
2. Every screenshot automatically includes UI elements with exact coordinates. Use these coordinates with tap(x, y) for precise tapping — do NOT guess coordinates from the screenshot.
3. If you need to refresh UI elements without a screenshot, call getUIElements.
4. Use takeScreenshot only when you need to visually verify the result.
5. After instant tools or completing actions: takeScreenshot to verify, then taskComplete.`}
</STRATEGY>

<IMPORTANT>
* iOS Messages: the SEND button is a BLUE UP-ARROW circle INSIDE the text input bar on the far right. Its position changes when the keyboard is open — always use coordinates from the auto-bundled UI elements, NOT hardcoded values. Do NOT tap the text effects/formatting button. To message a specific contact, find their existing conversation first — do NOT tap "New Message" unless they have no existing thread.
* iOS Photos: the MOST RECENT photo/image is at the BOTTOM-RIGHT of the grid. Scroll DOWN first if needed.
* iOS Maps: the search bar is at the BOTTOM of the screen, not the top.
* If the same action fails 2 times with no change, your coordinates are WRONG. Check the UI elements list bundled with the screenshot for exact coordinates, or scroll to reveal hidden elements, or try a completely different approach.
</IMPORTANT>

<RULES>
${isPhone ? '- Use openApp to launch apps, then navigate UI with tap/tapText/inputText' : '- Prefer instant tools over tapping'}
- Prefer using tap(x, y) with coordinates from the auto-bundled UI elements list. These coordinates come directly from the view hierarchy and are exact.
- Use tapText when you know the exact accessibility text. Use getUIElements only if you need to refresh the element list without taking a screenshot.
- BEFORE calling taskComplete, you MUST takeScreenshot and verify the task is actually done on screen.
- SCREEN UNDERSTANDING (do this BEFORE every action on a new or changed screen): (1) Describe what app/screen you see, (2) Read ALL visible text — especially instructions, labels, and placeholders, (3) Identify interactive elements — text fields, buttons, toggles — from the UI elements list, (4) Determine the correct interaction: should you tap, type, scroll, or something else? Only THEN choose your action. This is critical for unfamiliar apps, games, and non-standard interfaces.
- UNFAMILIAR APPS: If after reading the screen you still don't understand how to interact, use webSearch to look up how the app works BEFORE acting. Do NOT blindly tap UI elements.
- WEB SEARCH: For factual information (weather, scores, prices, news, how-to, definitions), ALWAYS use webSearch first — it returns results in 0.6s without leaving the current app. Do NOT open Safari, Weather, or any other app just to look up information that webSearch can provide. Only navigate to an app when the task requires YOUR personal data (your calendar, your photos, your messages, your contacts) that isn't available on the web. NEVER open result URLs on the device — read the search results from the tool response.
- CRITICAL — askUser RULES: The user's command IS the confirmation. If they said "text Emiliano hello", JUST DO IT — do NOT ask "do you want to send this?" Only call askUser when: (1) contact is ambiguous (multiple people match), (2) purchases or payments, (3) deleting data, (4) the task is genuinely vague and you need clarification. NEVER re-confirm an explicit command. NEVER parrot the task back as a question.
- MEMORY: When you learn something new about the user (preferred contact, address, preference), call saveMemory to persist it. After askUser resolves ambiguity, ALWAYS saveMemory with the result so you never ask the same question twice. IMPORTANT: Always bundle saveMemory with another action tool in the same response — never use an entire step just to save memory.${grounding === 'grid' ? `
- GRID OVERLAY: The screenshot has yellow grid lines at every 10% with labels at 20%, 40%, 60%, 80%. Use these to estimate tap coordinates accurately.` : ''}${grounding === 'zoomclick' ? `
- ZOOM TAP: When you need to tap a SMALL icon or when elements are close together, use zoomAndTap instead of tap for precise targeting.` : ''}
</RULES>${agentMode === 'vision-gated' ? `

<VISION_GATE>
Screenshots are only allowed when the screen content changes (detected via UI hierarchy hashing), on step 1, after errors, when stuck, or every ${visionEveryK} steps as a safety fallback. If your takeScreenshot call is denied, use getUIElements instead. Save takeScreenshot for verifying task completion.
</VISION_GATE>` : ''}`;

// ─── Hierarchy helpers (for hash-based vision gate) ───
const hierarchyNoise = ['scroll bar', 'battery', 'Cellular', 'Wi-Fi bars', 'PM', 'AM', 'No signal', 'Not charging', 'signal strength', 'battery power', 'location services', 'Location tracking'];

function flattenHierarchy(text) {
  const labels = [];
  // Try JSON format first
  try {
    const json = JSON.parse(text);
    function collect(node) {
      if (!node) return;
      if (node.label && node.label.trim()) {
        const l = node.label.trim();
        if (!hierarchyNoise.some(n => l.includes(n)) && !labels.includes(l)) labels.push(l);
      }
      if (node.children) node.children.forEach(collect);
    }
    collect(json?.axElement || json);
    if (labels.length > 0) return labels;
  } catch {}
  // Fall back to CSV/regex
  for (const m of text.matchAll(/accessibilityText[="] *:? *"?([^";,\n]+)/g)) {
    const label = m[1].trim();
    if (!label) continue;
    if (hierarchyNoise.some(n => label.includes(n))) continue;
    if (!labels.includes(label)) labels.push(label);
  }
  return labels;
}

function hashLabels(labels) {
  return [...labels].sort().join('|');
}

// ─── Agent loop ───
const messages = [
  { role: 'system', content: systemPrompt },
  { role: 'user', content: task },
];
const totalStart = Date.now();

console.log(`\n${'='.repeat(50)}`);
console.log(`  Task:      ${task}`);
console.log(`  Model:     ${modelName} (${provider})`);
console.log(`  Max Steps: ${maxSteps}`);
console.log(`  Apps:      ${Object.keys(appMap).length} detected`);
console.log(`  Device:    ${isPhone ? 'Physical iPhone' : 'iOS Simulator'}`);
console.log(`  Grounding: ${grounding}${useCompression ? ' + compress' : ''}`);
const modeLabel = agentMode === 'baseline' ? '(all screenshots kept)'
  : agentMode === 'vision-gated' ? `(vision gated, hash-based + every ${visionEveryK} steps fallback)`
  : '(single image + rolling summary)';
console.log(`  Mode:      ${agentMode} ${modeLabel}`);
console.log(`${'='.repeat(50)}\n`);

const stepLog = [];
const recentActions = [];
const rollingSummary = [];
const pendingMemories = [];
let visionSteps = 0;
let gatedSteps = 0;
let prevScreenHash = null;
let currentUILabels = [];
let prevAutoUICount = -1;
let unchangedScreenCount = 0;

for (let step = 1; step <= maxSteps; step++) {
  // Stuck detection (exact match OR same tool with similar coordinates)
  let stuckThisStep = false;
  if (recentActions.length >= 3) {
    const last3 = recentActions.slice(-3);
    // Exact match
    if (last3.every(a => a === last3[0])) {
      stuckThisStep = true;
    }
    // Semantic match: same tool name, coordinates within 10% of each other
    if (!stuckThisStep) {
      try {
        const parsed = last3.map(a => {
          const m = a.match(/^(\w+)\((.+)\)$/);
          return m ? { tool: m[1], args: JSON.parse(m[2]) } : null;
        });
        if (parsed.every(p => p && p.tool === parsed[0].tool)) {
          // Same tool 3 times — check if coordinates are clustered
          if (parsed[0].args.x !== undefined && parsed[0].args.y !== undefined) {
            const xs = parsed.map(p => p.args.x);
            const ys = parsed.map(p => p.args.y);
            if (Math.max(...xs) - Math.min(...xs) <= 10 && Math.max(...ys) - Math.min(...ys) <= 10) {
              stuckThisStep = true;
            }
          }
          // Same tapText target
          if (parsed[0].tool === 'tapText' && parsed.every(p => p.args.text === parsed[0].args.text)) {
            stuckThisStep = true;
          }
        }
      } catch {}
    }
    if (stuckThisStep) {
      messages.push({ role: 'user', content: `WARNING: You have repeated similar actions 3 times with no progress. Your coordinates or element text may be WRONG. Try: 1) getUIElements to see what is actually on screen with exact coordinates, 2) tap with coordinates from getUIElements, 3) a completely different approach.` });
    }
  }

  // Vision gate: decide if screenshots are allowed this step
  let visionAllowed = true;
  if (agentMode === 'vision-gated') {
    const hashChanged = prevScreenHash === null || hashLabels(currentUILabels) !== prevScreenHash;
    const emptyHierarchy = currentUILabels.length === 0;
    visionAllowed = (step === 1) || emptyHierarchy || hashChanged || stuckThisStep || (step % visionEveryK === 0);
    if (step > 1) {
      console.log(`[Vision Gate] hash ${hashChanged ? 'CHANGED' : 'same'} | ${currentUILabels.length} labels | ${visionAllowed ? 'VISION' : 'GATED'}`);
    }
  }

  const stepStart = Date.now();
  const elapsed = ((Date.now() - totalStart) / 1000).toFixed(1);
  const entry = { step, aiTime: 0, tools: [] };
  console.log(`\n--- Step ${step}/${maxSteps} (${elapsed}s total) ---`);

  // Inject rolling summary + UI labels as context (single-image and vision-gated modes)
  if ((agentMode === 'single-image' || agentMode === 'vision-gated') && (rollingSummary.length > 0 || currentUILabels.length > 0)) {
    // Remove previous context message if one exists
    const prevIdx = messages.findIndex(m => m.role === 'user' && typeof m.content === 'string' && m.content.startsWith('[Context]'));
    if (prevIdx !== -1) messages.splice(prevIdx, 1);
    // Build context with summary + current screen labels
    let ctx = '';
    if (rollingSummary.length > 0) ctx += `Action history:\n${rollingSummary.join('\n')}`;
    if (currentUILabels.length > 0) ctx += `${ctx ? '\n\n' : ''}Current screen elements:\n${currentUILabels.map(l => `- "${l}"`).join('\n')}`;
    messages.splice(2, 0, { role: 'user', content: `[Context] ${ctx}` });
  }

  // Call LLM
  const aiStart = Date.now();
  console.log(`[AI] Sending to ${modelName}...`);
  let data;
  try {
    data = await callLLM(messages);
  } catch (e) {
    console.log(`[AI] ERROR: ${e.message}`);
    await sleep(2000);
    continue;
  }

  const msg = data.choices?.[0]?.message;
  if (!msg) { console.log('[AI] No response'); continue; }

  entry.aiTime = (Date.now() - aiStart) / 1000;
  console.log(`[AI] Responded in ${entry.aiTime.toFixed(1)}s | Tokens: ${data.usage?.prompt_tokens ?? '?'} in / ${data.usage?.completion_tokens ?? '?'} out`);

  if (msg.content) console.log(`[AI] ${msg.content.slice(0, 200)}`);

  // Process tool calls
  if (msg.tool_calls && msg.tool_calls.length > 0) {
    messages.push(msg);

    let needsScreenshot = false;
    let needsSettleDelay = false;
    let isDone = false;
    let isFailed = false;
    let doneMsg = '';
    let errorThisStep = false;

    for (const tc of msg.tool_calls) {
      const toolName = tc.function.name;
      const toolArgs = JSON.parse(tc.function.arguments);
      const actionKey = `${toolName}(${JSON.stringify(toolArgs)})`;
      console.log(`[Tool] ${actionKey}`);
      recentActions.push(actionKey);
      if (recentActions.length > 10) recentActions.shift();

      let result;
      const execStart = Date.now();
      try {
        result = await executeTool(toolName, toolArgs);
        const execMs = Date.now() - execStart;
        const execTime = (execMs / 1000).toFixed(1);

        if (result === '__SCREENSHOT__') {
          // Vision gate: check if screenshot is allowed this step
          const hasTaskComplete = msg.tool_calls.some(t => t.function.name === 'taskComplete');
          const gateOverride = hasTaskComplete || errorThisStep;
          if (agentMode === 'vision-gated' && !visionAllowed && !gateOverride) {
            needsScreenshot = false;
            result = '[Vision gated] Screenshot skipped this step. Use getUIElements to see what is on screen instead.';
            entry.tools.push({ name: toolName, time: execMs / 1000, gated: true });
            entry.visionGated = true;
            gatedSteps++;
            console.log(`[Tool] → takeScreenshot GATED (step ${step}, next vision at step ${Math.ceil(step / visionEveryK) * visionEveryK})`);
          } else {
            needsScreenshot = true;
            result = 'Screenshot taken';
            entry.tools.push({ name: toolName, time: execMs / 1000 });
            if (agentMode === 'vision-gated') visionSteps++;
            console.log(`[Tool] → takeScreenshot (${execTime}s)`);
          }
        } else if (result.startsWith('__DONE__:')) {
          isDone = true;
          doneMsg = result.slice(9);
          result = doneMsg;
          console.log(`[Tool] → DONE: ${doneMsg}`);
        } else if (result.startsWith('__FAILED__:')) {
          isFailed = true;
          doneMsg = result.slice(11);
          result = doneMsg;
          console.log(`[Tool] → FAILED: ${doneMsg}`);
        } else {
          entry.tools.push({ name: toolName, time: execMs / 1000 });
          // Don't log full UI element lists — too noisy
          if (toolName === 'getUIElements') {
            const count = (result.match(/^- "/gm) || []).length;
            console.log(`[Tool] → Found ${count} elements (${execTime}s)`);
          } else {
            console.log(`[Tool] → ${result} (${execTime}s)`);
          }
          // Auto-capture: action tools automatically trigger a screenshot
          const actionTools = ['openApp', 'tap', 'tapText', 'inputText', 'pressKey', 'scroll', 'swipe', 'typeAndSubmit', 'hideKeyboard'];
          if (actionTools.includes(toolName) && !needsScreenshot) {
            needsScreenshot = true;
            // Track if this was a navigation action (needs settle delay for iOS animations)
            const navActions = ['tap', 'tapText', 'scroll', 'swipe', 'typeAndSubmit'];
            if (navActions.includes(toolName)) needsSettleDelay = true;
            console.log(`[Auto-capture] Screenshot queued after ${toolName}`);
          }
        }
      } catch (e) {
        const execMs = Date.now() - execStart;
        result = `Error: ${e.message}`;
        entry.tools.push({ name: toolName, time: execMs / 1000, error: true });
        errorThisStep = true;
        console.log(`[Tool] → ERROR: ${e.message} (${(execMs / 1000).toFixed(1)}s)`);
      }

      messages.push({ role: 'tool', tool_call_id: tc.id, content: result });
    }

    // Build rolling summary for this step
    if (agentMode === 'single-image' || agentMode === 'vision-gated') {
      const toolSummaries = msg.tool_calls.map(tc => {
        const name = tc.function.name;
        const args = JSON.parse(tc.function.arguments);
        const argStr = Object.values(args).map(v => typeof v === 'string' ? v : JSON.stringify(v)).join(', ');
        return argStr ? `${name}(${argStr.slice(0, 60)})` : name;
      });
      rollingSummary.push(`Step ${step}: ${toolSummaries.join(', ')}`);
    }

    if (isDone) {
      stepLog.push(entry);
      const totalTime = ((Date.now() - totalStart) / 1000).toFixed(1);
      const totalAI = stepLog.reduce((a, s) => a + s.aiTime, 0);
      const totalTools = stepLog.reduce((a, s) => a + s.tools.reduce((b, t) => b + t.time, 0), 0);
      const totalSS = stepLog.reduce((a, s) => a + (s.screenshotTime || 0), 0);
      console.log(`\n${'='.repeat(50)}`);
      console.log(`  ✅ TASK COMPLETED`);
      console.log(`  ${doneMsg}`);
      console.log(`${'─'.repeat(50)}`);
      console.log(`  Total time:    ${totalTime}s`);
      console.log(`  Steps:         ${step}`);
      console.log(`  AI time:       ${totalAI.toFixed(1)}s (${((totalAI / parseFloat(totalTime)) * 100).toFixed(0)}%)`);
      console.log(`  Tool time:     ${totalTools.toFixed(1)}s (${((totalTools / parseFloat(totalTime)) * 100).toFixed(0)}%)`);
      console.log(`  Screenshot:    ${totalSS.toFixed(1)}s (${((totalSS / parseFloat(totalTime)) * 100).toFixed(0)}%)`);
      console.log(`  Overhead:      ${(parseFloat(totalTime) - totalAI - totalTools - totalSS).toFixed(1)}s`);
      if (agentMode === 'vision-gated') {
        console.log(`${'─'.repeat(50)}`);
        console.log(`  Vision calls:  ${visionSteps}`);
        console.log(`  Gated calls:   ${gatedSteps}`);
        console.log(`  Vision rate:   ${visionSteps + gatedSteps > 0 ? ((visionSteps / (visionSteps + gatedSteps)) * 100).toFixed(0) : 0}%`);
      }
      console.log(`${'='.repeat(50)}`);
      // Log task to history
      try {
        const logDir = join(import.meta.dirname || '.', 'logs');
        mkdirSync(logDir, { recursive: true });
        const logEntry = JSON.stringify({ timestamp: new Date().toISOString(), task, summary: doneMsg, steps: step, time: totalTime, success: true, mode: agentMode, grounding, model: modelName, provider }) + '\n';
        const logFile = join(logDir, 'tasks.jsonl');
        const existing = existsSync(logFile) ? readFileSync(logFile, 'utf-8') : '';
        writeFileSync(logFile, existing + logEntry);
        console.log(`[History] Task logged`);
      } catch {}
      // Flush pending memories to disk
      if (pendingMemories.length > 0) {
        try {
          const memDir = join(import.meta.dirname || '.', 'memories');
          const memFile = join(memDir, 'user.md');
          mkdirSync(memDir, { recursive: true });
          const timestamp = new Date().toISOString().split('T')[0];
          const existing = existsSync(memFile) ? readFileSync(memFile, 'utf-8') : '# User Memory\n';
          const newEntries = pendingMemories.map(f => `- [${timestamp}] ${f}`).join('\n');
          writeFileSync(memFile, existing + newEntries + '\n');
          console.log(`[Memory] Saved ${pendingMemories.length} facts to disk`);
        } catch {}
      }
      process.exit(0);
    }

    if (isFailed) {
      const totalTime = ((Date.now() - totalStart) / 1000).toFixed(1);
      console.log(`\n${'='.repeat(50)}`);
      console.log(`  ❌ TASK FAILED (${totalTime}s)`);
      console.log(`  ${doneMsg}`);
      console.log(`${'='.repeat(50)}`);
      // Log failed task to history
      try {
        const logDir = join(import.meta.dirname || '.', 'logs');
        mkdirSync(logDir, { recursive: true });
        const logEntry = JSON.stringify({ timestamp: new Date().toISOString(), task, reason: doneMsg, steps: step, time: totalTime, success: false, mode: agentMode, grounding, model: modelName, provider }) + '\n';
        const logFile = join(logDir, 'tasks.jsonl');
        const existing = existsSync(logFile) ? readFileSync(logFile, 'utf-8') : '';
        writeFileSync(logFile, existing + logEntry);
        console.log(`[History] Task logged`);
      } catch {}
      process.exit(1);
    }

    // Settle delay: only after navigation actions (tap, scroll, swipe) on physical device
    // openApp, inputText, pressKey don't trigger iOS transition animations
    if (needsScreenshot && isPhone && needsSettleDelay) {
      await sleep(350); // iOS animations: nav push 330ms, keyboard 250ms, modals 350ms
    }
    if (needsScreenshot) {
      // In single-image/vision-gated mode, strip old screenshots so only the latest image is sent
      if (agentMode === 'single-image' || agentMode === 'vision-gated') {
        for (let i = 0; i < messages.length; i++) {
          const m = messages[i];
          if (Array.isArray(m.content) && m.content.some(c => c.type === 'image_url')) {
            const textParts = m.content.filter(c => c.type === 'text').map(c => c.text).join(' ');
            const summaryCtx = rollingSummary.length > 0 ? ` | Context: ${rollingSummary[rollingSummary.length - 1]}` : '';
            messages[i] = { role: m.role, content: `[Previous screenshot${summaryCtx}] ${textParts}` };
          }
        }
      }
      try {
        const ssStart = Date.now();

        // Run screenshot and hierarchy fetch in parallel (both are independent HTTP calls)
        const screenshotPromise = (async () => {
          let buffer;
          if (isPhone) {
            const ssResult = await maestro.screenshot();
            buffer = Buffer.from(ssResult.data, 'base64');
          } else {
            const p = join(tmpdir(), `screen-${Date.now()}.png`);
            await runShell(`xcrun simctl io booted screenshot "${p}"`, 10000);
            buffer = readFileSync(p);
            try { unlinkSync(p); } catch {}
          }
          if (useCompression) {
            try {
              const sharp = (await import('sharp')).default;
              const metadata = await sharp(buffer).metadata();
              if (metadata.width > 768) {
                buffer = await sharp(buffer).resize(768, null, { fit: 'inside' }).jpeg({ quality: 85 }).toBuffer();
              }
            } catch {}
          }
          if (grounding === 'grid') {
            try { buffer = await addGridOverlay(buffer); } catch (e) { console.log(`[Grid] Overlay failed: ${e.message}`); }
          }
          return buffer;
        })();

        const hierarchyPromise = (async () => {
          try {
            const hierResult = await maestro.viewHierarchy();
            const hText = hierResult.text || '';
            const uiNoise = ['scroll bar', 'battery', 'Cellular', 'Wi-Fi bars', 'PM', 'AM', 'No signal', 'Not charging', 'signal strength', 'battery power', 'location services', 'Location tracking'];
            const elems = [];
            const sw = isPhone ? phoneScreenWidth : 402;
            const sh = isPhone ? phoneScreenHeight : 874;
            try {
              const json = JSON.parse(hText);
              function collectAuto(node) {
                if (!node) return;
                if (node.label && node.label.trim()) {
                  const label = node.label.trim();
                  if (!uiNoise.some(n => label.includes(n))) {
                    let e;
                    if (node.frame) {
                      const px = Math.round((node.frame.X + node.frame.Width / 2) / sw * 100);
                      const py = Math.round((node.frame.Y + node.frame.Height / 2) / sh * 100);
                      e = `- "${label}" at (${px}%, ${py}%)`;
                    } else {
                      e = `- "${label}"`;
                    }
                    if (!elems.some(f => f.startsWith(`- "${label}"`))) elems.push(e);
                  }
                }
                if (node.children) node.children.forEach(collectAuto);
              }
              collectAuto(json?.axElement || json);
            } catch {
              const boundsRe = /\[(\d+),(\d+)\]\[(\d+),(\d+)\]/;
              for (const line of hText.split('\n')) {
                const lm = line.match(/accessibilityText[="] *:? *"?([^";,\n]+)/);
                if (!lm) continue;
                const label = lm[1].trim();
                if (!label || uiNoise.some(n => label.includes(n))) continue;
                const bm = line.match(boundsRe);
                let e;
                if (bm) {
                  const px = Math.round(((parseInt(bm[1]) + parseInt(bm[3])) / 2) / sw * 100);
                  const py = Math.round(((parseInt(bm[2]) + parseInt(bm[4])) / 2) / sh * 100);
                  e = `- "${label}" at (${px}%, ${py}%)`;
                } else {
                  e = `- "${label}"`;
                }
                if (!elems.some(f => f.startsWith(`- "${label}"`))) elems.push(e);
              }
            }
            if (elems.length > 0) {
              console.log(`[Auto-UI] ${elems.length} elements bundled with screenshot`);
              return `\n\nUI elements on screen:\n${elems.join('\n')}\nUse tap(x, y) with coordinates above for precise tapping.`;
            }
          } catch (e) {
            console.log(`[Auto-UI] Hierarchy fetch failed: ${e.message}`);
          }
          return '';
        })();

        const [buffer, uiElementsText] = await Promise.all([screenshotPromise, hierarchyPromise]);
        const b64 = buffer.toString('base64');
        const ssTime = ((Date.now() - ssStart) / 1000).toFixed(1);
        entry.screenshotTime = (Date.now() - ssStart) / 1000;
        console.log(`[Screenshot] OK (${Math.round(buffer.length / 1024)} KB, ${ssTime}s${useCompression ? ' +compressed' : ''}${grounding === 'grid' ? ' +grid' : ''})`);

        // Unchanged screen detection: if element count is identical for 3 steps, agent may not understand the app
        const currentAutoUICount = (uiElementsText.match(/^- "/gm) || []).length;
        let unchangedWarning = '';
        if (currentAutoUICount > 0 && currentAutoUICount === prevAutoUICount) {
          unchangedScreenCount++;
          if (unchangedScreenCount >= 3) {
            unchangedWarning = '\n\nWARNING: The screen has NOT changed after 3 actions — your taps are having no effect. You may not understand how this app or screen works. STOP tapping and try: 1) Read ALL text on screen carefully for instructions, 2) Use webSearch to look up how this app/game works, 3) Look for text fields or buttons you may have missed.';
            console.log(`[Unchanged] Screen unchanged for ${unchangedScreenCount} steps — suggesting webSearch`);
            unchangedScreenCount = 0; // Reset after warning
          }
        } else {
          unchangedScreenCount = 0;
        }
        prevAutoUICount = currentAutoUICount;

        messages.push({
          role: 'user',
          content: [
            { type: 'image_url', image_url: { url: `data:image/png;base64,${b64}` } },
            { type: 'text', text: `Here is the current screen. Continue with the task.${uiElementsText}${unchangedWarning}` },
          ],
        });
      } catch (e) {
        console.log(`[Screenshot] FAILED: ${e.message}`);
        messages.push({ role: 'user', content: 'Screenshot failed. Try a different approach.' });
      }
    }
  } else {
    messages.push(msg);
    messages.push({ role: 'user', content: 'Please use the available tools to complete the task.' });
  }

  // Auto-fetch hierarchy for hash-based vision gate (next step's decision)
  if (agentMode === 'vision-gated') {
    try {
      const hierResult = await maestro.viewHierarchy();
      const labels = flattenHierarchy(hierResult.text || '');
      prevScreenHash = hashLabels(currentUILabels); // save current as previous before updating
      currentUILabels = labels;
    } catch {
      prevScreenHash = hashLabels(currentUILabels);
      currentUILabels = []; // empty = force vision next step
    }
  }

  const stepTime = ((Date.now() - stepStart) / 1000).toFixed(1);
  stepLog.push(entry);
  const toolTotal = entry.tools.reduce((a, t) => a + t.time, 0).toFixed(1);
  const visionTag = agentMode === 'vision-gated' ? (entry.visionGated ? ' | GATED' : entry.screenshotTime ? ' | VISION' : '') : '';
  console.log(`[Step ${step}] ${stepTime}s (AI: ${entry.aiTime.toFixed(1)}s | Tools: ${toolTotal}s${entry.screenshotTime ? ` | Screenshot: ${entry.screenshotTime.toFixed(1)}s` : ''}${visionTag})`);
  await sleep(500);
}

const totalTime = ((Date.now() - totalStart) / 1000).toFixed(1);
console.log(`\n${'='.repeat(50)}`);
console.log(`  ⏱️  MAX STEPS REACHED (${totalTime}s)`);
console.log(`${'='.repeat(50)}`);
process.exit(1);
