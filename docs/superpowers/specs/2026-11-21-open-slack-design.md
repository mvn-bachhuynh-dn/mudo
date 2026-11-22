# Open the Slack thread from a session (iPhone app and widget)

## Goal

A session started from Slack by KiroCrew carries `terminal.slackChannel`, `slackTeam` and `slackThread`. The Mac app opens the channel on click; the iPhone app and widget should too: tap a session, land in Slack.

## Decisions

1. **Link.** `slack://channel?team=<T>&id=<C>` (documented, channel only). With `&message=<thread ts>&thread_ts=<thread ts>` (undocumented by Slack; verified on the owner's iPhone: `message` alone opens only the channel, both open the thread) when the thread is valid. One switch: `SlackLink.mobileThreadParameter` (`public static let`, default true); false opens the channel only, so it can be turned off if the parameter does nothing.
2. **No valid team**: `https://slack.com/app_redirect?channel=<C>`, as on the Mac. Invalid channel: no link.
3. **Team source.** The session's `slackTeam`, else the `slackTeamID` pref (Servers tab, Slack section, free text, stored in the existing prefs Keychain item; an old item without the field still decodes).
4. **App.** A session row with a link is a plain-style `Button` calling `openURL`, with a secondary `arrow.up.right.square` icon at the trailing end. Rows without Slack data stay non-tappable.
5. **Widget (medium, large).** Each row of `SessionList` is a `Link`: the Slack URL, else `mudo://open?tab=sessions`. The earlier single `Link` around the sessions area is removed (no nested links). The empty state keeps a `Link` to the Sessions tab. The compact lock screen variant is unchanged (no links there).

## Tests

`SlackLinkMobileTests` (MuDoCore, Linux): team and thread, thread parameter off (internal `includeThread:` overload), public overload follows the switch, no or invalid team falls back to `app_redirect`, trimmed team, invalid channel nil, invalid thread ignored, session without Slack data nil, session team preferred over the fallback, fallback used otherwise. The SwiftUI parts are compiled by CI only.

## Out of scope

Android, the lock screen, a Slack action in a detail sheet.
