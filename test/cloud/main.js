// Cloud Code for Parse Server testing

Parse.Cloud.define('hello', () => {
  return 'Hello world!';
});

Parse.Cloud.define('helloName', async (request) => {
  return `Hello ${request.params.name || 'World'}!`;
});

Parse.Cloud.define('testFunction', (request) => {
  return {
    message: 'This is a test cloud function',
    params: request.params,
    user: request.user ? request.user.get('username') : 'anonymous'
  };
});

// Test hooks
Parse.Cloud.beforeSave('TestObject', (request) => {
  request.object.set('beforeSaveRan', true);
});

Parse.Cloud.beforeSave('TestWithHook', (request) => {
  console.log('BeforeSave hook triggered for TestWithHook!');
  request.object.set('beforeSaveRan', true);
  return request.object;
});

Parse.Cloud.afterSave('TestObject', (request) => {
  console.log(`TestObject saved with id: ${request.object.id}`);
});

// Test trigger for User class
Parse.Cloud.beforeSave(Parse.User, (request) => {
  if (request.object.isNew()) {
    console.log(`New user being created: ${request.object.get('username')}`);
  }
});

// --------------------------------------------------------------------
// Analytics-adapter test plumbing. The adapter (loaded via
// PARSE_SERVER_ANALYTICS_ADAPTER -> /parse-server/cloud/analytics-adapter.js)
// pushes every trackEvent / appOpened call onto a Node-global ring
// buffer. These two Cloud functions are the only way the Ruby
// integration test drains and clears that buffer.
//
// Both require the master key — the captured records can contain
// session tokens (we capture req.info.sessionToken so the test can
// pin the v5.0 session_token-opt-as-header contract), and exposing
// them to a client-mode caller would let a drive-by attacker harvest
// every token that's hit /events on this server.
// --------------------------------------------------------------------
Parse.Cloud.define('getCapturedAnalyticsEvents', () => {
  return global.__parseTestCapturedAnalytics || [];
}, { requireMaster: true });

Parse.Cloud.define('resetCapturedAnalyticsEvents', () => {
  const prior = (global.__parseTestCapturedAnalytics || []).length;
  global.__parseTestCapturedAnalytics = [];
  return { cleared: prior };
}, { requireMaster: true });

// --------------------------------------------------------------------
// Error-path fixtures for cloud-function error-scenario coverage
// (integration: test/lib/parse/cloud_function_errors_integration_test.rb).
// Each surfaces a distinct failure mode the SDK must map onto
// Parse::Error::CloudCodeError with the correct code / message /
// http_status. Editing these requires a Parse Server restart to reload
// cloud code (it is read at boot from the mounted volume).
// --------------------------------------------------------------------

// A bare JavaScript throw. Parse Server wraps any non-Parse.Error thrown
// from cloud code as SCRIPT_FAILED (Parse error code 141).
Parse.Cloud.define('boomGeneric', () => {
  throw new Error('generic failure from cloud code');
});

// A typed Parse.Error with a standard Parse error code
// (INVALID_QUERY = 102). Pins that the SDK reads the wire code rather
// than forcing every cloud failure to 141.
Parse.Cloud.define('boomParseError', () => {
  throw new Parse.Error(Parse.Error.INVALID_QUERY, 'typed parse error from cloud code');
});

// A Parse.Error carrying an application-defined numeric code. Proves the
// SDK propagates non-standard codes verbatim instead of collapsing them
// to a generic value.
Parse.Cloud.define('boomCustomCode', () => {
  throw new Parse.Error(4242, 'custom application error code');
});

// Conditional failure: succeeds, or throws, based on a request param —
// one fixture exercises both the happy and the error branch so a test
// can prove the SAME function name reports success and failure cleanly.
Parse.Cloud.define('maybeBoom', (request) => {
  if (request.params.fail) {
    throw new Parse.Error(Parse.Error.VALIDATION_ERROR, 'asked to fail');
  }
  return { ok: true };
});

// beforeSave validation that rejects writes failing a business rule. A
// save of ValidatedThing without a positive numeric `amount` must be
// blocked, with the cloud error surfaced to the SDK's save path.
Parse.Cloud.beforeSave('ValidatedThing', (request) => {
  const amount = request.object.get('amount');
  if (typeof amount !== 'number' || amount <= 0) {
    throw new Parse.Error(Parse.Error.VALIDATION_ERROR, 'amount must be a positive number');
  }
});