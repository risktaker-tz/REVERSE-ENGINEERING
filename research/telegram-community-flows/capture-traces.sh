#!/bin/bash
# Capture full wire traces for docs/telegram-channels-groups.md §11-13
BASE=http://localhost:3000
U=$(date +%s%N | tail -c 9)
J() { python3 -m json.tool 2>/dev/null || cat; }
say() { echo; echo "##### $1"; }

curl -s -X POST $BASE/api/auth/email/login -H "Content-Type: application/json" -H "Origin: $BASE" -d '{"email":"alice8019@ruka.dev","password":"Alice!23456"}' -c /tmp/trace.jar >/dev/null

say "TRACE 1: POST /api/community/channels action=create (public group)"
curl -s -X POST $BASE/api/community/channels -H "Content-Type: application/json" -H "Origin: $BASE" -b /tmp/trace.jar -d "{\"action\":\"create\",\"title\":\"Trace Group $U\",\"about\":\"wire trace\",\"kind\":\"group\",\"username\":\"tr$U\"}" | J
say "TRACE 2: GET /api/community/channels?kind=peek (checkChatInvite parity)"
curl -s "$BASE/api/community/channels?kind=peek&username=tr$U" -b /tmp/trace.jar | J
say "TRACE 3: GET ?kind=pinned (pinned bar source)"
CH=$(curl -s "$BASE/api/community/channels?kind=mine" -b /tmp/trace.jar | python3 -c "import sys,json;d=json.load(sys.stdin);print([x['peer']['id'] for x in d['dialogs'] if x['peer'].get('username')=='tr$U'][0])")
curl -s -X POST $BASE/api/community -H "Content-Type: application/json" -H "Origin: $BASE" -b /tmp/trace.jar -d "{\"action\":\"send\",\"peerKey\":\"channel:$CH\",\"text\":\"trace message\"}" >/dev/null
curl -s "$BASE/api/community?kind=messages&peerKey=channel:$CH" -b /tmp/trace.jar | J
say "TRACE 4: PATCH /channels/[id] (editAbout — change_info right)"
curl -s -X PATCH $BASE/api/community/channels/$CH -H "Content-Type: application/json" -H "Origin: $BASE" -b /tmp/trace.jar -d '{"about":"updated by trace"}' | J
say "TRACE 5: GET /channels/[id]?kind=members (getParticipants parity)"
curl -s "$BASE/api/community/channels/$CH?kind=members&filter=recent" -b /tmp/trace.jar | J
