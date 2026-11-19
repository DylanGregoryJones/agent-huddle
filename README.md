# Agent Huddle

## What it is
A small floating panel that lists your Claude Code sessions running in Terminal.
When one needs permission, you can click Allow or Deny right there.

## Moving it
Drag it by its top bar (where it says "Agent huddle") to move it, onto any of
your screens. It stays where you leave it, even after a restart.

## What you need
- macOS 14 (Sonoma) or later. Works on Apple silicon and Intel Macs.
- Apple's developer tools, which Agent Huddle is built with. If you don't have
  them, the installer tells you. In Terminal, run `xcode-select --install`, click
  **Install**, wait for it to finish, then double-click the installer again.
- Claude Code, running in Terminal.

## Install
1. Get this folder into your home folder as `agent-huddle`. In Terminal, run:
   `git clone https://github.com/DylanGregoryJones/agent-huddle.git ~/agent-huddle`
   (GitHub will ask you to sign in, and you need to have been added to the repo.)
2. In Finder, open `agent-huddle` in your home folder.
3. Double-click **Install Agent Huddle.command**.
4. If macOS asks whether to open it, click **Open**.
5. Wait for "Agent Huddle is installed".

After installing, macOS may show a "Background Items Added" notification (it may be listed as "open"). That is Agent Huddle's start-at-login item and it is safe.

## First time you click `>_`
macOS asks whether "Agent Huddle" may control "Terminal". Click **OK**.
If the Terminal tab doesn't come forward, click `>_` again after allowing.

If the row says "Allow Agent Huddle to control Terminal in System Settings ›
Privacy & Security › Automation" (for example after clicking **Don't Allow**):
1. Open **System Settings**.
2. Click **Privacy & Security**, then **Automation**.
3. Under **Agent Huddle**, switch on **Terminal**.
4. Click `>_` again.

## Which sessions get buttons
Claude sessions started after install get Allow and Deny. Ones that were already
open show their status and say "answer in Terminal".

## If the panel says "Permission buttons off"
- **Permission buttons off · reinstall**: your Claude settings no longer include
  Agent Huddle (another app may have rewritten them). Double-click
  **Install Agent Huddle.command** again. Claude sessions you start after that
  get Allow and Deny.
- **Permission buttons off · retrying**: the panel couldn't set up its
  connection and tries again every 30 seconds. If the note is still there after
  a minute, double-click **Install Agent Huddle.command** again (it restarts
  the panel).

Until then, answer permission prompts in Terminal as usual.

## What each agent is working towards
Click a row to open it. At the top it says, in a sentence or two, what that
session is working towards. Claude writes this the first time you open the row
(it takes a few seconds and uses a little of your Claude usage), and again
after you've sent that session new messages.

## Hiding it
The X hides it. To bring it back, press **Control-Option-A** (⌃⌥A) in any app,
or open Agent Huddle from Spotlight (⌘Space, type "Agent Huddle", press Return).
Press ⌃⌥A again to hide it.

While it's hidden it keeps running quietly: Terminal still asks for permissions
as normal, and anything waiting is on the panel when you bring it back. It never
pops up by itself, so it's safe to hide before you share your screen.

## Removing it
Double-click **Uninstall Agent Huddle.command**.

Claude sessions that were already open keep looking for Agent Huddle until you
close them and start them again, so when they ask for permission they may show
a hook error. That's harmless: answer the prompt in Terminal as usual.

## Never edit settings files by hand
Install and Uninstall look after your Claude settings safely, and keep a backup
first. Please don't edit those files yourself.
