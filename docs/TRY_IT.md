# Trying Doorman with nothing real at stake

The demo site is a pretend website with fake passwords. It needs the source and Node.

## 1. Start it

```bash
make install
```

```bash
make demo
```

Open Doorman from the key in your menu bar. Under **Get started**, click **Try the demo site**, then **Save with Touch ID**. Connect a browser and an agent as the README describes.

## 2. Ask an agent to sign in

Open one of these in Chrome and ask the agent to sign in. For example: "Sign in to http://localhost:8765/password/login using Doorman."

| Page | What should happen |
|---|---|
| `/password/login` | Popup, Touch ID, signed in |
| `/picker/login` | Nothing to fill. The agent picks the account, then calls `sign_in` again |
| `/totp/login` | After the password, Doorman asks you for the code. Type `424242` into Doorman, not to the agent |
| `/twostep/login` | Login name first, password on the next page |
| `/emailcode/login` | Doorman reads the code from the demo mailbox |
| `/split/login` | The same, in six separate boxes |
| `/emaillink/login` | Doorman opens the link in the same tab |
| `/controlled/login` | Works on a page that only reads input events, like React |
| `/captcha/login` | Stops and returns `needs_you` |
| `/redirect/login` | Stops when the site sends it to another host |
| Any of them, click **Deny** | Nothing is typed, and the agent gets `denied` |

Then look at **Activity**, and ask the agent what it was told. It should only know a status.

## 3. Apple Passwords, still with fake details

1. In the Passwords app, add an entry: website `doorman-test.example.com`, username `demo@doorman.test`, password `demo-password-1234`.
2. In Doorman, go to **Apple Passwords** and pair. Under **Look up a site**, try `doorman-test.example.com`. You should see the username and no password.
3. Open the **Demo site** app. On **Demo password**, change Password to **Apple Passwords**, set the site to `doorman-test.example.com`, and save.
4. Ask the agent to sign in to `/password/login` again. The popup warns that the entry isn't for this site, which is right here.

## 4. Claude's browser

Under **Browsers**, click **Allow in System Settings** and turn on Doorman. Turn on **Use Accessibility for Claude's browser** and save. Show Claude's browser on a sign-in page, then click **Check Claude's browser** to see what your Mac exposes.
