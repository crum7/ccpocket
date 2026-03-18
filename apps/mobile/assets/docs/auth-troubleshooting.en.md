# Claude Authentication Troubleshooting

CC Pocket uses the Claude Code login state stored on your Bridge machine.
If authentication fails, sign in to Claude Code again on that machine.

## Recommended Fix

On the **Bridge machine**:

1. Start Claude Code with `claude`
2. Run `/login`
3. Complete the browser sign-in flow

CC Pocket will use the updated login on the next request.

## Shell Alternative

If you prefer, you can also run:

```bash
claude auth login
```

## When This Happens

- Your Claude login expired
- Claude Code was updated and the old login became invalid
- Anthropic revoked the saved token

## Headless / SSH Setup

If the Bridge machine is remote:

1. SSH into the machine from a terminal app
2. Run `claude`
3. Type `/login`
4. Open the displayed URL on your phone or PC
5. Finish sign-in and paste the result back into the terminal
