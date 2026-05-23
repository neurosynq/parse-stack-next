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