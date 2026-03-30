import { execSync, exec } from 'child_process';
import {
  writeFileSync,
  readFileSync,
  mkdirSync,
  existsSync,
  unlinkSync,
  copyFileSync,
  readdirSync,
  rmdirSync,
} from 'fs';
import * as os from 'os';
import * as path from 'path';

export interface IosDeviceConfig {
  udid: string;
  teamId: string;
  appFile: string;
  driverPort?: number;
}

export interface MaestroConfig {
  bundleId?: string;
  timeout?: number;
  saveEvalScreens?: boolean;
  evalScreensDir?: string;
  deviceId?: string;
  iosDevice?: IosDeviceConfig;
}

export class MaestroClient {
  private bundleId?: string;
  private timeout: number;
  private saveEvalScreens: boolean;
  private evalScreensDir: string;
  private deviceId?: string;
  private iosDevice?: IosDeviceConfig;

  constructor(config: MaestroConfig) {
    this.bundleId = config.bundleId;
    this.timeout = config.timeout ?? 30000;
    this.saveEvalScreens = config.saveEvalScreens ?? false;
    this.evalScreensDir = config.evalScreensDir ?? './eval-screens';
    this.deviceId = config.deviceId;
    this.iosDevice = config.iosDevice;
  }

  private buildYamlHeader(): string {
    return this.bundleId ? `appId: ${this.bundleId}\n---\n` : '---\n';
  }

  private buildMaestroCommand(flowPath: string): string {
    let cmd = 'maestro';

    if (this.iosDevice) {
      const port = this.iosDevice.driverPort ?? 6001;
      cmd += ` --driver-host-port ${port}`;
      cmd += ` --device ${this.iosDevice.udid}`;
      cmd += ` --app-file ${this.iosDevice.appFile}`;
    } else if (this.deviceId) {
      cmd += ` --device ${this.deviceId}`;
    }

    cmd += ` test ${flowPath}`;
    return cmd;
  }

  isIosDevice(): boolean {
    return !!this.iosDevice;
  }

  getIosDeviceInfo(): IosDeviceConfig | undefined {
    return this.iosDevice;
  }

  private runFlow(yaml: string): Promise<void> {
    const flowPath = `/tmp/maestro-flow-${Date.now()}.yaml`;
    writeFileSync(flowPath, yaml);
    const cmd = this.buildMaestroCommand(flowPath);
    const timeout = this.timeout;

    return new Promise<void>((resolve, reject) => {
      exec(cmd, { timeout }, (error) => {
        try { unlinkSync(flowPath); } catch { /* ignore */ }
        if (error) {
          reject(new Error(`Maestro command failed: ${error.message.slice(0, 200)}`));
        } else {
          resolve();
        }
      });
    });
  }

  hasBundleId(): boolean {
    return !!this.bundleId;
  }

  async launch(): Promise<void> {
    if (!this.bundleId) {
      return;
    }
    const yaml = `appId: ${this.bundleId}\n---\n- launchApp`;
    await this.runFlow(yaml);
  }

  async launchApp(appId: string): Promise<void> {
    const yaml = `${this.buildYamlHeader()}- launchApp:\n    appId: "${appId}"`;
    await this.runFlow(yaml);
  }

  async stopApp(appId: string): Promise<void> {
    const yaml = `${this.buildYamlHeader()}- stopApp:\n    appId: "${appId}"`;
    await this.runFlow(yaml);
  }

  async tap(x: number, y: number): Promise<void> {
    const yaml = `${this.buildYamlHeader()}- tapOn:\n    point: "${x}%, ${y}%"`;
    await this.runFlow(yaml);
  }

