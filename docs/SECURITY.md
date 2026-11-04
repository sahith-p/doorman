# Doorman: what it protects, and what it doesn't


## The goal

An agent should get signed in without ever holding a password or code, and you should approve sign-ins.
That limits what a tricked agent can do with a page or an email telling it to misbehave.

## What it does

| Risk | What stops it |
|---|---|
| An agent reads a password from a tool result | The agent API has no field that can carry one. `Secret` can't be printed or encoded. The e2e checks everything the agent received for the real values |
| A page tells an agent to sign in somewhere | A popup names the site and login. A site you haven't added always asks, and you can turn that route off or list sites it must never use |
| An agent probing which sites you have logins on | Lookups are limited to 10 a minute, and listed in Activity |
| A lookalike or redirected site gets the password | The host must match exactly, including the port. It's checked by the engine and again in the page at the moment of filling |
| A site downgraded to http | Refused, except on this Mac |
| A forged email | Exactly one plain From address, and your own mail server must have recorded DMARC or DKIM passing for that domain. A message with no such record doesn't count |
| A sign-in link pointing elsewhere | Only allowed hosts are opened |
| A wrong password locking an account | Each step is tried once |
| An agent edits the settings file to remove the tap | The file is signed with a Keychain key, so the change is detected and sign-ins stop until you review it |
| An agent clicks through Settings with screen control | Every save needs Touch ID |
| A program pretending to be the browser | The kernel names whoever connected. It must match the content hash of Doorman's own host, recorded when Doorman starts, and its direct parent must be a browser signed by that browser's real developer, so a wrapper in between doesn't pass |
| A rogue host asking the extension for your cookies | The extension in your Chrome has no cookie permission and refuses. Only Doorman's throwaway hidden browser can export a session |
| A late write reaching the wrong connection | Nothing can be written once a connection closes, so a reused socket can't receive a password |
| An old settings file and its valid signature put back | A save counter in the Keychain catches it |
| A login or code typed into an ordinary page | A lone email or code box only counts once the page reads like a sign-in or a sign-in has started. Change-password forms aren't filled |
| Replies from Apple's helper swapped between sites | One question at a time, and an answer has to be for the site that was asked about |
| An agent flooding you with prompts | Two can wait. More are refused |
| An agent writing a persuasive name or reason | The name is reduced to a short plain label, and the reason is cut short and marked as not verified |
| AI inside the app being talked around | There isn't any. Mail and pages are read with plain patterns |

## What it doesn't do

**An agent with a shell runs as you.** This raises the bar and leaves a trail. It isn't a sandbox. Known gaps:

- **No popup removes the human check.** Turning it on for an account means any agent that can reach Doorman can
  sign in to that account without asking you, including one tricked by a page or an email. It's off by default,
  it's per account, and every sign-in still shows in the corner and in Activity. Keep it to test accounts.

- **While a field is filled, the password is in the page.** With the Chrome extension or Accessibility, an
  agent attached to that same tab could read it in the moment before the form submits. `sign_in` doesn't
  stop an agent running a second tool at the same time. Session files avoid this, because no agent is
  attached during sign-in.
- **A fake browser extension.** Doorman's extension key is public. A determined agent could start its own
  signed Chrome with a modified copy, tell Doorman a tab is on your site, and receive the password after you
  tap. You'd have to approve a prompt you didn't expect, which is why the prompt says which browser and page.
  A per-profile pairing step would close most of this, and it's the first thing to add.
- **A rogue native host.** The file telling Chrome which host to start can be edited by anything running as you.
  Doorman refuses that host's connection, but the extension would still talk to it. It can no longer get cookies,
  but it can list open tabs' addresses and fill or navigate pages with what it already knows.
- **The Keychain key can be replaced.** Without a Developer ID, Doorman can't use the protected part of the
  Keychain. A program running as you might be able to delete the signing key and add its own, which would let it
  forge settings. This hasn't been tested. A Developer ID build would close it.
- **After sign-in, the agent has the session.** It can do whatever that account can until the session ends.
  Approving a superadmin login gives the agent superadmin. Use a role warning, and prefer a test account.
- **Session files are live logins.** They're owner-only and deleted after 15 minutes, but until then anything
  running as you can read one.
- **Reaching Apple Passwords is unofficial.** It uses Apple's private browser helper, so an update could break
  it. Doorman could technically ask for any entry once paired. It only reads a password for the login you
  approved, and it records that.
- **An agent can learn which sites you use.** With sites you haven't added, the answer shows whether you have a
  login on a site, even if you never approve anything. Lookups are limited and logged, but not hidden.
- **Same-origin attacks.** If the real site has a script injection, that script can read what's filled, as with
  any password manager.
- **No Developer ID.** Builds are ad hoc signed. macOS asks again for Keychain and Accessibility access after each
  update, and the Keychain's protection is tied to that signature.

## What Doorman won't do by design

Solve CAPTCHAs, retry a refused password, read mail outside an approved sign-in, keep mail, show a stored
password, or return a secret to an agent.
