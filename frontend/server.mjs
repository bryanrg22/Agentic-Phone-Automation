#!/usr/bin/env node
/**
 * WebSocket server connecting the phone UI to the agent.
 * Phone sends commands → server runs agent → streams updates back.
 *
 * Usage: node frontend/server.mjs
 * Then open http://<your-mac-ip>:8000 on your phone's Safari.
 */
import 'dotenv/config';
import { createServer } from 'http';
import http2 from 'http2';
import { readFileSync, writeFileSync, existsSync } from 'fs';
import { join, dirname } from 'path';
import { tmpdir } from 'os';
import { fileURLToPath } from 'url';
import { WebSocketServer } from 'ws';
import { spawn } from 'child_process';
import { networkInterfaces } from 'os';
import { createSign } from 'crypto';

const __dirname = dirname(fileURLToPath(import.meta.url));
const PORT = 8000;

// ─── APNs Configuration ───
const APNS_KEY_ID = 'QMQJJ79CQD';
const APNS_TEAM_ID = 'C924TNC23B';
const APNS_BUNDLE_ID = 'com.bryanrg.MobileAgentCompanion';
const APNS_KEY_PATH = join(__dirname, '..', '.keys', `AuthKey_${APNS_KEY_ID}.p8`);
const APNS_HOST = 'api.sandbox.push.apple.com'; // Use api.push.apple.com for production

let apnsKey = null;
try {
  if (existsSync(APNS_KEY_PATH)) {
    apnsKey = readFileSync(APNS_KEY_PATH, 'utf8');
    console.log('[APNs] Key loaded');
  } else {
    console.log('[APNs] No key file found at', APNS_KEY_PATH);
  }
} catch { console.log('[APNs] Failed to load key'); }

// Store push-to-start token from iOS app
let pushToStartToken = null;

// Generate JWT for APNs authentication
function generateAPNsJWT() {
  const header = Buffer.from(JSON.stringify({ alg: 'ES256', kid: APNS_KEY_ID })).toString('base64url');
  const now = Math.floor(Date.now() / 1000);
  const payload = Buffer.from(JSON.stringify({ iss: APNS_TEAM_ID, iat: now })).toString('base64url');
  const signingInput = `${header}.${payload}`;
  const sign = createSign('SHA256');
  sign.update(signingInput);
  const signature = sign.sign(apnsKey, 'base64url');
  return `${header}.${payload}.${signature}`;
}

// Send APNs push to start a Live Activity
async function sendPushToStartLiveActivity(taskName) {
  if (!apnsKey || !pushToStartToken) {
    console.log(`[APNs] Cannot send push — key: ${!!apnsKey}, token: ${!!pushToStartToken}`);
    return;
  }

  const jwt = generateAPNsJWT();
  const payload = {
    aps: {
      timestamp: Math.floor(Date.now() / 1000),
      event: 'start',
      'content-state': {
        currentStep: 0,
        totalSteps: 1,
        thought: 'Starting...',
        phase: 'thinking',
        elapsed: '0',
        isComplete: false,
        success: false,
        waitingForInput: false,
        inputQuestion: '',
        inputOptions: [],
      },
      'attributes-type': 'AgentActivityAttributes',
      attributes: {
        taskName: taskName,
      },
      alert: {
        title: 'Agent Started',
        body: taskName,
      },
    },
  };

  return new Promise((resolve, reject) => {
    const client = http2.connect(`https://${APNS_HOST}`);
    client.on('error', (err) => { console.log(`[APNs] Connection error: ${err.message}`); reject(err); });

    const req = client.request({
      ':method': 'POST',
      ':path': `/3/device/${pushToStartToken}`,
      'authorization': `bearer ${jwt}`,
      'apns-push-type': 'liveactivity',
      'apns-topic': `${APNS_BUNDLE_ID}.push-type.liveactivity`,
      'apns-priority': '10',
      'content-type': 'application/json',
    });

    let responseData = '';
    req.on('data', (chunk) => { responseData += chunk; });
    req.on('end', () => {
      client.close();
      console.log(`[APNs] Push sent. Response: ${responseData || 'OK'}`);
      resolve();
    });
    req.on('error', (err) => { console.log(`[APNs] Request error: ${err.message}`); reject(err); });

    req.write(JSON.stringify(payload));
    req.end();
  });
}

