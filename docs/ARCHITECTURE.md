# How Doorman is put together

Doorman is a Mac menu bar app. Agents reach it through a small MCP server, and browsers reach it through an extension and a native messaging host.

```
 agent (Claude Code, etc.)
   | stdio, MCP
 doorman-mcp ------------+
                         | unix socket (0600), newline JSON
 Chrome + extension      |
   | native messaging    |
 doorman-host -----------+--> Doorman.app (menu bar)
                               SignInEngine
                                 Resolver         address -> app, role, account
                                 Approver         popup and Touch ID
                                 PasswordSource   Apple Passwords, or stored in Doorman
                                 MailSource       Gmail or IMAP
                                 BrowserAdapter   extension, hidden Chrome, Accessibility
```

## Rules the design keeps

1. **No tool returns a secret.** The agent API has no field that can carry one, and the e2e checks everything the agent received for the real values.
2. **Every account asks first by default,** in Doorman's own window. Not in an agent's permission prompt, because some agents can skip those. Approve takes Touch ID, or a click when Apple Passwords will ask for Touch ID next. You can turn the popup off per account, which is a settings change, so it takes Touch ID. A site you haven't added always asks.
3. **The page's real address decides the site, not the agent.** The host has to match a tab the browser reports, and it picks the app. The role comes from the path the agent gives, or a name it asks for, which the prompt shows. An agent's stated reason is shown as not verified.
4. **No AI inside the app, and the agent does the thinking.** The agent can see the page, so it decides when to call `sign_in`, picks accounts, presses Continue, and judges whether it worked. Doorman reports what it did. It only uses plain patterns where the agent must not see the data, like finding a code in an email, so an email or a page can't talk it into anything.
5. **Mail is read narrowly.** Only during an approved sign-in, only from that role's senders, and only for the few minutes after. It's never stored.
6. **Settings are saved with Touch ID, and stored signed.** A change from outside is detected and not used.
7. **No CAPTCHA solving.** Doorman returns `needs_you`.

## Apple Passwords

Apple has no public API. Its helper, `PasswordManagerBrowserExtensionHelper`, refuses any parent that isn't a browser. So:

- Doorman starts a **hidden Chrome** with a private profile, over `--remote-debugging-pipe`, so no port is opened, and loads a small **relay extension**.
- The relay has the extension ID Apple's helper allows, because it carries Apple's public key. It contains none of Apple's code, and only forwards bytes.
- **Doorman does the pairing and encryption itself in Swift:** SRP-3072 and AES-128-GCM, with the protocol read from Apple's extension and checked against it by the fixtures in `scripts/srp_fixture.mjs`. So hidden Chrome never sees a password in the clear.
- Pairing needs the 6-digit code macOS shows. You type it into Doorman.
- A pairing only lasts as long as the helper process. A new helper stays silent about a session it doesn't know, and Apple's own extension starts over on every hello. So Doorman checks a saved pairing with a lookup for a made-up site, and asks you to pair again if nothing answers.

An account can use **Stored in Doorman** instead, a write-only Keychain item, if Apple breaks this.

## Reaching a page

`BrowserAdapter` hides how a page gets filled. The engine finds the window on that site, so an agent doesn't name a browser, though it can state a preference.

| Adapter | Reaches | How it checks the site |
|---|---|---|
| Extension | Your Chrome, Brave or Edge | The browser's own tab address, checked again in the page at the moment of filling |
| Session file | Browsers an agent starts itself | The hidden browser's own tab address |
| Accessibility | Claude's built-in browser, in the app signed by Anthropic | The address Accessibility reports |

## Signing in

A role says how a site signs in: **Password**, **Email code** or **Email link**. It also says where a code comes from if the site asks. The engine watches the page and only acts on what it sees, so 2FA is handled if it appears and skipped if it doesn't. Each kind of step is tried once, because retrying a password can lock an account.
