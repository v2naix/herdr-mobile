'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const {shouldReconnect} = require('../web/reconnect-policy.js');

test('policy rejection stops reconnecting so the user can log in again', () => {
  assert.equal(shouldReconnect({manuallyLoggedOut: false, closeCode: 1008}), false);
});

test('transient disconnects reconnect unless the user logged out', () => {
  assert.equal(shouldReconnect({manuallyLoggedOut: false, closeCode: 1006}), true);
  assert.equal(shouldReconnect({manuallyLoggedOut: true, closeCode: 1006}), false);
});
