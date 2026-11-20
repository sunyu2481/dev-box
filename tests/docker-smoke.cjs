const assert = require('node:assert/strict');
const fs = require('node:fs');
const http = require('node:http');
const os = require('node:os');
const path = require('node:path');
const { spawn, execFileSync } = require('node:child_process');

// 仅在无挂载的临时容器中运行，以模拟服务验证套接字权限，不接触宿主机 Docker。
const socket = '/var/run/docker.sock';
assert.equal(fs.existsSync(socket), false, '测试容器不得挂载真实 Docker 套接字');
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'devbox-docker-'));
const delay = milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds));
const sudo = (...args) => execFileSync('sudo', ['-n', ...args], { encoding: 'utf8' });

async function waitFor(condition, label) {
  for (let attempt = 0; attempt < 200; attempt++) {
    if (condition()) return;
    await delay(50);
  }
  throw new Error(`等待超时：${label}`);
}

async function main() {
  const privateKey = path.join(temporary, 'ssh-key');
  execFileSync('ssh-keygen', ['-q', '-t', 'ed25519', '-f', privateKey, '-N', '']);
  fs.writeFileSync(path.join(temporary, 'config.toml'), 'language = "zh"\n');
  fs.writeFileSync(path.join(temporary, 'cc-connect'), `#!/usr/bin/env bash
set -e
test "$DEVBOX_DOCKER_TEST_ENV" = '环境保留'
docker ps >/dev/null
printf '聊天代理访问成功\\n'
trap 'printf "聊天代理清理完成\\n"; exit 0' TERM
while :; do sleep 0.1; done
`, { mode: 0o755 });

  let requests = 0;
  const server = http.createServer((request, response) => {
    response.setHeader('API-Version', '1.44');
    if (request.url === '/_ping') return response.end('OK');
    response.setHeader('Content-Type', 'application/json');
    if (request.url.endsWith('/version')) {
      return response.end(JSON.stringify({ Version: '26.0.0', ApiVersion: '1.44', MinAPIVersion: '1.24' }));
    }
    if (request.url.includes('/containers/json')) {
      requests++;
      return response.end('[]');
    }
    response.statusCode = 404;
    response.end('{}');
  });
  await new Promise(resolve => server.listen(path.join(temporary, 'docker.sock'), resolve));
  sudo('mv', path.join(temporary, 'docker.sock'), socket);
  sudo('chmod', '660', socket);
  let unusedGid = 60000;
  while (spawnSyncGroupExists(unusedGid)) unusedGid++;

  try {
    for (const [label, gid] of [['复用现有组', 1], ['创建新组', unusedGid], ['重复启动', unusedGid]]) {
      sudo('chown', `0:${gid}`, socket);
      const child = spawn('bash', ['/usr/local/bin/start-dev-box'], {
        env: {
          ...process.env,
          PATH: `${temporary}:${process.env.PATH}`,
          DEVBOX_DOCKER_TEST_ENV: '环境保留',
          HEALTH_REPORT_INTERVAL: '0',
          CC_CONNECT_ENABLED: '1',
          CC_CONNECT_CONFIG: path.join(temporary, 'config.toml'),
          SSH_PUBLIC_KEY: fs.readFileSync(`${privateKey}.pub`, 'utf8'),
        },
        detached: true,
        stdio: ['ignore', 'pipe', 'pipe'],
      });
      let output = '';
      let closed = false;
      let status;
      child.stdout.on('data', data => { output += data; });
      child.stderr.on('data', data => { output += data; });
      child.on('close', code => { closed = true; status = code; });
      const previousRequests = requests;
      try {
        await waitFor(() => closed || output.includes('聊天代理访问成功'), `${label}：启动`);
        assert.equal(closed, false, output);
        assert.match(output, /sshd 已启动/);
        assert(requests > previousRequests, '聊天代理必须成功访问模拟 Docker 服务');
        const socketStat = fs.statSync(socket);
        assert.equal(socketStat.uid, 0);
        assert.equal(socketStat.gid, gid);
        assert.equal(socketStat.mode & 0o777, 0o660);

        // 异步执行 SSH，让当前事件循环继续响应 Docker 请求。
        const ssh = spawn('ssh', [
          '-i', privateKey, '-o', 'IdentitiesOnly=yes', '-o', 'StrictHostKeyChecking=no',
          '-o', 'UserKnownHostsFile=/dev/null', 'vscode@127.0.0.1',
          'docker ps >/dev/null && printf SSH访问成功',
        ]);
        let reply = '';
        ssh.stdout.on('data', data => { reply += data; });
        const sshStatus = await new Promise((resolve, reject) => {
          const timeout = setTimeout(() => { ssh.kill('SIGKILL'); reject(new Error('SSH 验证超时')); }, 10000);
          ssh.on('close', code => { clearTimeout(timeout); resolve(code); });
          ssh.on('error', reject);
        });
        assert.equal(sshStatus, 0);
        assert.equal(reply, 'SSH访问成功');
        process.kill(-child.pid, 'SIGTERM');
        await waitFor(() => closed, `${label}：退出`);
        assert.equal(status, 143, output);
        assert.match(output, /聊天代理清理完成/);
        console.log(`通过：${label}、聊天代理与 SSH 访问、环境保留及退出清理`);
      } finally {
        if (!closed) {
          process.kill(-child.pid, 'SIGKILL');
          await waitFor(() => closed, '清理失败的测试进程');
        }
      }
    }
  } finally {
    sudo('rm', '-f', socket);
    await new Promise(resolve => server.close(resolve));
    fs.rmSync(temporary, { recursive: true, force: true });
  }
}

function spawnSyncGroupExists(gid) {
  return require('node:child_process').spawnSync('getent', ['group', String(gid)]).status === 0;
}

main().catch(error => { console.error(error); process.exitCode = 1; });
