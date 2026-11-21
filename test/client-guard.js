// No server APIs exist here: touching one before returning must fail the test.
const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const path = require('node:path');
const context = vm.createContext({ IsDuplicityVersion: () => false });
vm.runInContext(fs.readFileSync(path.join(__dirname, '../inject/server.js'), 'utf8'), context);
assert.equal(context.__hitchhunter, undefined);
assert.deepEqual(Object.keys(context), ['IsDuplicityVersion']);
console.log('PASS shared JS client guard returns before accessing server APIs');