// Send APNs push to update an existing Live Activity
async function sendPushUpdateLiveActivity(updateToken, state) {
  if (!apnsKey || !updateToken) return;

  const jwt = generateAPNsJWT();
  const payload = {
    aps: {
      timestamp: Math.floor(Date.now() / 1000),
      event: state.isComplete ? 'end' : 'update',
      'content-state': {
        currentStep: state.currentStep,
        totalSteps: state.totalSteps,
        thought: state.thought,
        phase: state.phase,
        elapsed: state.elapsed,
        isComplete: state.isComplete,
        success: state.success,
        waitingForInput: state.waitingForInput || false,
        inputQuestion: state.inputQuestion || '',
        inputOptions: state.inputOptions || [],
      },
      ...(state.isComplete ? { 'dismissal-date': Math.floor(Date.now() / 1000) + 8 } : {}),
    },
  };

  return new Promise((resolve, reject) => {
    const client = http2.connect(`https://${APNS_HOST}`);
    client.on('error', (err) => reject(err));

    const req = client.request({
      ':method': 'POST',
      ':path': `/3/device/${updateToken}`,
      'authorization': `bearer ${jwt}`,
      'apns-push-type': 'liveactivity',
      'apns-topic': `${APNS_BUNDLE_ID}.push-type.liveactivity`,
      'apns-priority': '10',
      'content-type': 'application/json',
    });

    let responseData = '';
    req.on('data', (chunk) => { responseData += chunk; });
    req.on('end', () => { client.close(); resolve(); });
    req.on('error', reject);

    req.write(JSON.stringify(payload));
    req.end();
  });
}

// Store the Live Activity's push update token
let liveActivityUpdateToken = null;

// ─── Parse server CLI flags ───
const serverArgs = process.argv.slice(2);
const SERVER_PROVIDER = serverArgs.find((_, i) => serverArgs[i - 1] === '--provider') || 'gemini';
if (SERVER_PROVIDER !== 'gemini' && SERVER_PROVIDER !== 'openai') {
  console.log(`ERROR: Unknown provider "${SERVER_PROVIDER}". Use: --provider gemini  or  --provider openai`);
  process.exit(1);
}

// ─── Agent state (shared between WebSocket + HTTP /status) ───
let agentState = {
  isActive: false,
  taskName: '',
  currentStep: 0,
  totalSteps: 0,
  thought: '',
  phase: 'idle',
  toolName: '',
  elapsed: '0',
  isComplete: false,
  success: false,
  waitingForInput: false,
  inputQuestion: '',
  inputOptions: [],
};

// ─── Agent runner (shared between WebSocket + POST /task) ───
let agentProcess = null;

const DEFAULT_MODEL = SERVER_PROVIDER === 'openai' ? 'gpt-5.4' : 'gemini-2.5-flash-lite';

function startAgent(task, model = DEFAULT_MODEL, maxSteps = 25, onUpdate = () => {}, { phone = false } = {}) {
  if (agentProcess) { agentProcess.kill(); agentProcess = null; }

  agentState = { isActive: true, taskName: task, currentStep: 0, totalSteps: maxSteps, thought: 'Starting...', phase: 'thinking', toolName: '', elapsed: '0', isComplete: false, success: false };

  const agentPath = join(__dirname, '..', 'agent.mjs');
  const agentArgs = [agentPath, task, '--max-steps', String(maxSteps), '--model', model, '--provider', SERVER_PROVIDER];
  if (phone) agentArgs.push('--phone');
  agentProcess = spawn('node', agentArgs, {
    env: { ...process.env },
    cwd: join(__dirname, '..'),
  });

  agentProcess.stdout.on('data', (chunk) => {
    const text = chunk.toString();
    const lines = text.split('\n').filter(Boolean);
    for (const line of lines) {
      if (line.includes('[AI] Sending to')) { agentState.phase = 'thinking'; agentState.thought = 'Thinking...'; }
      else if (line.includes('[Tool]') && line.includes('→') && !line.includes('Found')) {
        const resultMatch = line.match(/→ (.+?)(?:\s*\([\d.]+s\))?$/);
        if (resultMatch) agentState.thought = resultMatch[1];
        agentState.phase = 'acting';
      }
      else if (line.includes('[Screenshot]')) { agentState.phase = 'observing'; agentState.thought = 'Capturing screen...'; }
      else if (line.includes('__ASK_USER__:')) {
        const askData = JSON.parse(line.split('__ASK_USER__:')[1]);
        agentState.waitingForInput = true;
        agentState.inputQuestion = askData.question;
        agentState.inputOptions = askData.options;
        agentState.phase = 'waiting';
        agentState.thought = askData.question;
        console.log(`[Server] Agent asking user: "${askData.question}" — options: ${askData.options.join(', ')}`);
      }
      else if (line.includes('TASK COMPLETED')) { agentState.isComplete = true; agentState.success = true; agentState.phase = 'complete'; agentState.isActive = false; }
      else if (line.includes('TASK FAILED')) { agentState.isComplete = true; agentState.success = false; agentState.phase = 'failed'; agentState.isActive = false; }
      else if (line.includes('--- Step')) {
        const match = line.match(/Step (\d+)\/(\d+).*\(([\d.]+)s total\)/);
        if (match) { agentState.currentStep = parseInt(match[1]); agentState.totalSteps = parseInt(match[2]); agentState.elapsed = match[3]; }
      }
    }
    onUpdate(text);
  });

  agentProcess.stderr.on('data', (chunk) => onUpdate(chunk.toString()));

  agentProcess.on('exit', (code) => {
    if (!agentState.isComplete) { agentState.isActive = false; agentState.isComplete = true; agentState.success = code === 0; agentState.phase = code === 0 ? 'complete' : 'failed'; }
    agentProcess = null;
  });

  return agentProcess;
}

