// Doorman's page side. It connects to the Doorman app and does what the app asks: list tabs, look at a
// page, fill a field. Secrets arrive from the app, go into the page, and are never stored here.
let port = null;
let retry = 1000;

function connect() {
  if (port) return;
  port = chrome.runtime.connectNative('ai.doorman.host');
  port.onMessage.addListener(async (message) => {
    retry = 1000;
    let reply;
    try {
      reply = { id: message.id, ok: true, result: await handle(message) };
    } catch (error) {
      reply = { id: message.id, ok: false, error: String(error?.message || error) };
    }
    // Never send a filled value back. `result` only ever holds page facts.
    port?.postMessage(reply);
  });
  port.onDisconnect.addListener(() => {
    port = null;
    setTimeout(connect, retry);
    retry = Math.min(retry * 2, 30000);
  });
}

// Runs inside the page, in the extension's isolated world. It can't see page variables, and the page
// can't see it. `action` is one of: inspect, fillLogin, fillCode.
function pageAction(action, args) {
  const visible = (el) => {
    if (!el || el.disabled || el.readOnly) return false;
    const style = getComputedStyle(el);
    if (style.visibility === 'hidden' || style.display === 'none' || Number(style.opacity) === 0) return false;
    const box = el.getBoundingClientRect();
    return box.width > 1 && box.height > 1;
  };
  const words = (el) => [el.name, el.id, el.placeholder, el.getAttribute('autocomplete'), el.getAttribute('aria-label'),
    el.labels?.[0]?.textContent, el.getAttribute('data-testid')].filter(Boolean).join(' ').toLowerCase();
  // Includes open shadow DOM, which plenty of sign-in pages use.
  const deep = (root, selector) => {
    const out = [...root.querySelectorAll(selector)];
    for (const el of root.querySelectorAll('*')) if (el.shadowRoot) out.push(...deep(el.shadowRoot, selector));
    return out;
  };
  const inputs = () => deep(document, 'input').filter(visible);
  const textLike = (el) => ['text', 'email', 'tel', 'number', ''].includes((el.getAttribute('type') || '').toLowerCase());

  // One password box is a sign-in. Two or more, or one marked for a new password, is a sign-up or a
  // change-password form, and Doorman has no business filling those.
  const password = () => {
    const boxes = inputs().filter((el) => el.type === 'password');
    if (boxes.length !== 1 || boxes[0].getAttribute('autocomplete') === 'new-password') return null;
    return boxes[0];
  };

  const splitCode = () => {
    // Six little boxes, one digit each.
    const boxes = inputs().filter((el) => textLike(el) && el.maxLength === 1);
    return boxes.length >= 4 && boxes.length <= 8 ? boxes : null;
  };

  const codeRe = /(one[-_ ]?time|otp|2fa|mfa|two[-_ ]?factor|verification|verify|passcode|security[-_ ]?code|auth(entication)?[-_ ]?code|\bcode\b|\btoken\b)/;
  const codeField = () => {
    const auto = inputs().find((el) => el.getAttribute('autocomplete') === 'one-time-code');
    if (auto) return auto;
    if (password()) return null;
    return inputs().find((el) => textLike(el) && codeRe.test(words(el)) && !/(zip|postal|country|promo|coupon|invite|referral)/.test(words(el))) || null;
  };

  const usernameRe = /(user|login|email|e-mail|account|identifier)/;
  const usernameField = () => {
    const pw = password();
    const candidates = inputs().filter((el) => textLike(el) && el !== codeField() && !(splitCode() || []).includes(el));
    const named = candidates.find((el) => ['username', 'email'].includes(el.getAttribute('autocomplete')) || el.type === 'email' || usernameRe.test(words(el)));
    if (named && !/(search|filter|query)/.test(words(named))) return named;
    if (pw) {
      // The text box just before the password box in the same form.
      const form = pw.form;
      const inForm = candidates.filter((el) => el.form === form);
      return inForm[inForm.length - 1] || null;
    }
    return null;
  };

  const setValue = (el, value) => {
    el.focus();
    const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
    setter.call(el, value);
    el.dispatchEvent(new InputEvent('input', { bubbles: true, data: value, inputType: 'insertText' }));
    el.dispatchEvent(new Event('change', { bubbles: true }));
  };

  const label = (b) => (b.textContent || b.value || b.getAttribute('aria-label') || '').trim();
  const goRe = /(sign[- ]?in|log[- ]?in|continue|next|verify|submit|confirm|enter|send)/i;
  const notThisRe = /(cancel|back|forgot|reset|sign[- ]?up|register|create|delete|remove|google|microsoft|apple|github|sso|passkey|show|hide)/i;
  const candidates = (scope) => deep(scope, 'button, input[type=submit], [role=button]').filter(visible).filter((b) => !notThisRe.test(label(b)));

  const submit = (el) => {
    const form = el.form;
    if (form) {
      const buttons = candidates(form);
      const pick = buttons.find((b) => goRe.test(label(b))) || buttons.find((b) => (b.getAttribute('type') || 'submit').toLowerCase() === 'submit');
      if (pick) { pick.click(); return; }
      if (form.requestSubmit) { form.requestSubmit(); return; }
    }
    // No form. Only a clearly labelled button close to the field, never just the first one on the page.
    let around = el.parentElement || el.getRootNode().host;
    for (let i = 0; around && i < 5; i += 1) {
      const pick = candidates(around).find((b) => goRe.test(label(b)));
      if (pick) { pick.click(); return; }
      around = around.parentElement || around.getRootNode().host;
    }
    el.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', code: 'Enter', keyCode: 13, bubbles: true }));
  };

  // The real address as this frame sees it, for the app to compare before anything is filled.
  const here = location.href;

  if (action === 'inspect') {
    const captcha = [...document.querySelectorAll('.g-recaptcha, .h-captcha, .cf-turnstile, iframe[src*="recaptcha"], iframe[src*="hcaptcha"], iframe[src*="challenges.cloudflare.com"]')].some(visible);
    return {
      url: here,
      username: Boolean(usernameField()),
      password: Boolean(password()),
      code: Boolean(splitCode() || codeField()),
      captcha,
    };
  }

  // A filling call carries the host it was approved for, checked here at the last moment: a page can
  // navigate between inspect and fill.
  if (location.host !== args.expectedHost) throw new Error('page_moved');
  if (location.protocol !== 'https:' && !['localhost', '127.0.0.1', '[::1]'].includes(location.hostname)) throw new Error('page_not_https');

  if (action === 'fillLogin') {
    const user = args.username != null ? usernameField() : null;
    const pw = args.password != null ? password() : null;
    if (args.username != null && !user && args.password == null) throw new Error('no_username_field');
    if (args.password != null && !pw) throw new Error('no_password_field');
    if (user) setValue(user, args.username);
    if (pw) setValue(pw, args.password);
    if (args.submit) submit(pw || user);
    return { filled: true };
  }

  if (action === 'fillCode') {
    const boxes = splitCode();
    if (boxes) {
      const chars = [...args.code];
      boxes.forEach((box, i) => setValue(box, chars[i] || ''));
      if (args.submit) submit(boxes[boxes.length - 1]);
      return { filled: true };
    }
    const el = codeField();
    if (!el) throw new Error('no_code_field');
    setValue(el, args.code);
    if (args.submit) submit(el);
    return { filled: true };
  }
  throw new Error('unknown_action');
}