  async tapText(text: string): Promise<void> {
    const escapedText = text.replace(/"/g, '\\"');
    const yaml = `${this.buildYamlHeader()}- tapOn:\n    text: "${escapedText}"`;
    await this.runFlow(yaml);
  }

  async doubleTap(x: number, y: number): Promise<void> {
    const yaml = `${this.buildYamlHeader()}- doubleTapOn:\n    point: "${x}%, ${y}%"`;
    await this.runFlow(yaml);
  }

  async longPress(x: number, y: number): Promise<void> {
    const yaml = `${this.buildYamlHeader()}- longPressOn:\n    point: "${x}%, ${y}%"`;
    await this.runFlow(yaml);
  }

  async longPressText(text: string): Promise<void> {
    const escapedText = text.replace(/"/g, '\\"');
    const yaml = `${this.buildYamlHeader()}- longPressOn:\n    text: "${escapedText}"`;
    await this.runFlow(yaml);
  }

  async inputText(text: string): Promise<void> {
    const escapedText = text.replace(/"/g, '\\"');
    const yaml = `${this.buildYamlHeader()}- inputText: "${escapedText}"`;
    await this.runFlow(yaml);
  }

  async inputLongText(text: string, chunkSize: number = 200): Promise<void> {
    if (text.length <= chunkSize) {
      return this.inputText(text);
    }

    const chunks = this.smartChunk(text, chunkSize);

    for (let i = 0; i < chunks.length; i++) {
      await this.inputText(chunks[i] ?? '');
      await this.sleep(150);
    }
  }

  private smartChunk(text: string, maxSize: number): string[] {
    const chunks: string[] = [];
    let remaining = text;

    while (remaining.length > 0) {
      if (remaining.length <= maxSize) {
        chunks.push(remaining);
        break;
      }

      let breakPoint = remaining.lastIndexOf('. ', maxSize);
      if (breakPoint === -1) {
        breakPoint = remaining.lastIndexOf(' ', maxSize);
      }
      if (breakPoint === -1) {
        breakPoint = maxSize;
      } else {
        breakPoint += 1;
      }

      chunks.push(remaining.slice(0, breakPoint));
      remaining = remaining.slice(breakPoint);
    }

    return chunks;
  }

  private sleep(ms: number): Promise<void> {
    return new Promise((resolve) => setTimeout(resolve, ms));
  }

  async pasteText(text: string): Promise<void> {
    const escapedText = text.replace(/"/g, '\\"').replace(/\n/g, '\\n');
    const yaml = `${this.buildYamlHeader()}- pasteText: "${escapedText}"`;
    await this.runFlow(yaml);
  }

  async eraseText(chars: number = 50): Promise<void> {
    const yaml = `${this.buildYamlHeader()}- eraseText: ${chars}`;
    await this.runFlow(yaml);
  }

  async scroll(): Promise<void> {
    const yaml = `${this.buildYamlHeader()}- scroll`;
    await this.runFlow(yaml);
  }

  async swipe(startX: number, startY: number, endX: number, endY: number): Promise<void> {
    const yaml = `${this.buildYamlHeader()}- swipe:\n    start: "${startX}%, ${startY}%"\n    end: "${endX}%, ${endY}%"`;
    await this.runFlow(yaml);
  }

  async back(): Promise<void> {
    const yaml = `${this.buildYamlHeader()}- back`;
    await this.runFlow(yaml);
  }

  async hideKeyboard(): Promise<void> {
    const yaml = `${this.buildYamlHeader()}- hideKeyboard`;
    await this.runFlow(yaml);
  }

  async openLink(url: string): Promise<void> {
    const yaml = `${this.buildYamlHeader()}- openLink: ${url}`;
    await this.runFlow(yaml);
  }

  async pressKey(key: string): Promise<void> {
    const yaml = `${this.buildYamlHeader()}- pressKey: ${key}`;
    await this.runFlow(yaml);
  }

  async waitForAnimation(timeout: number = 3000): Promise<void> {
    const yaml = `${this.buildYamlHeader()}- waitForAnimationToEnd:\n    timeout: ${timeout}`;
    await this.runFlow(yaml);
  }

  async iosBackGesture(): Promise<void> {
    const yaml = `${this.buildYamlHeader()}- swipe:\n    start: "1%, 50%"\n    end: "80%, 50%"`;
    await this.runFlow(yaml);
  }

  async screenshot(stepNumber?: number): Promise<string> {
    const timestamp = Date.now();
    const screenshotPath = path.join(os.tmpdir(), `maestro-screen-${timestamp}.png`);

    try {
      if (!this.iosDevice) {
        // Simulator: use xcrun simctl (reliable)
        await new Promise<void>((resolve, reject) => {
          exec(`xcrun simctl io booted screenshot "${screenshotPath}"`, { timeout: 10000 }, (error) => {
            if (error) reject(new Error(`Screenshot failed: ${error.message}`));
            else resolve();
          });
        });
      } else {
        // Physical device: use Maestro's takeScreenshot
        const name = `screen-${timestamp}`;
        const tempDir = path.join(os.tmpdir(), `maestro-eval-${timestamp}`);
        mkdirSync(tempDir, { recursive: true });
        const yaml = `${this.buildYamlHeader()}- takeScreenshot: ${name}`;
        const flowPath = path.join(tempDir, 'flow.yaml');
        writeFileSync(flowPath, yaml);
        const cmd = this.buildMaestroCommand(flowPath);
        await new Promise<void>((resolve, reject) => {
          exec(cmd, { timeout: 15000, cwd: tempDir }, (error) => {
            if (error) reject(error);
            else resolve();
          });
        });
        const maestroScreenshot = path.join(tempDir, `${name}.png`);
        if (existsSync(maestroScreenshot)) {
          copyFileSync(maestroScreenshot, screenshotPath);
        }
        try {
          const files = readdirSync(tempDir);
          for (const f of files) unlinkSync(path.join(tempDir, f));
          rmdirSync(tempDir);
        } catch { /* ignore */ }
      }

      if (!existsSync(screenshotPath)) {
        throw new Error(`Screenshot not found at ${screenshotPath}`);
      }

      const buffer = readFileSync(screenshotPath);

      if (this.saveEvalScreens && stepNumber !== undefined) {
        mkdirSync(this.evalScreensDir, { recursive: true });
        const evalPath = path.join(this.evalScreensDir, `step-${String(stepNumber).padStart(3, '0')}-before.png`);
        copyFileSync(screenshotPath, evalPath);
      }

      return buffer.toString('base64');
    } catch (error: unknown) {
      const err = error as { message?: string };
      throw new Error(`Screenshot failed: ${(err.message || 'Unknown error').slice(0, 300)}`);
    } finally {
      try { unlinkSync(screenshotPath); } catch { /* ignore */ }
    }
  }

  async hierarchy(): Promise<Record<string, unknown>> {
    try {
      const output = execSync('maestro hierarchy', {
        encoding: 'utf-8',
        stdio: 'pipe',
        timeout: 10000,
      });

      const jsonMatch = output.match(/\{[\s\S]*\}/);
      if (!jsonMatch) {
        throw new Error('No JSON found in hierarchy output');
      }

      return JSON.parse(jsonMatch[0]) as Record<string, unknown>;
    } catch (error: unknown) {
      const err = error as { message?: string };
      throw new Error(`Hierarchy failed: ${err.message || 'Unknown error'}`);
    }
  }
}