// Serve static files + /status API + POST /task
const httpServer = createServer((req, res) => {
  // POST /task — accept task from Shortcuts / HTTP clients
  if (req.url === '/task' && req.method === 'POST') {
    let body = '';
    req.on('data', chunk => { body += chunk; });
    req.on('end', () => {
      try {
        const { task, model, maxSteps, phone } = JSON.parse(body);
        if (!task) { res.writeHead(400, { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' }); res.end(JSON.stringify({ error: 'Missing "task" field' })); return; }
        startAgent(task, model, maxSteps, (text) => {
          // Print agent output to server terminal
          process.stdout.write(text);
          // Broadcast to any connected WebSocket clients
          wss.clients.forEach(ws => ws.send(JSON.stringify({ type: 'log', text })));
        }, { phone: phone !== false });
        console.log(`[Server] Task received via POST: "${task}"`);

        // Send APNs push to start Live Activity on the phone
        sendPushToStartLiveActivity(task).catch(e => console.log(`[APNs] Push failed: ${e.message}`));
        res.writeHead(200, { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' });
        res.end(JSON.stringify({ status: 'started', task }));
      } catch (e) {
        res.writeHead(400, { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' });
        res.end(JSON.stringify({ error: 'Invalid JSON' }));
      }
    });
    return;
  }

  // POST /stop — stop the running agent
  if (req.url === '/stop' && req.method === 'POST') {
    if (agentProcess) {
      agentProcess.kill();
      agentProcess = null;
      agentState = { ...agentState, isActive: false, isComplete: true, success: false, phase: 'failed', thought: 'Stopped by user' };
      console.log('[Server] Agent stopped via POST /stop');
    }
    res.writeHead(200, { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' });
    res.end(JSON.stringify({ status: 'stopped' }));
    return;
  }

  // POST /respond — user responds to askUser question (from Dynamic Island)
  if (req.url === '/respond' && req.method === 'POST') {
    let body = '';
    req.on('data', chunk => { body += chunk; });
    req.on('end', () => {
      try {
        const { choice } = JSON.parse(body);
        if (!choice) { res.writeHead(400, { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' }); res.end(JSON.stringify({ error: 'Missing "choice" field' })); return; }
        // Write the response to a file that the agent polls
        const responseFile = join(tmpdir(), 'agent-user-response.json');
        writeFileSync(responseFile, JSON.stringify({ choice }));
        agentState.waitingForInput = false;
        agentState.inputQuestion = '';
        agentState.inputOptions = [];
        agentState.phase = 'acting';
        agentState.thought = `User chose: ${choice}`;
        console.log(`[Server] User responded: "${choice}"`);
        res.writeHead(200, { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' });
        res.end(JSON.stringify({ status: 'received', choice }));
      } catch (e) {
        res.writeHead(400, { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' });
        res.end(JSON.stringify({ error: 'Invalid JSON' }));
      }
    });
    return;
  }

  // POST /register-push-token — iOS app sends its pushToStartToken
  if (req.url === '/register-push-token' && req.method === 'POST') {
    let body = '';
    req.on('data', chunk => { body += chunk; });
    req.on('end', () => {
      try {
        const { token, type } = JSON.parse(body);
        if (type === 'pushToStart') {
          pushToStartToken = token;
          console.log(`[APNs] Registered pushToStart token: ${token.slice(0, 20)}...`);
        } else if (type === 'update') {
          liveActivityUpdateToken = token;
          console.log(`[APNs] Registered update token: ${token.slice(0, 20)}...`);
        }
        res.writeHead(200, { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' });
        res.end(JSON.stringify({ status: 'registered' }));
      } catch (e) {
        res.writeHead(400, { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' });
        res.end(JSON.stringify({ error: 'Invalid JSON' }));
      }
    });
    return;
  }

  // CORS preflight
  if ((req.url === '/task' || req.url === '/stop' || req.url === '/respond' || req.url === '/register-push-token') && req.method === 'OPTIONS') {
    res.writeHead(204, { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Methods': 'POST', 'Access-Control-Allow-Headers': 'Content-Type' });
    res.end();
    return;
  }

  if (req.url === '/status') {
    res.writeHead(200, {
      'Content-Type': 'application/json',
      'Access-Control-Allow-Origin': '*',
    });
    res.end(JSON.stringify(agentState));
  } else if (req.url === '/' || req.url === '/index.html') {
    res.writeHead(200, { 'Content-Type': 'text/html' });
    res.end(readFileSync(join(__dirname, 'index.html'), 'utf-8'));
  } else if (req.url === '/style.css') {
    res.writeHead(200, { 'Content-Type': 'text/css' });
    res.end(readFileSync(join(__dirname, 'style.css'), 'utf-8'));
  } else {
    res.writeHead(404);
    res.end('Not found');
  }
});

// WebSocket server
const wss = new WebSocketServer({ server: httpServer });

wss.on('connection', (ws) => {
  console.log('[Server] Client connected');
  let wsAgentProcess = null;

  ws.on('message', (data) => {
    const msg = JSON.parse(data.toString());

    if (msg.type === 'run') {
      const { task, model, maxSteps } = msg;
      ws.send(JSON.stringify({ type: 'status', status: 'starting', task }));

      wsAgentProcess = startAgent(task, model, maxSteps, (text) => {
        // Parse lines for detailed WebSocket updates
        const lines = text.split('\n').filter(Boolean);
        for (const line of lines) {
          if (line.includes('[AI] Sending to')) ws.send(JSON.stringify({ type: 'step', phase: 'thinking', raw: line }));
          else if (line.includes('[AI] Responded')) ws.send(JSON.stringify({ type: 'step', phase: 'decided', raw: line }));
          else if (line.includes('[Tool]') && line.includes('→') && !line.includes('Found')) ws.send(JSON.stringify({ type: 'step', phase: 'acting', raw: line }));
          else if (line.includes('[Tool]') && !line.includes('→')) ws.send(JSON.stringify({ type: 'step', phase: 'tool_call', raw: line }));
          else if (line.includes('[Screenshot]')) ws.send(JSON.stringify({ type: 'step', phase: 'observing', raw: line }));
          else if (line.includes('TASK COMPLETED')) ws.send(JSON.stringify({ type: 'done', success: true }));
          else if (line.includes('TASK FAILED')) ws.send(JSON.stringify({ type: 'done', success: false }));
          else if (line.includes('--- Step')) {
            const match = line.match(/Step (\d+)\/(\d+).*\(([\d.]+)s total\)/);
            if (match) ws.send(JSON.stringify({ type: 'step', phase: 'new_step', step: parseInt(match[1]), total: parseInt(match[2]), elapsed: match[3] }));
          }
        }
        ws.send(JSON.stringify({ type: 'log', text }));
      });

      wsAgentProcess.on('exit', (code) => {
        ws.send(JSON.stringify({ type: 'done', success: code === 0 }));
        wsAgentProcess = null;
      });
    }

    if (msg.type === 'stop') {
      if (agentProcess) {
        agentProcess.kill();
        agentProcess = null;
        agentState = { ...agentState, isActive: false, isComplete: true, success: false, phase: 'idle', thought: 'Stopped by user' };
        ws.send(JSON.stringify({ type: 'done', success: false, stopped: true }));
      }
    }
  });

  ws.on('close', () => {
    console.log('[Server] Client disconnected');
    if (agentProcess) { agentProcess.kill(); agentProcess = null; }
  });
});

// Start server
const nets = networkInterfaces();
const localIPs = Object.values(nets).flat().filter(n => n && n.family === 'IPv4' && !n.internal).map(n => n.address);

httpServer.listen(PORT, '0.0.0.0', () => {
  console.log(`\n${'='.repeat(50)}`);
  console.log('  mobile-use Frontend Server');
  console.log('='.repeat(50));
  console.log(`  Provider: ${SERVER_PROVIDER}`);
  console.log(`  Local:   http://localhost:${PORT}`);
  localIPs.forEach(ip => console.log(`  Network: http://${ip}:${PORT}`));
  console.log(`\n  Open the Network URL on your phone's Safari`);
  console.log('='.repeat(50) + '\n');
});