async function run(tabId, action, args) {
  const [frame] = await chrome.scripting.executeScript({ target: { tabId }, func: pageAction, args: [action, args || {}] });
  if (!frame) throw new Error('no_frame');
  if (frame.error) throw new Error(frame.error.message || String(frame.error));
  return frame.result;
}

async function handle(message) {
  switch (message.cmd) {
    case 'ping':
      return { pong: true };
    case 'tabs': {
      const tabs = await chrome.tabs.query({});
      return tabs.filter((t) => t.url && /^https?:/.test(t.url)).map((t) => ({
        id: String(t.id), url: t.url, title: t.title || '', active: Boolean(t.active),
      }));
    }
    case 'closeTabs': {
      // Only used by the end-to-end test, on the demo host.
      const tabs = await chrome.tabs.query({});
      const ids = tabs.filter((t) => { try { const h = new URL(t.url).host; return h.startsWith('localhost:') || h.startsWith('127.0.0.1:'); } catch { return false; } }).map((t) => t.id);
      if (ids.length) await chrome.tabs.remove(ids);
      return { closed: ids.length };
    }
    case 'open': {
      const tab = await chrome.tabs.create({ url: message.url, active: true });
      return { id: String(tab.id) };
    }
    case 'inspect': {
      const state = await run(Number(message.tab), 'inspect');
      // A password box in an embedded frame. Doorman won't fill it, but it does mean the page isn't
      // signed in, whatever the top page looks like.
      try {
        const frames = await chrome.scripting.executeScript({
          target: { tabId: Number(message.tab), allFrames: true },
          func: () => window !== top && Boolean(document.querySelector('input[type=password]')),
        });
        state.frameLogin = frames.some((f) => f.result === true);
      } catch { state.frameLogin = false; }
      return state;
    }
    case 'fillLogin':
      return await run(Number(message.tab), 'fillLogin', {
        username: message.username ?? null, password: message.password ?? null, submit: Boolean(message.submit), expectedHost: message.expectedHost,
      });
    case 'fillCode':
      return await run(Number(message.tab), 'fillCode', { code: message.code, submit: Boolean(message.submit), expectedHost: message.expectedHost });
    case 'navigate':
      await chrome.tabs.update(Number(message.tab), { url: message.url });
      return { ok: true };
    case 'exportSession': {
      // Playwright's storage state format, for session files. Only Doorman's throwaway hidden browser
      // has the cookies permission, so in your own Chrome this refuses.
      if (!chrome.cookies) throw new Error('not_available_here');
      const tab = await chrome.tabs.get(Number(message.tab));
      const url = new URL(tab.url);
      if (url.host !== message.expectedHost) throw new Error('page_moved');
      const cookies = await chrome.cookies.getAll({ url: tab.url });
      const [frame] = await chrome.scripting.executeScript({
        target: { tabId: tab.id },
        func: () => Object.keys(localStorage).map((name) => ({ name, value: localStorage.getItem(name) })),
      });
      return {
        cookies: cookies.map((c) => ({
          name: c.name, value: c.value, domain: c.domain, path: c.path, expires: c.expirationDate ?? -1, httpOnly: c.httpOnly, secure: c.secure,
          sameSite: { no_restriction: 'None', lax: 'Lax', strict: 'Strict', unspecified: 'Lax' }[c.sameSite] || 'Lax',
        })),
        origins: [{ origin: url.origin, localStorage: frame?.result || [] }],
      };
    }
    default:
      throw new Error('unknown_command');
  }
}

// Chrome suspends idle extensions, which also cancels any retry timer. These wake it back up, so it
// reconnects after Chrome starts and after Doorman restarts.
chrome.runtime.onStartup.addListener(connect);
chrome.runtime.onInstalled.addListener(connect);
chrome.alarms.create('doorman-reconnect', { periodInMinutes: 1 });
chrome.alarms.onAlarm.addListener(connect);

connect();
