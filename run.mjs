#!/usr/bin/env node
/**
 * Minimal runner - bypasses commander/ora to test the core flow
 */
import 'dotenv/config';
import { exec } from 'child_process';
import { writeFileSync, readFileSync, unlinkSync, existsSync, mkdirSync, copyFileSync, readdirSync, rmdirSync } from 'fs';
import { tmpdir } from 'os';
import { join } from 'path';
import { createGoogleGenerativeAI } from '@ai-sdk/google';
import { generateText } from 'ai';

// Parse args
const args = process.argv.slice(2);
const bundleId = args[0];
const task = args[1];
const maxSteps = parseInt(args.find((_, i) => args[i - 1] === '--max-steps') || '10');
const model = args.find((_, i) => args[i - 1] === '--model') || 'gemini-2.5-flash-lite';

if (!task) {
  console.log('Usage: node run.mjs <bundleId> "task" [--max-steps N]');
  process.exit(1);
}

const apiKey = process.env.GEMINI_API_KEY;
if (!apiKey) {
  console.log('ERROR: Set GEMINI_API_KEY (https://aistudio.google.com/apikey)');
  process.exit(1);
}

// Helpers
function runMaestro(yaml) {
  const flowPath = join(tmpdir(), `maestro-flow-${Date.now()}.yaml`);
  writeFileSync(flowPath, yaml);
  const cmd = `maestro test ${flowPath}`;
  return new Promise((resolve, reject) => {
    exec(cmd, { timeout: 30000 }, (error) => {
      try { unlinkSync(flowPath); } catch {}
      if (error) reject(new Error(`Maestro failed: ${error.message.slice(0, 200)}`));
      else resolve();
    });
  });
}

function screenshot() {
  const screenshotPath = join(tmpdir(), `screen-${Date.now()}.png`);
  return new Promise((resolve, reject) => {
    exec(`xcrun simctl io booted screenshot "${screenshotPath}"`, { timeout: 10000 }, (error) => {
      if (error) return reject(new Error(`Screenshot failed: ${error.message}`));
      const buffer = readFileSync(screenshotPath);
      try { unlinkSync(screenshotPath); } catch {}
      resolve(buffer);
    });
  });
}

const sleep = (ms) => new Promise(r => setTimeout(r, ms));

// Build system prompt
function buildPrompt(task, step, maxSteps, history) {
  return `You are an AI agent controlling a mobile app to complete a task.

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
hideKeyboard: {"action":"hideKeyboard","params":{},"reasoning":"...","progress":N}
done: {"action":"done","params":{},"reasoning":"...","progress":100}
failed: {"action":"failed","params":{},"reasoning":"...","progress":N}

PROGRESS: Step ${step}/${maxSteps}
Recent: ${history.slice(-5).join(' -> ') || 'none'}

Respond with ONLY valid JSON (no markdown):`;
}

// Main
const googleProvider = createGoogleGenerativeAI({ apiKey });
const conversationHistory = [];
const actionHistory = [];
const totalStart = Date.now();

console.log(`\n${'='.repeat(50)}`);
console.log(`  Task:      ${task}`);
console.log(`  App:       ${bundleId || '(foreground)'}`);
console.log(`  Model:     ${model}`);
console.log(`  Max Steps: ${maxSteps}`);
console.log(`${'='.repeat(50)}\n`);

// Step 0: Launch
if (bundleId) {
  const launchStart = Date.now();
  console.log('[Step 0] Launching app...');
  await runMaestro(`appId: ${bundleId}\n---\n- launchApp`);
  console.log(`[Step 0] App launched (${((Date.now() - launchStart) / 1000).toFixed(1)}s). Waiting 3s...`);
  await sleep(3000);
}

// AI Loop
const stepTimes = [];
for (let step = 1; step <= maxSteps; step++) {
  const stepStart = Date.now();
  const elapsed = ((Date.now() - totalStart) / 1000).toFixed(1);
  console.log(`\n--- Step ${step}/${maxSteps} (${elapsed}s total) ---`);

  // Screenshot
  const ssStart = Date.now();
  console.log('[Screenshot] Capturing...');
  let imageBuffer;
  try {
    imageBuffer = await screenshot();
    console.log(`[Screenshot] OK (${Math.round(imageBuffer.length / 1024)} KB, ${((Date.now() - ssStart) / 1000).toFixed(1)}s)`);
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
      { type: 'image', image: imageBuffer },
      { type: 'text', text: 'Analyze the screenshot. What is the ONE best action to progress toward the task goal?' },
    ],
  };

  if (conversationHistory.length > 10) conversationHistory.splice(0, conversationHistory.length - 8);
  conversationHistory.push(userMessage);

  let decision;
  try {
    const start = Date.now();
    const response = await generateText({
      model: googleProvider(model),
      system: systemPrompt,
      messages: conversationHistory,
    });
    const elapsed = ((Date.now() - start) / 1000).toFixed(1);

    conversationHistory.push({ role: 'assistant', content: response.text });

    console.log(`[AI] Response (${elapsed}s):`);
    console.log(`     ${response.text.slice(0, 300)}`);

    const jsonMatch = response.text.match(/\{[\s\S]*\}/);
    if (!jsonMatch) throw new Error('No JSON in response');
    let jsonStr = jsonMatch[0];
    // Handle model returning duplicate JSON objects (e.g. {...}{...})
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
    console.log(`  Avg per step: ${(parseFloat(totalTime) / step).toFixed(1)}s`);
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
  const header = bundleId ? `appId: ${bundleId}\n---\n` : '---\n';
  try {
    switch (decision.action) {
      case 'tap':
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
      case 'hideKeyboard':
        await runMaestro(`${header}- hideKeyboard`);
        break;
      case 'back':
        await runMaestro(`${header}- back`);
        break;
      case 'pressKey':
        await runMaestro(`${header}- pressKey: ${p.key || 'enter'}`);
        break;
      case 'wait':
        await sleep(p.timeout || 3000);
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

  const stepTime = ((Date.now() - stepStart) / 1000).toFixed(1);
  stepTimes.push(parseFloat(stepTime));
  console.log(`[Step ${step}] Completed in ${stepTime}s`);

  await sleep(1500);
}

const totalTime = ((Date.now() - totalStart) / 1000).toFixed(1);
console.log(`\n${'='.repeat(50)}`);
console.log(`  ⏱️  MAX STEPS REACHED`);
console.log(`  Steps: ${maxSteps} | Total time: ${totalTime}s`);
console.log(`  Avg per step: ${stepTimes.length ? (stepTimes.reduce((a, b) => a + b, 0) / stepTimes.length).toFixed(1) : 0}s`);
console.log(`${'='.repeat(50)}`);
process.exit(1);
