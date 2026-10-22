const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn } = require('node:child_process');

// 在无宿主机挂载的临时镜像容器中运行，避免修改实际家目录和系统环境。
const startup = '/usr/local/bin/start-dev-box';
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'devbox-cc-connect-'));
const delay = milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds));

async function waitFor(condition, label) {
  for (let attempt = 0; attempt < 200; attempt++) {
    if (condition()) return;
    await delay(50);
  }
  throw new Error(`等待超时：${label}`);
}

function launch(extraEnvironment = {}) {
  const processHandle = spawn('bash', [startup], {
    env: { ...process.env, HEALTH_REPORT_INTERVAL: '0', CC_CONNECT_ENABLED: '0', SSH_PUBLIC_KEY: '', ...extraEnvironment },
    detached: true,
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  const state = { processHandle, output: '', exited: false, code: null };
  processHandle.stdout.on('data', data => { state.output += data.toString(); });
  processHandle.stderr.on('data', data => { state.output += data.toString(); });
  processHandle.on('close', code => { state.exited = true; state.code = code; });
  return state;
}

async function dispose(state) {
  if (!state.exited) {
    // 模拟 tini 对整个进程组转发信号，验证服务和日志读取端的退出行为。
    process.kill(-state.processHandle.pid, 'SIGTERM');
    try {
      await waitFor(() => state.exited, '进程组关闭');
    } catch (error) {
      process.kill(-state.processHandle.pid, 'SIGKILL');
      throw error;
    }
  }
}

async function runCase(name, check) {
  await check();
  console.log(`通过：${name}`);
}

async function fakeService(name, source) {
  const directory = path.join(temporary, name);
  fs.mkdirSync(directory);
  fs.writeFileSync(path.join(directory, 'cc-connect'), `#!/usr/bin/env bash\n${source}\n`, { mode: 0o755 });
  const config = path.join(directory, 'config.toml');
  fs.writeFileSync(config, 'language = "zh"\n');
  return { PATH: `${directory}:${process.env.PATH}`, CC_CONNECT_ENABLED: '1', CC_CONNECT_CONFIG: config };
}

async function main() {
  await runCase('用户可复制镜像内的配置示例', async () => {
    const sample = '/usr/local/share/cc-connect/config.example.toml';
    assert.match(fs.readFileSync(sample, 'utf8'), /backend = "app_server"/);
    fs.copyFileSync(sample, path.join(temporary, '复制的示例.toml'));
  });

  await runCase('默认关闭时保持常驻且不启动聊天服务', async () => {
    const state = launch();
    try {
      await waitFor(() => state.output.includes('健康汇报已关闭'), '默认启动');
      assert.equal(state.exited, false);
      assert.equal(state.output.includes('已启动 cc-connect'), false);
    } finally {
      await dispose(state);
    }
  });

  await runCase('启用后缺失配置以失败状态退出', async () => {
    const state = launch({ CC_CONNECT_ENABLED: '1', CC_CONNECT_CONFIG: `${temporary}/不存在.toml` });
    try {
      await waitFor(() => state.exited, '缺失配置退出');
      assert.equal(state.code, 1);
      assert.match(state.output, /配置不可读或为空/);
    } finally {
      await dispose(state);
    }
  });

  await runCase('真实程序配置错误保留日志并退出', async () => {
    const config = path.join(temporary, '无项目.toml');
    fs.writeFileSync(config, 'language = "zh"\n');
    const state = launch({ CC_CONNECT_ENABLED: '1', CC_CONNECT_CONFIG: config });
    try {
      await waitFor(() => state.exited, '错误配置退出');
      assert.notEqual(state.code, 0);
      assert.match(state.output, /\[cc-connect\]/);
      assert.match(state.output, /cc-connect 进程已退出/);
    } finally {
      await dispose(state);
    }
  });

  for (const interval of ['0', '1']) {
    await runCase(`健康汇报间隔为 ${interval} 时都能发现服务崩溃`, async () => {
      // 子进程短暂保留日志写端，不能使已退出的服务被误判为健康。
      const environment = await fakeService(`崩溃-${interval}`, 'printf "验证服务已启动\\n"\nsleep 2 &\nsleep 1.3\nexit 7');
      const state = launch({ ...environment, HEALTH_REPORT_INTERVAL: interval });
      try {
        await waitFor(() => state.exited, '崩溃被发现');
        assert.equal(state.code, 7);
        assert.match(state.output, /\[cc-connect\] 验证服务已启动/);
        assert.match(state.output, /退出码 7/);
      } finally {
        await dispose(state);
      }
    });
  }

  await runCase('服务自行以零退出码结束也视为桥接中断', async () => {
    const environment = await fakeService('正常结束', 'sleep 0.3\nexit 0');
    const state = launch(environment);
    try {
      await waitFor(() => state.exited, '零退出码被发现');
      assert.equal(state.code, 1);
    } finally {
      await dispose(state);
    }
  });

  await runCase('终止信号保留服务的最后一行日志', async () => {
    const environment = await fakeService('正常关闭', 'trap \'printf "验证服务清理完成\\n"; exit 0\' TERM\nprintf "验证服务就绪\\n"\nwhile :; do sleep 0.1; done');
    const state = launch(environment);
    try {
      await waitFor(() => state.output.includes('验证服务就绪'), '服务启动');
      await dispose(state);
      assert.match(state.output, /\[cc-connect\] 验证服务清理完成/);
      assert.equal(state.code, 143);
    } finally {
      await dispose(state);
    }
  });

  await runCase('真实 cc-connect 注册双代理项目、回复状态并限制发送者', async () => {
    const { wsServer: WebSocketServer } = require('/usr/local/lib/node_modules/playwright/node_modules/playwright-core/lib/utilsBundle.js');
    const servers = [];
    const sockets = [];
    const replies = [[], []];
    let state;
    try {
      for (let index = 0; index < 2; index++) {
        const server = new WebSocketServer({ host: '127.0.0.1', port: 0 });
        servers.push(server);
        await new Promise(resolve => server.once('listening', resolve));
        server.on('connection', socket => {
          sockets[index] = socket;
          socket.on('message', raw => {
            const request = JSON.parse(raw.toString());
            const data = request.action === 'get_login_info' ? { user_id: 99999, nickname: '验证机器人' } : { message_id: 123 };
            if (request.action === 'send_private_msg') replies[index].push(request.params.message);
            socket.send(JSON.stringify({ status: 'ok', retcode: 0, data, echo: request.echo }));
          });
        });
      }
      const config = path.join(temporary, '双项目.toml');
      fs.writeFileSync(config, `language = "zh"\ndata_dir = "${temporary}/state"\n` + ['codex', 'claudecode'].map((agent, index) => `
[[projects]]
name = "验证-${agent}"
[projects.agent]
type = "${agent}"
[projects.agent.options]
work_dir = "/workspace"
mode = "${index === 0 ? 'suggest' : 'default'}"
${index === 0 ? 'backend = "app_server"\napp_server_url = "stdio://"' : ''}
[[projects.platforms]]
type = "qq"
[projects.platforms.options]
ws_url = "ws://127.0.0.1:${servers[index].address().port}"
allow_from = "12345"
`).join(''));
      state = launch({ CC_CONNECT_ENABLED: '1', CC_CONNECT_CONFIG: config });
      await waitFor(() => sockets.length === 2 && state.output.includes('cc-connect is running'), '双项目启动');
      const send = (index, user, text, id) => sockets[index].send(JSON.stringify({
        post_type: 'message', message_type: 'private', user_id: user, message_id: id,
        time: Math.floor(Date.now() / 1000), sender: { nickname: '验证用户' },
        message: [{ type: 'text', data: { text } }],
      }));
      for (let index = 0; index < 2; index++) send(index, 54321, '/status', index + 1);
      await delay(300);
      assert(replies.every(messages => messages.length === 0));
      for (let index = 0; index < 2; index++) send(index, 12345, '/status', index + 101);
      await waitFor(() => replies.every(messages => messages.length > 0), '状态回复');
      assert.match(replies[0].join('\n'), /codex/);
      assert.match(replies[1].join('\n'), /claudecode/);
      await dispose(state);
      assert.match(state.output, /\[cc-connect\].*bye/);
    } finally {
      if (state) await dispose(state);
      sockets.forEach(socket => socket.terminate());
      await Promise.all(servers.map(server => new Promise(resolve => server.close(resolve))));
    }
  });

  await runCase('原有 SSH 公钥登录和退出清理仍可用', async () => {
    const { execFileSync } = require('node:child_process');
    const privateKey = path.join(temporary, 'ssh-key');
    execFileSync('ssh-keygen', ['-q', '-t', 'ed25519', '-f', privateKey, '-N', '']);
    const state = launch({ SSH_PUBLIC_KEY: fs.readFileSync(`${privateKey}.pub`, 'utf8') });
    try {
      await waitFor(() => state.output.includes('sshd 已启动'), 'SSH 启动');
      const reply = execFileSync('ssh', [
        '-i', privateKey, '-o', 'IdentitiesOnly=yes', '-o', 'StrictHostKeyChecking=no',
        '-o', 'UserKnownHostsFile=/dev/null', 'vscode@127.0.0.1', 'printf', '验证SSH登录',
      ], { encoding: 'utf8', timeout: 10000 });
      assert.equal(reply, '验证SSH登录');
      await dispose(state);
      assert.match(state.output, /\[sshd\].*Accepted publickey/);
      assert.match(state.output, /\[sshd\].*Received signal 15/);
    } finally {
      await dispose(state);
    }
  });
}

main().catch(error => { console.error(error); process.exitCode = 1; });
