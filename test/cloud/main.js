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