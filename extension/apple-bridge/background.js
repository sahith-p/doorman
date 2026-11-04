// Forwards messages between Doorman and Apple's password helper. Everything secret is encrypted by
// Doorman before it gets here, so this only ever sees ciphertext and the pairing exchange.
let apple = null;
let doorman = null;

function connectApple() {
  apple = chrome.runtime.connectNative('com.apple.passwordmanager');
  apple.onMessage.addListener((message) => doorman?.postMessage(message));
  apple.onDisconnect.addListener(() => {
    apple = null;
    doorman?.postMessage({ relay: 'apple_disconnected', error: chrome.runtime.lastError?.message || '' });
  });
}

function connectDoorman() {
  doorman = chrome.runtime.connectNative('ai.doorman.host');
  doorman.onMessage.addListener((message) => {
    if (!apple) connectApple();
    apple.postMessage(message);
  });
  doorman.onDisconnect.addListener(() => {
    doorman = null;
    setTimeout(connectDoorman, 1000);
  });
}

connectDoorman();
