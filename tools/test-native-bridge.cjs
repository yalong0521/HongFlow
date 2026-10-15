'use strict';

// Execute the production bridge with Node N-API. The second build supplies a
// small Linux ioctl fixture; neither build creates a system VPN or loads Go.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

function run(command, args) {
  const result = spawnSync(command, args, { encoding: 'utf8' });
  if (result.error) throw result.error;
  assert.equal(result.status, 0, result.stdout + result.stderr);
}

function checkArguments(bridge) {
  for (const value of [undefined, null, '3', -1, 1.5, NaN, Infinity, 2147483648]) {
    assert.throws(() => bridge.tunInterfaceName(value), TypeError);
  }
  assert.throws(() => bridge.tunInterfaceName(), TypeError);
  assert.throws(() => bridge.tunInterfaceName(7, 8), TypeError);
}

const source = path.resolve(__dirname, '../entry/src/main/cpp/napi_bridge.cpp');
const include = [process.env.HONGFLOW_NODE_INCLUDE,
  path.resolve(path.dirname(process.execPath), '../include/node'), '/usr/include/node']
  .find(candidate => candidate && fs.existsSync(path.join(candidate, 'node_api.h')));
assert.ok(include, 'Set HONGFLOW_NODE_INCLUDE to the directory containing node_api.h');
assert.ok(['darwin', 'linux'].includes(process.platform), 'This host test supports macOS and Linux');
const build = fs.mkdtempSync(path.join(os.tmpdir(), 'hongflow-native-bridge-'));

try {
  fs.mkdirSync(path.join(build, 'napi'));
  fs.writeFileSync(path.join(build, 'napi/native_api.h'), '#include <node_api.h>\n');
  const common = ['-std=c++17', '-shared', '-fPIC', '-Wall', '-Wextra', '-Werror',
    '-Wno-deprecated-declarations', '-I' + build, '-I' + include,
    ...(process.platform === 'darwin' ? ['-undefined', 'dynamic_lookup'] : ['-ldl'])];
  const compiler = process.env.CXX || 'clang++';
  const realPath = path.join(build, 'real.node');
  run(compiler, [...common, source, '-o', realPath]);
  const real = require(realPath);
  checkArguments(real);
  for (const name of ['validateProfile', 'start', 'stop', 'version', 'setMode']) {
    assert.equal(typeof real[name], 'function', 'Existing bridge export: ' + name);
  }
  assert.throws(() => real.tunInterfaceName(2147483647),
    process.platform === 'linux' ? /读取 TUN 网卡名称失败/ : /当前平台不支持/);
  console.log('PASS production bridge arguments and actual host unsupported/invalid-fd path');

  const fixture = path.join(build, 'fixture');
  for (const directory of ['linux', 'net', 'sys']) fs.mkdirSync(path.join(fixture, directory), { recursive: true });
  fs.writeFileSync(path.join(fixture, 'linux/if_tun.h'), '#define TUNGETIFF 0x800454d2UL\n');
  fs.writeFileSync(path.join(fixture, 'net/if.h'),
    '#pragma once\n#define IFNAMSIZ 16\nstruct ifreq { char ifr_name[IFNAMSIZ]; };\n');
  fs.writeFileSync(path.join(fixture, 'sys/ioctl.h'),
    '#pragma once\nextern "C" int ioctl(int, unsigned long, ...);\n');
  const fixtureSource = path.join(build, 'fixture.cpp');
  // Preload real host headers before selecting the Linux branch on macOS.
  fs.writeFileSync(fixtureSource, `#include "napi/native_api.h"
#include <cerrno>
#include <cmath>
#include <cstring>
#include <dlfcn.h>
#include <limits>
#include <mutex>
#include <string>
#include <cstdarg>
#ifndef __linux__
#define __linux__ 1
#endif
#define ioctl HongFlowFixtureIoctl
#include ${JSON.stringify(source)}
extern "C" int ioctl(int fd, unsigned long operation, ...) {
  if (operation != TUNGETIFF) { errno = EINVAL; return -1; }
  va_list args;
  va_start(args, operation);
  auto *request = va_arg(args, struct ifreq *);
  va_end(args);
  static bool interrupted = false;
  if (fd == 8 && !interrupted) { interrupted = true; errno = EINTR; return -1; }
  if (fd == 7 || fd == 8) { std::strcpy(request->ifr_name, "tun-fixture"); return 0; }
  if (fd == 9) return 0;
  if (fd == 10) { std::memset(request->ifr_name, 'x', IFNAMSIZ); return 0; }
  errno = EBADF;
  return -1;
}
`);
  const fixturePath = path.join(build, 'fixture.node');
  run(compiler, [...common, '-I' + fixture, fixtureSource, '-o', fixturePath]);
  const bridge = require(fixturePath);
  checkArguments(bridge);
  assert.equal(bridge.tunInterfaceName(7), 'tun-fixture');
  assert.equal(bridge.tunInterfaceName(8), 'tun-fixture', 'Retry an interrupted ioctl');
  assert.throws(() => bridge.tunInterfaceName(9), /TUN 网卡名称无效/);
  assert.throws(() => bridge.tunInterfaceName(10), /TUN 网卡名称无效/);
  assert.throws(() => bridge.tunInterfaceName(11), /读取 TUN 网卡名称失败/);
  console.log('PASS Linux ioctl fixture name, interruption, invalid names and failure paths');
  console.log('Boundary: production bridge and Node N-API; fixture Linux headers/ioctl. No device VPN test.');
} finally {
  fs.rmSync(build, { recursive: true, force: true });
}
