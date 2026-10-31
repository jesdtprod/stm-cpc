import assert from "node:assert/strict";
import { createSignupEntry } from "../../web/pages-account.js";

function setup(load) {
  const state = { hash: "#/", notices: [], navigation: [] };
  const enter = createSignupEntry({
    load,
    getHash: () => state.hash,
    navigate: (hash) => state.navigation.push(hash),
    notify: (closed) => state.notices.push(closed),
  });
  return { state, enter };
}
Deno.test("signup entry: closed applications show only a notice and keep the current page", async () => {
  const { state, enter } = setup(() => Promise.resolve(false));
  await enter();
  assert.deepEqual(state.notices, [true]);
  assert.deepEqual(state.navigation, []);
  assert.equal(state.hash, "#/");
});
Deno.test("signup entry: open applications navigate to the form without a notice", async () => {
  const { state, enter } = setup(() => Promise.resolve(true));
  await enter();
  assert.deepEqual(state.navigation, ["#/signup"]);
  assert.deepEqual(state.notices, []);
});
Deno.test("signup entry: failed lookup can retry without navigating or claiming registration is closed", async () => {
  let tries = 0;
  const { state, enter } = setup(() =>
    ++tries === 1 ? Promise.reject(new Error("network")) : Promise.resolve(true)
  );
  await enter();
  assert.deepEqual(state.notices, [false]);
  assert.deepEqual(state.navigation, []);
  await enter();
  assert.deepEqual(state.navigation, ["#/signup"]);
});
Deno.test("signup entry: duplicate clicks and replies after leaving the page do nothing", async () => {
  let resolve;
  let calls = 0;
  const { state, enter } = setup(() => {
    calls++;
    return new Promise((done) => resolve = done);
  });
  const pending = enter();
  await enter();
  assert.equal(calls, 1);
  state.hash = "#/signin";
  resolve(false);
  await pending;
  assert.deepEqual(state.notices, []);
  assert.deepEqual(state.navigation, []);
});
