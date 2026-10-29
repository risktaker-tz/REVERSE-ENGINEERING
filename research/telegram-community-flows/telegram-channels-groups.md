# Telegram Groups & Channels — End-to-End Protocol Reverse-Engineering

Verified against the public TL schema (layer 233, `updateChannelParticipant#985d3abb`
era) and observed client behaviour. This document drives RUKA NOW's community
channel/group implementation so that our Supabase-backed communities behave the
way Telegram users already expect.

---

## 1. The three community shapes (not two)

| Shape | TL origin | Who can post | Member cap | Joinable by |
|---|---|---|---|---|
| **Basic group** | `messages.createChat(title, users[])` | everyone | 200 000 | added by a member; invite link |
| **Supergroup (megagroup)** | `channels.createChannel(..., megagroup:flags.0=true)` | everyone (unless `default_banned_rights` says otherwise) | 200 000 | public username, invite link |
| **Broadcast channel** | `channels.createChannel(...)` (no megagroup flag) | admins only (subscribers get `send_messages` banned via `default_banned_rights`) | unlimited | public username, invite link |

RUKA NOW mapping: our `kind: "group"` behaves like a **megagroup**, our
`kind: "channel"` behaves like a **broadcast channel**. (Basic groups and
`messages.migrateChat` are a Telegram-internal optimisation — we start every
group in its "migrated" form, which is what Telegram apps show users anyway.)

## 2. Creation flow, byte-for-byte

1. App collects **title** (+ optional *about*, *photo*, *public username*).
   Telegram's own create sheet defaults to a **private** entity; the public
   username toggle is explicit — we copy this default.
2. Client calls `channels.createChannel(title, about, megagroup)`.
   - `flags.0 = megagroup` (group), `flags.2 = forum` (topics, out of scope).
3. Server answers with an **Updates envelope** containing:
   - `updateNewMessage` with a `messageService` carrying
     `messageActionChannelCreate` (or `messageActionChatCreate` for basic groups)
     — **this service message is the first message of the chat**;
   - the fresh `channel`/`chat` object (with `access_hash` — the join capability
     token);
   - `chats`/`users` vectors.
4. **The client does NOT refetch `messages.getDialogs`.** It synthesises the
   dialog locally from the returned chat object, inserts it at the top of the
   list and opens the chat. We mirror this: `POST /create` returns the dialog
   payload and the store inserts it directly, then calls `loadDialogs()` as a
   background refresh.
5. Creator becomes `channelParticipantCreator` (rank "owner"); rights are
   immutable — only the owner can transfer/delete the entity.
6. Supergroups/channels are created with 1 participant ("you"). Telegram then
   offers to add contacts — for us the *invite* surface serves that role.

**Username rules** (public entities): 5–32 chars, `a-z 0-9 _`, must not start
with a digit, globally unique across the whole network (we enforce globally
unique across RUKA). Setting the username makes `t.me/<username>` resolvable.

## 3. Joining — the four doors

| Door | TL call | Service message the members see |
|---|---|---|
| Public username | `contacts.resolveUsername` → `channels.joinChannel(channel)` | megagroup: `X joined the group`; channel: silent (count bump only) |
| Invite link | `messages.importChatInvite(hash)` → reply `chatInviteAlready` if already member | megagroup: `X joined the group via invite link` (`messageActionChatJoinedByLink`) |
| Added by admin | `channels.editAdmin(channel, user, rights, rank)` used as "add", or `messages.addChatUser` in basic groups | `X added Y` (`messageActionChatAddUser`) |
| Join request | invite with `request_needed=true` → `updateChannelParticipant` pending → `messages.hideChatJoinRequests(approve)` | `X joined the group by request` (`messageActionChatJoinedByRequest`) |

Banned users (`channelParticipantBanned`, `banned_rights.view_messages=true`)
**cannot re-enter** through any door until an admin lifts the ban —
`channels.editBanned` with empty rights restores them. We reproduce exactly
this: banned membership row blocks join-by-username *and* invite-hash join.

Private entities have **no username**: the only doors are invite links and
direct adds. Revoke semantics: `exportChatInvite(revoke=true)` / `editExportedChatInvite`
kills the old hash; every future `importChatInvite(hash)` answers
`INVITE_HASH_EXPIRED`. We model one active hash + `inviteRevokedAt`.

## 4. Roles & rights (the exact model)

`channelParticipantCreator` > `channelParticipantAdmin` > `channelParticipant`.
Admins carry `chatAdminRights` flags:

```
change_info      – edit title/about/photo
post_messages    – channel: publish as the channel
edit_messages    – delete/edit *others'* messages
delete_messages  – delete any message
ban_users        – kick/ban/restrict
invite_users     – add members / manage invites
pin_messages     – pin messages
add_admins       – promote others (owner-only in practice for us)
anonymous        – hide identity in service actions (out of scope v1)
```

`chatBannedRights` flags: `view_messages` (ban), `send_messages` (mute),
`send_media`, `embed_links`, … + `until_date`. Channel default for
subscribers = `send_messages` banned → "only admins can post". We store
`defaultBannedRights` JSON on the channel and check it on every send.

Promotion guard rails copied from Telegram: you cannot promote to a level
≥ your own; admins cannot ban/demote other admins or the owner; the owner is
untouchable. `updateChannelParticipant` carries `actor_id` + `user_id` —
service messages always name **who did what to whom**; we store the actor.

## 5. Member list & counts

- `channels.getParticipants(filter, limit)` with filters `recent`, `admins`,
  `kicked`, `banned`, `search`, `contacts` — paged with an offset.
- `participants_count` is **eventually consistent** (denormalised counter on
  the channel object; updates arrive via `updateChannelParticipant`). We keep
  a `membersCount` column maintained transactionally on join/leave/ban.
- Leaving: `channels.leaveChannel` — in megagroups a service message
  `X left the group` (`messageActionChatDeleteUser` with actor=self) is
  broadcast; broadcast channels stay silent.

## 6. Messaging rules per shape

- **Channel**: subscriber `sendMessage` → server error `CHAT_WRITE_FORBIDDEN`.
  Admin posts appear *as the channel* (`from_id = peerChannel(self)`), signed
  optionally (`signatures` flag) → "views" counter per post
  (`views` on `message`), incremented on read; view counts are what channel
  bubbles show instead of "read" ticks.
- **Megagroup**: everyone posts by default; admin can pin
  (`updateChannelPinnedMessage`), delete others' messages if
  `delete_messages`, etc.
- **Unread state** is per-user: `read_inbox_max_id` / `read_outbox_max_id`
  per dialog. We keep `lastReadMessageId` per member row.
- Service messages (`messageService`) render **centered, gray, italic** in
  every official client and are excluded from unread logic in practice —
  we mark them `kind=service` and skip them in unread counts.

## 7. Updates fan-out (why we poll the way we do)

Telegram pushes `updateNewMessage` / `updateChannelParticipant` over the
socket. RUKA NOW community mode has no socket yet (roadmap item in the main
notes) — `pollActive()` refetches the open peer every few seconds and
`loadDialogs()` refreshes the list after actions, which reproduces the same
end state at slightly higher latency. The community API therefore returns
**complete fresh state** after every mutation (create/join/send), so a single
round-trip updates the UI — the "Updates envelope" pattern in REST form.

## 8. Mapping table — TL → RUKA NOW community API

| Telegram | RUKA NOW endpoint | Notes |
|---|---|---|
| `channels.createChannel` | `POST /api/community/channels` `action:"create"` | returns dialog payload + service msg |
| `contacts.resolveUsername` + `joinChannel` | `POST …/channels` `action:"join" {username}` | 404 `USERNAME_NOT_OCCUPIED` parity |
| `messages.importChatInvite` | `POST …/channels` `action:"join" {inviteHash}` | revoked/expired → 410 |
| `messages.checkChatInvite` | `GET …/channels?username=` (peek) | returns preview without joining |
| `channels.getParticipants` | `GET …/channels/[id]?kind=members&filter=` | filters: recent/admins/banned/search |
| `channels.editAdmin` (promote) | `POST …/channels/[id]` `action:"promote"/"demote"` | rights matrix enforced server-side |
| `channels.editBanned` | `POST …/channels/[id]` `action:"ban"/"unban"/"remove"` | actor recorded in service msg |
| `channels.leaveChannel` | `POST …/channels/[id]` `action:"leave"` | silent for channels |
| `exportChatInvite` / revoke | `POST …/channels/[id]` `action:"invite-export"/"invite-revoke"` | one active hash |
| `channels.editTitle/editAbout/editUsername` | `PATCH …/channels/[id]` | `change_info` right required |
| `messages.getHistory` (channel peer) | `GET /api/community?kind=messages&peerKey=channel:<id>` | views bumped on read |
| `messages.sendMessage` | `POST /api/community` `action:"send"` (channel peerKey) | `CHAT_WRITE_FORBIDDEN` for subscribers |

