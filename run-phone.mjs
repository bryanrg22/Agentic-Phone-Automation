#!/usr/bin/env node
/**
 * AI agent runner for PHYSICAL iPhone
 * Requires maestro-ios-device bridge running in another terminal.
 *
 * Usage:
 *   Terminal 1: maestro-ios-device --team-id C924TNC23B --device 00008130-0008249124C1401C
 *   Terminal 2: node run-phone.mjs com.apple.Maps "Search for USC" --max-steps 10
 */
import 'dotenv/config';
import { exec } from 'child_process';
import { writeFileSync, readFileSync, unlinkSync, existsSync } from 'fs';
import { tmpdir } from 'os';
import { join } from 'path';

// ─── Config ───
const DEVICE_ID = '00008130-0008249124C1401C';
const DRIVER_PORT = 6001;

// ─── Parse args ───
const args = process.argv.slice(2);
const bundleId = args[0];
const task = args[1];
const maxSteps = parseInt(args.find((_, i) => args[i - 1] === '--max-steps') || '10');
const model = args.find((_, i) => args[i - 1] === '--model') || 'gemini-2.5-flash-lite';

if (!task) {
  console.log('Usage: node run-phone.mjs <bundleId> "task" [--max-steps N] [--model MODEL]');
  console.log('\nMake sure maestro-ios-device bridge is running in another terminal!');
  process.exit(1);
}

const apiKey = process.env.GEMINI_API_KEY;
if (!apiKey) { console.log('ERROR: Set GEMINI_API_KEY (https://aistudio.google.com/apikey)'); process.exit(1); }

const GEMINI_OPENAI_COMPAT_URL = 'https://generativelanguage.googleapis.com/v1beta/openai/chat/completions';

// ─── Helpers ───
const sleep = (ms) => new Promise(r => setTimeout(r, ms));

function runMaestro(yaml) {
  const flowPath = join(tmpdir(), `maestro-flow-${Date.now()}.yaml`);
  writeFileSync(flowPath, yaml);
  const cmd = `maestro --driver-host-port ${DRIVER_PORT} --device ${DEVICE_ID} test ${flowPath}`;
  return new Promise((resolve, reject) => {
    exec(cmd, { timeout: 60000 }, (error) => {
      try { unlinkSync(flowPath); } catch {}
      if (error) reject(new Error(`Maestro: ${error.message.slice(0, 200)}`));
      else resolve();
    });
  });
}

function screenshot() {
  // For physical device, use Maestro's takeScreenshot
  const name = `screen-${Date.now()}`;
  const flowPath = join(tmpdir(), `maestro-ss-${Date.now()}.yaml`);
  const ssDir = join(tmpdir(), `maestro-ss-dir-${Date.now()}`);

  return new Promise((resolve, reject) => {
    const { mkdirSync, readdirSync } = require('fs');
    mkdirSync(ssDir, { recursive: true });

    // Use xcrun for screenshot via the device - try devicectl first
    exec(`xcrun devicectl device process launch --device ${DEVICE_ID} --terminate-existing com.apple.Maps 2>/dev/null; sleep 0.1`, () => {});

    // Actually, take screenshot via Maestro
    const yaml = `appId: ${bundleId}\n---\n- takeScreenshot: ${name}`;
    writeFileSync(flowPath, yaml);
    const cmd = `maestro --driver-host-port ${DRIVER_PORT} --device ${DEVICE_ID} test ${flowPath}`;
    exec(cmd, { timeout: 30000, cwd: ssDir }, (error) => {
      try { unlinkSync(flowPath); } catch {}

      // Find the screenshot
      try {
        const files = readdirSync(ssDir);
        const ssFile = files.find(f => f.endsWith('.png'));
        if (ssFile) {
          const buffer = readFileSync(join(ssDir, ssFile));
          // Cleanup
          try { files.forEach(f => unlinkSync(join(ssDir, f))); require('fs').rmdirSync(ssDir); } catch {}
          resolve(buffer);
          return;
        }
      } catch {}

      // Fallback: check maestro tests dir for latest screenshot
      try {
        const testsDir = join(require('os').homedir(), '.maestro', 'tests');
        const dirs = readdirSync(testsDir).sort().reverse();
        for (const dir of dirs) {
          const testFiles = readdirSync(join(testsDir, dir));
          const png = testFiles.find(f => f.endsWith('.png'));
          if (png) {
            const buffer = readFileSync(join(testsDir, dir, png));
            resolve(buffer);
            return;
          }
        }
      } catch {}

      reject(new Error('Screenshot not found'));
    });
  });
}

