#!/bin/bash
# Post-merge regression: channels/groups E2E with unique names
set -e
BASE=http://localhost:3000
U=$(date +%s)
J() { python3 -c "import sys,json;d=json.load(sys.stdin);print(json.dumps(d,ensure_ascii=False)[:300])"; }
say() { echo; echo "=== $1 ==="; }

say "login alice+bob"
curl -s -X POST $BASE/api/auth/email/login -H "Content-Type: application/json" -H "Origin: $BASE" -d '{"email":"alice8019@ruka.dev","password":"Alice!23456"}' -c /tmp/alice.jar | J
curl -s -X POST $BASE/api/auth/email/login -H "Content-Type: application/json" -H "Origin: $BASE" -d '{"email":"bob8019@ruka.dev","password":"Bob!234567"}' -c /tmp/bob.jar | J

say "1. alice creates public group"
CREATE=$(curl -s -X POST $BASE/api/community/channels -H "Content-Type: application/json" -H "Origin: $BASE" -b /tmp/alice.jar -d "{\"action\":\"create\",\"title\":\"Merge Check $U\",\"about\":\"post-merge\",\"kind\":\"group\",\"username\":\"mg$U\"}")
echo "$CREATE" | J
CH_ID=$(echo "$CREATE" | python3 -c "import sys,json;print(json.load(sys.stdin)['channel']['id'])")

say "2. bob peeks"
curl -s "$BASE/api/community/channels?kind=peek&username=mg$U" -b /tmp/bob.jar | J

say "3. bob joins by username"
curl -s -X POST $BASE/api/community/channels -H "Content-Type: application/json" -H "Origin: $BASE" -b /tmp/bob.jar -d "{\"action\":\"join\",\"username\":\"mg$U\"}" | J

say "4. bob posts (megagroup: everyone posts)"
MSG=$(curl -s -X POST $BASE/api/community -H "Content-Type: application/json" -H "Origin: $BASE" -b /tmp/bob.jar -d "{\"action\":\"send\",\"peerKey\":\"channel:$CH_ID\",\"text\":\"post-merge check\"}")
echo "$MSG" | J
MSG_ID=$(echo "$MSG" | python3 -c "import sys,json;print(json.load(sys.stdin)['message']['id'])")

say "5. bob reacts to his message (sendReaction parity)"
curl -s -X POST $BASE/api/community -H "Content-Type: application/json" -H "Origin: $BASE" -b /tmp/bob.jar -d "{\"action\":\"react\",\"peerKey\":\"channel:$CH_ID\",\"msgId\":$MSG_ID,\"emoticon\":\"👍\"}" | J

say "6. alice pins bob's message (updatePinnedMessage parity)"
curl -s -X POST $BASE/api/community -H "Content-Type: application/json" -H "Origin: $BASE" -b /tmp/alice.jar -d "{\"action\":\"pin\",\"peerKey\":\"channel:$CH_ID\",\"ids\":[$MSG_ID]}" | J
curl -s "$BASE/api/community?kind=pinned&peerKey=channel:$CH_ID" -b /tmp/alice.jar | J

say "7. alice creates private channel + invite flow"
PRIV=$(curl -s -X POST $BASE/api/community/channels -H "Content-Type: application/json" -H "Origin: $BASE" -b /tmp/alice.jar -d "{\"action\":\"create\",\"title\":\"Private $U\",\"kind\":\"channel\"}")
echo "$PRIV" | J
P_ID=$(echo "$PRIV" | python3 -c "import sys,json;print(json.load(sys.stdin)['channel']['id'])")
INV=$(curl -s -X POST $BASE/api/community/channels/$P_ID -H "Content-Type: application/json" -H "Origin: $BASE" -b /tmp/alice.jar -d '{"action":"invite-export"}')
HASH=$(echo "$INV" | python3 -c "import sys,json;print(json.load(sys.stdin)['link'])")
echo "invite hash: $HASH"
curl -s -X POST $BASE/api/community/channels -H "Content-Type: application/json" -H "Origin: $BASE" -b /tmp/bob.jar -d "{\"action\":\"join\",\"inviteHash\":\"$HASH\"}" | J

say "8. bob (subscriber) cannot post in channel (CHAT_WRITE_FORBIDDEN parity)"
curl -s -X POST $BASE/api/community -H "Content-Type: application/json" -H "Origin: $BASE" -b /tmp/bob.jar -d "{\"action\":\"send\",\"peerKey\":\"channel:$P_ID\",\"text\":\"nope\"}" | J

say "9. alice posts; bob reads; views bump"
curl -s -X POST $BASE/api/community -H "Content-Type: application/json" -H "Origin: $BASE" -b /tmp/alice.jar -d "{\"action\":\"send\",\"peerKey\":\"channel:$P_ID\",\"text\":\"broadcast works\"}" | J
curl -s "$BASE/api/community?kind=messages&peerKey=channel:$P_ID" -b /tmp/bob.jar | J

say "10. bob's dialogs include both"
curl -s "$BASE/api/community/channels?kind=mine" -b /tmp/bob.jar | J

say DONE