Error-string parity with Telegram client behaviour:
`USERNAME_NOT_OCCUPIED` (unknown @user), `USER_NOT_PARTICIPANT` (acting on a
chat you're not in), `CHAT_ADMIN_REQUIRED`, `CHAT_WRITE_FORBIDDEN`,
`USER_BANNED_IN_CHANNEL` (banned re-join), `INVITE_HASH_EXPIRED`,
`USERS_TOO_MUCH` (cap), `ABOUT_TOO_LONG`, `USERNAME_INVALID`,
`USERNAME_OCCUPIED`.

## 9. What RUKA NOW deliberately diverges on

1. **One namespace** — our usernames live in the same space as member handles
   (Telegram channels register usernames in a global namespace; ours does the
   RUKA-wide equivalent).
2. **No basic-group/megagroup split** — groups are born supergroups; migration
   is meaningless for us.
3. **Service messages are stored rows** (`kind:"service"`) instead of
   synthesised client-side — cheap, and they survive reloads.
4. **Polling fan-out** instead of MTProto socket updates (documented above).
5. **Join requests** (`request_needed`) are documented but not implemented in
   v1; the door list otherwise matches Telegram 1:1.

## 10. Member interaction — reactions, pins, views, adds (implemented)

Verified against the public TL schema (`messages.sendReaction`,
`channels.updatePinnedMessage` era behaviour) and official client
UX. Everything in this section is enforced **server-side** in
`/api/community` and mirrored optimistically in the store.

### 10.1 Reactions (`messages.sendReaction` parity)

- Storage: `reactionsJson` on the message row —
  `{emoticon: {count, users[]}}`; `chosen` is derived from membership in
  `users[]`, exactly what `messageReactions.recent_reactions` answers.
- Toggle semantics: one reaction set per user per message (chosen flag flips;
  removing the last chooser deletes the key — the empty-map row is nulled).
- Choosers capped at 100 recent users (Telegram keeps a small recent window;
  we keep enough to always answer "did I react?").
- Authorization: requires participation (`USER_NOT_PARTICIPANT` for outsiders);
  banned members are blocked by the membership tombstone.
- Client: optimistic toggle → adopt the server's canonical list on response;
  failure rolls the toggle back.

### 10.2 Pins (`channels.updatePinnedMessage` parity)

- `pinnedAt` timestamp on the message row; unpin nulls it.
- Right required: `pin_messages` (the owner always holds it) — otherwise
  `CHAT_ADMIN_REQUIRED` ("Only admins can pin messages.").
- Fan-out: the pinned bar reads `GET ?kind=pinned&peerKey=` (the
  `channels.getMessages?filter=pinned` equivalent, newest pin first, cap 10).
- Unlike Telegram basic groups, we do **not** post a service message for pins
  (Telegram supergroups/channels don't either).

### 10.3 Views (broadcast channels)

- Subscribers' read passes increment `views` once per unread admin post
  (§6); bubbles render 👁 N instead of delivery ticks when `views` exists —
  including on the admin's own posts, matching official clients.

### 10.4 Adds after create (`channels.inviteToChannel` parity)

- `POST /channels/[id] action:"add"` requires `invite_users`; the added row
  lands with `joinedVia:"added"` and broadcasts `X added Y`
  (`messageActionChatAddUser`).
- UX parity: the create sheet hands straight into an "Add members"
  multi-select (the same sheet Telegram shows after `createChannel`), and the
  info panel's invite card carries a permanent "Add members" action for
  admins.

### 10.5 Join preview (`messages.checkChatInvite` parity)

- Joining by @username or /join/+hash now **peeks first**:
  `GET /channels?kind=peek` returns title/about/members-count/joined/banned;
  the dialog renders a preview card with an explicit Join button — the same
  two-step door Telegram uses for invite links (and public chats via
  resolve-then-preview).

### 10.6 Write gating (`CHAT_WRITE_FORBIDDEN` parity)

- The composer never renders for subscribers of a broadcast channel; a muted
  "Only admins can post in this channel" bar replaces it (the server still
  enforces the same rule on `send` — client gating is UX, not security).
- `canPost` comes from `GET /channels/[id]` (`kind=group` ⇒ always true;
  `kind=channel` ⇒ `post_messages` right or owner), cached per peer in
  `canPostByPeer` and invalidated on leave.

## 11. End-to-end creation flow — wire-level trace (frontend ↔ backend)

Observed 2026-10-29 on the running app (traces captured with curl against
`localhost:3000`; JSON is the exact response body). Every hop is listed in
order so the flow can be re-verified after any refactor.

### 11.1 The complete hop chain

```
[UI]   NewGroupDialog "Create" click
   └─ title/kind/about/public-toggle → store.createGroup(title, kind, opts)
[STORE] useRuka.createGroup
   └─ conn==="community" ? communityApi.create(...)          (cookie auth, no header)
      conn==="live"       ? api.createChannel(sid, ...)      (MTProto box)
      otherwise           ? ensureCommunitySession() re-verify → promote or toast
[CLIENT] POST /api/community/channels  {action:"create", title, kind, about?, username?}
   └─ fetch(credentials:"same-origin") — the sb-* Supabase cookies ride along
[GUARD CHAIN] (in /api/community/channels POST)
   1 requireSameOrigin        → Origin must match host (CSRF)
   2 requireIdentity          → Supabase cookie → app identity (401 "Sign in to continue." if absent)
   3 parseBody(bodySchema)    → zod strict: title 1..128, kind group|channel, username ≤32
   4 rateLimit("community-channels", userId, 20/60s)
   5 usernameError()          → USERNAME_INVALID parity (5–32, a-z0-9_, no leading digit)
   6 username clash check     → 409 "That username is already taken." (USERNAME_OCCUPIED parity)
[DB] single $transaction:
   INSERT communityChannel   (kind, title, about, username, ownerId, membersCount=1,
                              defaultBannedRights: channel ⇒ {"sendMessages":true}, group ⇒ {})
   INSERT communityMember    (role:"owner", joinedVia:"created")   ← channelParticipantCreator
   INSERT communityMessage   (kind:"service", serviceAction:"channel_create"|"chat_create")
                             ← messageActionChannelCreate: the entity's first message
[RESPONSE] Updates-envelope in REST form: {dialog, channel} — complete fresh state
[STORE] inserts the dialog at the TOP of the list (no refetch round-trip,
        mirroring the official client which never re-calls messages.getDialogs
        after channels.createChannel), then openChat("channel:<id>")
[UI]    chat opens; AddMembersDialog sheet appears (inviteToChannel parity)
```

### 11.2 Observed create response (public group)

```json
{
  "dialog": { "peer": { "id": "cmv…", "type": "group", "title": "Trace Group",
      "username": "tr…", "membersCount": 1 },
    "unread": 0, "pinned": false, "muted": false,
    "lastMessage": { "id": 37, "peerKey": "channel:cmv…", "date": 1793272102,
      "out": true, "text": "", "senderName": "Alice K", "service": "Alice K created the group" } },
  "channel": { "id": "cmv…", "kind": "group", "title": "Trace Group",
      "about": "wire trace", "username": "tr…", "inviteHash": null,
      "ownerId": "sb:…", "membersCount": 1, "defaultBannedRights": {} }
}
```

Notes that matter for parity:

- `dialog.lastMessage` **is the service message** — this is what makes
  "X created the group" the first bubble, exactly like `messageService` +
  `messageActionChannelCreate` on Telegram.
- `defaultBannedRights` is the only difference between the two kinds:
  broadcast channels ship `{"sendMessages":true}` (subscribers muted by
  default), megagroups ship `{}` (everyone posts). One column drives all
  write gating.
- The creator's member row is never in the response — the client doesn't
  need it (it knows who it is); the server enforces everything else.

### 11.3 Session survival across the flow (why "sign in to create" can lie)

The Supabase access token lives ~1 h; `@supabase/ssr` **rotates the cookie on
server-side refresh**. Observed live: a saved curl jar went from 200 → 401
`"Sign in to continue."` mid-session after the server refreshed the session —
the browser keeps working because each response's `Set-Cookie` updates the
jar automatically. The store therefore re-verifies the cookie session
(`ensureCommunitySession()`) before ever claiming the user is signed out, and
a stale `conn` can never produce a false "sign in to create" toast.

## 12. Member joining — end-to-end wire traces

### 12.1 Peek (messages.checkChatInvite parity) — door preview

`GET /api/community/channels?kind=peek&username=<u>` — **no join happens**:

```json
{ "channel": { "id": "cmv…", "kind": "group", "title": "Trace Group",
    "about": "wire trace", "username": "tr…", "membersCount": 1 },
  "joined": true, "banned": false }
```

`joined` / `banned` let the dialog render the correct door state: Join button,
"already a member", or the banned tombstone (`USER_BANNED_IN_CHANNEL` parity —
the server re-checks on the actual join anyway; peek is UX, not security).

### 12.2 Join by public username (resolveUsername + joinChannel parity)

`POST /api/community/channels {action:"join", username}` inside one transaction:

```
guard chain: sameOrigin → identity → schema → rateLimit(20/60s) → usernameError
lookup:      communityChannel.findFirst({username})            → 404 USERNAME_NOT_OCCUPIED
membership:  banned row?                                       → 403 "You were removed from this community."
already in?  return the dialog with joined:true (idempotent — matches
             chatInviteAlready vs chatInvite semantics without an error)
capacity:    membersCount >= MEMBER_CAP                        → 400 "This community is full." (USERS_TOO_MUCH parity)
transaction: INSERT member (role:"member", joinedVia:"username")
             UPDATE channel membersCount = membersCount + 1    (denormalised counter)
             kind==="group" ? INSERT service message "joined"
                            : silent (broadcast channels only move the count)
response:    complete fresh {dialog, joined:true}
```

Observed: `membersCount` went 1 → 2 and Bob's dialog list picked the group up
on his next `loadDialogs()`; the megagroup showed "Bob M joined the group".

### 12.3 Join by invite hash (messages.importChatInvite parity)

Same endpoint with `inviteHash` instead of `username`. Differences:

- Lookup by the hash column; a channel whose `inviteHash` was **revoked**
  (`inviteRevokedAt` set, hash nulled) answers **410** "This invite link was
  revoked by an admin." — `INVITE_HASH_EXPIRED` parity.
- `joinedVia:"invite"`; megagroups post "joined via invite link"
  (`messageActionChatJoinedByLink` parity); channels stay silent.

### 12.4 What joining never does

- It never posts to the channel (subscribers still can't — §10.6).
- It never leaks private entities: a private channel has no username row, so
  peek-by-username 404s exactly like `USERNAME_NOT_OCCUPIED`.
- It never double-counts: the `(channelId, userId)` unique index makes the
  member row the single source of truth; the counter is maintained only in
  the same transaction that inserts the row.

## 13. Member interaction — the enforcement chain, end to end

Every mutation (`POST /api/community`) runs the same guard order; the chain
is the security model, so it is written down verbatim:

```
1 requireSameOrigin        CSRF
2 requireIdentity          cookie → identity (401 on absent/revoked session)
3 parseBody                zod .strict() — unknown fields rejected
4 rateLimit(60/60s/user)   flood control (server-side, not client UX)
5 body validation          "Write a message first." / "Choose a message."
6 peer routing             /^(channel|group):/ → community branch; user: → threads branch
   community branch:
   6a react     → loadMembership (participation + ban check) → toggle in reactionsJson
   6b pin/unpin → loadMembership → rights.pinMessages || owner  → pinnedAt set/null
   6c send      → requireMember (defaultBannedRights + mutedUntil + postMessages)
   6d edit      → own always; others' requires rights.editMessages
   6e delete    → own always; any message requires rights.deleteMessages
   7 canonical response — the client adopts the server's rendering, never its own
```

Rights evaluation uses **short-circuit semantics identical to Telegram**:
the default-banned-rights check runs *before* per-admin rights, a muted admin
with `post_messages` still wins (mute ≠ ban for admins), and the owner passes
every right implicitly. Observed in the regression run: subscriber send →
403 `"Only admins can post in this channel."` while the same member reacts
and reads without restriction — the exact `CHAT_WRITE_FORBIDDEN` vs
`messages.sendReaction` split Telegram makes.

### 13.1 Observed interaction traces (2026-10-29 regression)

| Action | Request | Response (exact) |
|---|---|---|
| React | `action:"react", msgId, emoticon:"👍"` | `{"reactions":[{"emoticon":"👍","count":1,"chosen":true}]}` |
| Pin | `action:"pin", ids:[34]` | `{"ok":true}` |
| Pinned bar | `GET ?kind=pinned&peerKey=channel:<id>` | newest pin first, service rows excluded |
| Edit about | `PATCH /channels/[id] {"about":…}` | full fresh `channel` object (`change_info` right) |
| Members | `GET /channels/[id]?kind=members` | `{members:[{role:"owner",rank:"owner",joinedVia:"created",me:true,…}]}` |
| Subscriber send | `action:"send"` on channel peer | `403 {"error":"Only admins can post in this channel."}` |

### 13.2 Fan-out after each interaction

Telegram pushes `updateSendMessageReaction` / `updateChannelPinnedMessage` /
`updateChannelParticipant` over the socket; RUKA NOW returns the canonical
state in the mutation response and refreshes the open peer via `pollActive()`
(≤12 s) and the dialog list via `loadDialogs()` (≤8 s safety net). The end
state converges identically; latency is the only divergence (§7).
