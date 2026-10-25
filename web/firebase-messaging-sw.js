/* Firebase Messaging service worker for web push.
 * Fill in your web app's Firebase config and keep it in sync with index.html.
 */
importScripts('https://www.gstatic.com/firebasejs/10.14.1/firebase-app-compat.js');
importScripts('https://www.gstatic.com/firebasejs/10.14.1/firebase-messaging-compat.js');

const firebaseConfig = {
  apiKey: 'TODO_REPLACE',
  authDomain: 'TODO_REPLACE',
  projectId: 'TODO_REPLACE',
  storageBucket: 'TODO_REPLACE',
  messagingSenderId: '892815395656',
  appId: 'TODO_REPLACE',
};

const isConfigured = !Object.values(firebaseConfig).some(
  (value) => typeof value === 'string' && value.includes('TODO_REPLACE'),
);

if (isConfigured) {
  firebase.initializeApp(firebaseConfig);
  const messaging = firebase.messaging();

  messaging.onBackgroundMessage((payload) => {
    const title = (payload.notification && payload.notification.title) || 'New Message';
    const options = {
      body: (payload.notification && payload.notification.body) || 'You have a new notification',
      icon: '/icons/Icon-192.png',
    };
    self.registration.showNotification(title, options);
  });
}