// Build system prompt
function buildPrompt(task, step, maxSteps, history) {
  return `You are an AI agent controlling a PHYSICAL iPhone to complete a task.

OBJECTIVE: ${task}

COORDINATE ESTIMATION GUIDE
Estimate tap positions as PERCENTAGES (0-100):
- 0% = left/top edge, 50% = center, 100% = right/bottom edge

ACTION PRIORITY
1. tapText - BEST when you see readable text on a button. Use EXACT visible text.
2. tap - For icons or when tapText might fail. Estimate coordinates carefully.
3. inputText - ONLY after tapping a text field (you should see cursor/keyboard)
4. scroll - To reveal content below the fold

AVAILABLE ACTIONS
tap: {"action":"tap","params":{"x":50,"y":50},"reasoning":"...","progress":N}
tapText: {"action":"tapText","params":{"text":"Button"},"reasoning":"...","progress":N}
inputText: {"action":"inputText","params":{"text":"hello"},"reasoning":"...","progress":N}
scroll: {"action":"scroll","params":{},"reasoning":"...","progress":N}
swipe: {"action":"swipe","params":{"startX":50,"startY":80,"endX":50,"endY":20},"reasoning":"...","progress":N}
pressKey: {"action":"pressKey","params":{"key":"enter"},"reasoning":"...","progress":N}
hideKeyboard: {"action":"hideKeyboard","params":{},"reasoning":"...","progress":N}
done: {"action":"done","params":{},"reasoning":"...","progress":100}
failed: {"action":"failed","params":{},"reasoning":"...","progress":N}

PROGRESS: Step ${step}/${maxSteps}
Recent: ${history.slice(-5).join(' -> ') || 'none'}

Respond with ONLY valid JSON (no markdown):`;
}

// ─── Main ───
const conversationHistory = [];
const actionHistory = [];
const totalStart = Date.now();

console.log(`\n${'='.repeat(50)}`);
console.log(`  Task:      ${task}`);
console.log(`  App:       ${bundleId}`);
console.log(`  Model:     ${model}`);
console.log(`  Device:    Physical iPhone (${DEVICE_ID})`);
console.log(`  Max Steps: ${maxSteps}`);
console.log(`${'='.repeat(50)}\n`);

// Step 0: Launch
console.log('[Step 0] Launching app on phone...');
const launchStart = Date.now();
await runMaestro(`appId: ${bundleId}\n---\n- launchApp`);
console.log(`[Step 0] App launched (${((Date.now() - launchStart) / 1000).toFixed(1)}s). Waiting 3s...`);
await sleep(3000);

