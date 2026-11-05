#!/usr/bin/env node
// A pretend website for trying Doorman with nothing real at stake. Every password and code on it is made
// up. Run it with: node demo/server.mjs   then open http://localhost:8765
import http from 'node:http';
import crypto from 'node:crypto';

const PORT = Number(process.env.DEMO_PORT || 8765);
export const LOGIN = 'demo@doorman.test';
export const PASSWORD = 'demo-password-1234';
export const AUTHENTICATOR_CODE = '424242';
const SENDER = 'codes@doorman.test';

const mail = [];
const codes = new Map(); // scenario -> current emailed code
const tokens = new Set();
const sessions = new Set();
let phishPosts = 0;

const page = (title, body) => `<!doctype html><meta charset=utf-8><title>${title}</title>
<style>:root{color-scheme:light dark}body{font:15px system-ui;max-width:420px;margin:60px auto;padding:0 16px;line-height:1.5}
label{display:block;margin:12px 0 4px}input{font:inherit;padding:8px;width:100%;box-sizing:border-box}
button{font:inherit;padding:8px 14px;margin-top:14px}.err{color:#c33}a{display:block;margin:6px 0}
.split input{width:44px;text-align:center;display:inline-block;margin-right:6px}</style><h1>${title}</h1>${body}`;

const form = (action, fields, error = '') => `${error ? `<p class=err>${error}</p>` : ''}<form method=post action="${action}">${fields}<button type=submit>Continue</button></form>`;
const emailField = `<label for=email>Email</label><input id=email name=email type=email autocomplete=username>`;
const passwordField = `<label for=password>Password</label><input id=password name=password type=password autocomplete=current-password>`;
const codeField = `<label for=code>Verification code</label><input id=code name=code inputmode=numeric autocomplete=one-time-code>`;

function sendCode(scenario) {
  const code = String(crypto.randomInt(100000, 999999));
  codes.set(scenario, code);
  deliver('Your sign-in code', `Your verification code is ${code}. It expires in 10 minutes.`);
}

function deliver(subject, body) {
  const date = new Date().toUTCString().replace('GMT', '+0000');
  const raw = `From: Doorman Demo <${SENDER}>\r\nAuthentication-Results: demo; dmarc=pass header.from=doorman.test\r\nSubject: ${subject}\r\nDate: ${date}\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n${body}\r\n`;
  mail.push({ at: Date.now(), raw });
  if (mail.length > 20) mail.shift();
}

function signedIn(res, scenario) {
  const sid = crypto.randomUUID();
  sessions.add(sid);
  res.writeHead(303, { 'Set-Cookie': `demo_session=${sid}; Path=/; HttpOnly; SameSite=Lax`, Location: `/${scenario}/home` });
  res.end();
}

const send = (res, html, status = 200) => { res.writeHead(status, { 'Content-Type': 'text/html; charset=utf-8' }); res.end(html); };

async function body(req) {
  let text = '';
  for await (const c of req) text += c;
  return Object.fromEntries(new URLSearchParams(text));
}

