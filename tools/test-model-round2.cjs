'use strict';

const assert = require('node:assert/strict');
const { environment } = require('./test-card-host.cjs');

(async () => {
  const e = environment();
  try {
    const proxies = JSON.parse('{"__proto__":{"type":"Selector","now":"first","all":["first","second"]},"constructor":{"type":"Selector","now":"first","all":["first","second"]},"first":{"type":"Shadowsocks"},"second":{"type":"Shadowsocks"}}');
    const quotedGroup = 'group "quote"\\line\n名称';
    const quotedNode = 'node "quote"\\line\n名称';
    proxies[quotedGroup] = { type: 'Selector', now: 'first', all: ['first', quotedNode] };
    proxies[quotedNode] = { type: 'Shadowsocks' };
    e.setProxies(proxies);
    e.seedRun('arbitrary-group-names');
    await e.initialize();
    const create = e.network.http.createHttp;
    e.network.http.createHttp = () => {
      const client = create();
      return {
        request: (url, options) => {
          if (options.method === 'PUT') {
            const group = decodeURIComponent(new URL(url).pathname.slice('/proxies/'.length));
            proxies[group].now = JSON.parse(options.extraData).name;
            return Promise.resolve({ responseCode: 204, result: '' });
          }
          return client.request(url, options);
        },
        destroy: () => client.destroy()
      };
    };
    await e.model.selectNode('__proto__', 'second');
    await e.model.selectNode('constructor', 'second');
    await e.model.selectNode(quotedGroup, quotedNode);
    let selections = e.store.readSettings().selections[e.model.selectedProfileId];
    assert.equal(Object.hasOwn(selections, '__proto__'), true);
    assert.equal(selections.__proto__, 'second');
    assert.equal(selections.constructor, 'second');
    assert.equal(selections[quotedGroup], quotedNode);
    await e.model.selectNode('__proto__', 'first');
    selections = e.store.readSettings().selections[e.model.selectedProfileId];
    assert.equal(selections.__proto__, 'first');
    assert.equal(selections.constructor, 'second', 'Changing one group must preserve other saved choices');
    assert.equal(selections[quotedGroup], quotedNode, 'Quotes, newlines and backslashes remain exact JSON keys and values');
    assert.equal(e.model.groups.find(group => group.name === '__proto__').now, 'first');
    assert.deepEqual(Object.keys(selections).sort(), ['__proto__', 'constructor', quotedGroup].sort());
    console.log('PASS valid group names preserve their exact keys and choices through JSON persistence');
  } finally {
    e.cleanup();
  }
})().catch(error => {
  console.error(error.stack || error);
  process.exitCode = 1;
});