// AI Loop
for (let step = 1; step <= maxSteps; step++) {
  const stepStart = Date.now();
  const elapsed = ((Date.now() - totalStart) / 1000).toFixed(1);
  console.log(`\n--- Step ${step}/${maxSteps} (${elapsed}s total) ---`);

  // Screenshot
  console.log('[Screenshot] Capturing from phone...');
  let imageBuffer;
  try {
    imageBuffer = await screenshot();
    console.log(`[Screenshot] OK (${Math.round(imageBuffer.length / 1024)} KB)`);
  } catch (e) {
    console.log(`[Screenshot] FAILED: ${e.message}`);
    await sleep(2000);
    continue;
  }

  // AI
  console.log(`[AI] Sending to ${model}...`);
  const systemPrompt = buildPrompt(task, step, maxSteps, actionHistory);
  const userMessage = {
    role: 'user',
    content: [
      { type: 'image_url', image_url: { url: `data:image/png;base64,${imageBuffer.toString('base64')}` } },
      { type: 'text', text: 'Analyze the screenshot. What is the ONE best action to progress toward the task goal?' },
    ],
  };

  if (conversationHistory.length > 10) conversationHistory.splice(0, conversationHistory.length - 8);
  conversationHistory.push(userMessage);

  let decision;
  try {
    const start = Date.now();
    const resp = await fetch(GEMINI_OPENAI_COMPAT_URL, {
      method: 'POST',
      headers: { 'Authorization': `Bearer ${apiKey}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        model,
        messages: [{ role: 'system', content: systemPrompt }, ...conversationHistory],
      }),
    });
    const data = await resp.json();
    const aiText = data.choices?.[0]?.message?.content || '';
    const aiElapsed = ((Date.now() - start) / 1000).toFixed(1);

    conversationHistory.push({ role: 'assistant', content: aiText });

    console.log(`[AI] Response (${aiElapsed}s):`);
    console.log(`     ${aiText.slice(0, 300)}`);

    const jsonMatch = aiText.match(/\{[\s\S]*\}/);
    if (!jsonMatch) throw new Error('No JSON in response');
    let jsonStr = jsonMatch[0];
    const dupeIndex = jsonStr.indexOf('}{');
    if (dupeIndex !== -1) jsonStr = jsonStr.slice(0, dupeIndex + 1);
    decision = JSON.parse(jsonStr);
  } catch (e) {
    console.log(`[AI] FAILED: ${e.message}`);
    await sleep(2000);
    continue;
  }

  console.log(`[Decision] Action: ${decision.action} | Progress: ${decision.progress}% | Reason: ${decision.reasoning}`);
  if (decision.params) console.log(`[Decision] Params: ${JSON.stringify(decision.params)}`);

  // Done/Failed
  if (decision.action === 'done') {
    const totalTime = ((Date.now() - totalStart) / 1000).toFixed(1);
    console.log(`\n${'='.repeat(50)}`);
    console.log(`  ✅ TASK COMPLETED`);
    console.log(`  Steps: ${step} | Total time: ${totalTime}s`);
    console.log(`${'='.repeat(50)}`);
    process.exit(0);
  }
  if (decision.action === 'failed') {
    const totalTime = ((Date.now() - totalStart) / 1000).toFixed(1);
    console.log(`\n${'='.repeat(50)}`);
    console.log(`  ❌ TASK FAILED (${totalTime}s)`);
    console.log(`  Reason: ${decision.reasoning}`);
    console.log(`${'='.repeat(50)}`);
    process.exit(1);
  }

  // Execute
  const execStart = Date.now();
  console.log(`[Execute] Running ${decision.action}...`);
  const p = decision.params || {};
  const header = `appId: ${bundleId}\n---\n`;
  try {
    switch (decision.action) {
      case 'tap':
        if (p.x > 100 || p.y > 100) {
          console.log(`[Execute] ERROR: Coordinates must be percentages 0-100, not pixels (got ${p.x},${p.y})`);
          actionHistory.push('error');
          continue;
        }
        await runMaestro(`${header}- tapOn:\n    point: "${p.x}%, ${p.y}%"`);
        break;
      case 'tapText':
        await runMaestro(`${header}- tapOn:\n    text: "${p.text?.replace(/"/g, '\\"')}"`);
        break;
      case 'inputText':
        await runMaestro(`${header}- inputText: "${p.text?.replace(/"/g, '\\"')}"`);
        break;
      case 'scroll':
        await runMaestro(`${header}- scroll`);
        break;
      case 'swipe':
        await runMaestro(`${header}- swipe:\n    start: "${p.startX}%, ${p.startY}%"\n    end: "${p.endX}%, ${p.endY}%"`);
        break;
      case 'pressKey':
        await runMaestro(`${header}- pressKey: ${p.key || 'enter'}`);
        break;
      case 'hideKeyboard':
        await runMaestro(`${header}- hideKeyboard`);
        break;
      default:
        console.log(`[Execute] Unknown action: ${decision.action}`);
    }
    const actionStr = `${decision.action}(${JSON.stringify(p)})`;
    actionHistory.push(actionStr);
    console.log(`[Execute] Done: ${actionStr} (${((Date.now() - execStart) / 1000).toFixed(1)}s)`);
  } catch (e) {
    console.log(`[Execute] FAILED: ${e.message} (${((Date.now() - execStart) / 1000).toFixed(1)}s)`);
    actionHistory.push('error');
  }

  await sleep(1500);
}

console.log('\n⏱️ Max steps reached');
process.exit(1);