const scenarios = {
  password: 'Password only',
  totp: 'Password, then an authenticator code',
  twostep: 'Email first, then password on the next page',
  picker: 'A remembered account to pick, then password',
  emailcode: 'Email code',
  split: 'Email code in six little boxes',
  emaillink: 'Email link',
  controlled: 'A page that only reads what you typed through input events',
  captcha: 'A CAPTCHA, which Doorman hands back to you',
  redirect: 'Sends you to another site after the password',
};

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://${req.headers.host}`);
  const path = url.pathname;
  const [, scenario, step] = path.split('/');

  if (path === '/') {
    return send(res, page('Doorman demo site', `<p>Nothing here is real. Sign in with <code>${LOGIN}</code> and <code>${PASSWORD}</code>.</p>`
      + Object.entries(scenarios).map(([k, v]) => `<a href="/${k}/login">${v}</a>`).join('')));
  }
  if (path === '/__mail') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    return res.end(JSON.stringify(mail));
  }
  if (path === '/__reset') {
    mail.length = 0; codes.clear(); tokens.clear(); sessions.clear();
    return res.end('ok');
  }
  if (path === '/__stats') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    return res.end(JSON.stringify({ phishPosts }));
  }
  if (path === '/phish') {
    if (req.method === 'POST') phishPosts += 1;
    return send(res, page('Definitely the real site', form('/phish', passwordField + codeField)));
  }
  if (step === 'home') {
    const sid = /demo_session=([^;]+)/.exec(req.headers.cookie || '')?.[1];
    if (!sessions.has(sid)) { res.writeHead(303, { Location: `/${scenario}/login` }); return res.end(); }
    return send(res, page('Signed in', `<p>You're signed in to <b>${scenarios[scenario] || scenario}</b>.</p><a href="/">Back to the list</a>`));
  }

  if (req.method === 'GET' && step === 'login') {
    switch (scenario) {
      case 'password': case 'totp': case 'redirect':
        return send(res, page(scenarios[scenario], form(`/${scenario}/login`, emailField + passwordField)));
      case 'picker':
        // The decoy matters: a button that mentions the login but would remove it must never be clicked.
        return send(res, page('Sign in: pick your account', `<form method=post action="/picker/choose"><button type=submit>${LOGIN}</button></form>
<form method=post action="/picker/remove"><button type=submit>Remove ${LOGIN}</button></form><a href="/password/login">Use another email</a>`));
      case 'twostep': case 'emailcode': case 'split': case 'emaillink':
        return send(res, page(scenarios[scenario], form(`/${scenario}/login`, emailField)));
      case 'captcha':
        return send(res, page(scenarios[scenario], form(`/${scenario}/login`, emailField + passwordField + `<div class=g-recaptcha style="width:300px;height:74px;border:1px solid #888;margin:12px 0">I'm not a robot</div>`)));
      case 'controlled':
        return send(res, page(scenarios[scenario], `<div id=app>
          <label for=email>Email</label><input id=email type=email autocomplete=username>
          <label for=password>Password</label><input id=password type=password>
          <button type=button id=go>Sign in</button><p class=err id=err></p></div>
          <script>const state={email:'',password:''};
          email.addEventListener('input',e=>state.email=e.target.value);password.addEventListener('input',e=>state.password=e.target.value);
          go.addEventListener('click',async()=>{const r=await fetch('/controlled/login',{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:new URLSearchParams(state),redirect:'follow'});
          if(r.redirected)location.href=r.url;else err.textContent='Wrong email or password.'});</script>`));
      default:
    }
  }

  if (req.method === 'POST') {
    const f = await body(req);
    switch (`${scenario}/${step}`) {
      case 'password/login': case 'controlled/login':
        if (f.email === LOGIN && f.password === PASSWORD) return signedIn(res, scenario);
        return send(res, page(scenarios[scenario], form(`/${scenario}/login`, emailField + passwordField, 'Wrong email or password.')), 401);
      case 'redirect/login':
        res.writeHead(303, { Location: `http://127.0.0.1:${PORT}/phish` });
        return res.end();
      case 'totp/login':
        if (f.email === LOGIN && f.password === PASSWORD) return send(res, page('Two-step verification', `<p>The demo's code is always <code>${AUTHENTICATOR_CODE}</code>.</p>` + form('/totp/code', codeField)));
        return send(res, page(scenarios.totp, form('/totp/login', emailField + passwordField, 'Wrong email or password.')), 401);
      case 'totp/code':
        if (f.code === AUTHENTICATOR_CODE) return signedIn(res, 'totp');
        return send(res, page('Two-step verification', form('/totp/code', codeField, 'That code is wrong.')), 401);
      case 'picker/choose':
        return send(res, page('Enter your password', form('/picker/password', `<input type=hidden name=email value="${LOGIN}">` + passwordField)));
      case 'picker/password':
        if (f.email === LOGIN && f.password === PASSWORD) return signedIn(res, 'picker');
        return send(res, page('Enter your password', form('/picker/password', `<input type=hidden name=email value="${LOGIN}">` + passwordField, 'Wrong password.')));
      case 'picker/remove':
        return send(res, page('Removed', '<p>That account was removed from this list.</p>'));
      case 'twostep/login':
        return send(res, page('Enter your password', form('/twostep/password', `<input type=hidden name=email value="${f.email}">` + passwordField)));
      case 'twostep/password':
        if (f.email === LOGIN && f.password === PASSWORD) return signedIn(res, 'twostep');
        return send(res, page('Enter your password', form('/twostep/password', `<input type=hidden name=email value="${f.email}">` + passwordField, 'Wrong password.')), 401);
      case 'emailcode/login':
        sendCode('emailcode');
        return send(res, page('Check your email', form('/emailcode/code', codeField)));
      case 'emailcode/code':
        if (f.code && f.code === codes.get('emailcode')) return signedIn(res, 'emailcode');
        return send(res, page('Check your email', form('/emailcode/code', codeField, 'That code is wrong.')), 401);
      case 'split/login':
        sendCode('split');
        return send(res, page('Check your email', form('/split/code', `<label>Code</label><div class=split>${[0, 1, 2, 3, 4, 5].map((i) => `<input name=d${i} maxlength=1 inputmode=numeric aria-label="Digit ${i + 1}">`).join('')}</div>`)));
      case 'split/code': {
        const typed = [0, 1, 2, 3, 4, 5].map((i) => f[`d${i}`] || '').join('');
        if (typed === codes.get('split')) return signedIn(res, 'split');
        return send(res, page('Check your email', '<p class=err>That code is wrong.</p>'), 401);
      }
      case 'emaillink/login': {
        const token = crypto.randomUUID();
        tokens.add(token);
        deliver('Sign in to the demo', `Click to sign in: http://localhost:${PORT}/emaillink/verify?token=${token}\nOur privacy policy: http://localhost:${PORT}/privacy`);
        return send(res, page('Check your email', '<p>We sent you a link.</p>'));
      }
      default:
    }
  }
  if (req.method === 'GET' && `${scenario}/${step}` === 'emaillink/verify') {
    if (tokens.delete(url.searchParams.get('token'))) return signedIn(res, 'emaillink');
    return send(res, page('That link has expired', ''), 401);
  }
  send(res, page('Not found', ''), 404);
});

server.listen(PORT, '127.0.0.1', () => console.log(`Doorman demo site on http://localhost:${PORT}`));
