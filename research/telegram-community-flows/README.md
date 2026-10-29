# Telegram Community Flows — End-to-End Reverse Engineering

Agent research synced from the RUKA NOW project (an independent messaging
client that reimplements Telegram's community semantics on Supabase/Postgres).

## What is in this folder

| File | What it is |
|---|---|
| `telegram-channels-groups.md` | The full protocol study: the three community shapes, the byte-for-byte creation flow (`channels.createChannel` → Updates envelope → synthesized dialog), the four joining doors, the exact roles/rights model, per-shape messaging rules, updates fan-out, a TL → REST mapping table, deliberate divergences, and — added in this sync — **§11–13: wire-level end-to-end traces** of creation, joining, and member interaction as implemented and observed on a running app. |
| `e2e-regression.sh` | Executable evidence: a 10-step API-level regression that exercises create → peek → join → post → react → pin → private-channel invite → `CHAT_WRITE_FORBIDDEN` gating → views → dialogs. Run it against any deployment of the app to reproduce the claims in §11–13. |
| `capture-traces.sh` | Minimal single-user script that captures the raw create/peek/pinned/PATCH/members response bodies used as evidence in the doc. |

## Method (REA-style: evidence provenance)

- TL-shape claims are sourced from the public schema (layer 233,
  `updateChannelParticipant#985d3abb` era) and official client behaviour.
- Implementation claims are backed by the observed HTTP traces embedded in
  §11–13 (exact request/response JSON, captured 2026-10-29) and re-runnable
  via the scripts above.
- Divergences (§9) and unimplemented doors (join requests) are stated as
  unknowns rather than silently dropped.

## Headline findings

1. Creation is **one round-trip**: `channels.createChannel` answers with the
   complete Updates envelope and the client synthesizes the dialog locally —
   it never refetches `messages.getDialogs`. The REST equivalent returns
   `{dialog, channel}` and the store inserts the dialog at the top of the list.
2. The two community kinds differ by exactly one object:
   `default_banned_rights` (`send_messages` banned for broadcast subscribers,
   empty for megagroups). One column drives all write gating.
3. Joining has four doors (username, invite hash, admin add, join request);
   banned members are locked out of all of them until an admin lifts the ban.
4. Member interactions converge to a single guard chain
   (same-origin → identity → schema → rate limit → membership → rights →
   mutation → canonical response) with Telegram's short-circuit semantics.
5. Auth-session rotation can make a signed-in client *look* signed out —
   the client must re-verify the cookie session before showing any
   "sign in" gate (§11.3 documents the live observation).
