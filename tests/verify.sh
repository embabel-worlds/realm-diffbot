#!/bin/sh
# Ground truth for realm-diffbot: every view answers by name, the figures it reports agree with the
# Diffbot Knowledge Graph asked directly, and what a narrow question COSTS in Diffbot calls.
#
#   DIFFBOT_TOKEN=... APPLIANCE=http://127.0.0.1:11043 AUTH=user:pass sh tests/verify.sh
#
# DIFFBOT_TOKEN is the same Diffbot API token the appliance holds for this realm; the battery uses
# it only for the handful of direct DQL reads in L2. Exits nonzero on any failure; the last line on
# success is exactly ALL CHECKS PASS.
#
# CREDITS ARE REAL. Diffbot bills per entity returned, so this battery is written to spend little:
# the views that take a spending ceiling (`companies`, `films`) are run at 2, the direct reads ask
# for a handful of entities, and everything the views read is cached by the realm, so a second run
# inside the cache window costs almost nothing. The L3 cost checks force a cold read with
# `ai: {fresh: true}` on a single edge, never on a sweep.
#
# Layers: L1 every view by name; L2 the realm's figures against DQL; L3 the cost of a single-entity
# read (O(1) Diffbot calls cold, 0 warm) and proof that a filter is sent to Diffbot.
set -e
AUTHCFG=$(mktemp); trap 'rm -f "$AUTHCFG"' EXIT
if [ -n "${TOKEN:-}" ]; then printf 'header = "Authorization: Bearer %s"\n' "$TOKEN" > "$AUTHCFG"
else printf 'user = "%s"\n' "${AUTH:?set AUTH (user:pass) or TOKEN}" > "$AUTHCFG"; fi
APPLIANCE="${APPLIANCE:-http://127.0.0.1:11043}"
: "${DIFFBOT_TOKEN:?set DIFFBOT_TOKEN}"
DQL="https://kg.diffbot.com/kg/v3/dql"

fail=0
check() { # name expected actual
  if [ "$2" = "$3" ]; then echo "  ok   $1 = $2"
  else echo "  FAIL $1: expected $2, got $3"; fail=1; fi
}
at_most() { # name bound actual — source calls a question made
  case "$3" in ''|*[!0-9]*) echo "  FAIL $1: no call count ($3)"; fail=1; return ;; esac
  if [ "$3" -le "$2" ]; then echo "  ok   $1: $3 Diffbot call(s), bound $2"
  else echo "  FAIL $1: $3 Diffbot calls, bound $2"; fail=1; fi
}
py() { python3 -c "$1"; }
kg() { curl -s -K "$AUTHCFG" -X POST "$APPLIANCE/api/v1/admin/kg/execute" -H 'Content-Type: application/json' \
         -d "$(python3 -c 'import json,sys; print(json.dumps({"cypher": sys.argv[1]}))' "$1")"; }
view() { curl -s -K "$AUTHCFG" -X POST "$APPLIANCE/api/v1/views/$1/invoke" -H 'Content-Type: application/json' -d "{\"args\":$2}"; }
# The token goes to curl through a config file, never on a command line `ps` would show.
dql() { # query size -> raw JSON
  Q=$(mktemp); printf 'url = "%s"\ndata-urlencode = "token=%s"\ndata-urlencode = "query=%s"\ndata-urlencode = "size=%s"\n' \
      "$DQL" "$DIFFBOT_TOKEN" "$(printf '%s' "$1" | sed 's/"/\\"/g')" "$2" > "$Q"
  curl -s -G -K "$Q"; rm -f "$Q"; }
# First row's column, or REFUSED when the engine answered with an error (never read an error as 0).
col() { py "import json,sys; d=json.load(sys.stdin); r=d.get('rows') or d.get('data') or []
print('REFUSED: '+str(d['error'])[:160] if d.get('error') else (r[0].get('$1') if r else ''))"; }
calls() { printf '%s' "$1" | py 'import json,sys; print(json.load(sys.stdin).get("apiCalls", ""))'; }

echo "== L1: every view answers by name =="
# Defaults throughout, except the two spending ceilings, run at 2. Views anchored on your own
# correspondence (Contact*, HiddenCommonOwner, QuietlyAbsorbed, ExecutiveExposure, HiringSignals)
# and MyFilmsByOwner (realm-movie's ratings) may answer zero rows on a world without that data;
# they must still answer without an error.
for spec in 'CompanyProfile {}' 'CompanySearch {}' 'CompanyOwnership {}' 'GroupRollup {}' \
            'SiblingCompanies {}' 'WhoOwnsThisMarket {"companies":2}' 'BoardInterlocks {}' \
            'TalentFlow {}' 'CompetitorHiring {}' 'SkillDemand {"companies":2}' 'PeopleSearch {}' \
            'ContactCompanyProfiles {}' 'HiddenCommonOwner {}' 'QuietlyAbsorbed {}' \
            'ContactCompanyNews {}' 'ExecutiveExposure {}' 'HiringSignals {}' 'MovieSearch {}' \
            'RepeatCollaborators {}' 'FilmOwnership {"films":2}' 'DirectorFilmography {}' \
            'FilmCast {}' 'MyFilmsByOwner {}'; do
  name=${spec%% *}; args=${spec#* }
  R=$(view "$name" "$args")
  out=$(printf '%s' "$R" | py 'import json,sys
try: d=json.load(sys.stdin)
except ValueError: print("ERR not JSON"); raise SystemExit
if d.get("error"): print("ERR " + str(d["error"])[:160])
elif not isinstance(d.get("data"), list): print("ERR no data: " + str(d)[:160])
else: print("OK %d" % len(d["data"]))')
  case "$out" in OK*) echo "  ok   $name: ${out#OK } row(s)";; *) echo "  FAIL $name: ${out#ERR }"; fail=1;; esac
done
# The views that need nothing but Diffbot must find something: an empty answer there is a broken
# join or a refused request, not a quiet day.
for spec in 'CompanyProfile {}' 'CompanyOwnership {}' 'MovieSearch {}' 'DirectorFilmography {}'; do
  name=${spec%% *}; args=${spec#* }
  N=$(view "$name" "$args" | py 'import json,sys; print(len(json.load(sys.stdin).get("data") or []))')
  [ "$N" -gt 0 ] && echo "  ok   $name is not empty ($N)" || { echo "  FAIL $name answered no rows"; fail=1; }
done

echo "== L2: the realm's figures, against Diffbot asked directly =="
# Shazam is CompanyOwnership's default and a company with a recorded parent (Apple).
R=$(kg "MATCH (:DiffbotCompany {name: 'Shazam'})-[:RESOLVED_TO]->(o:DiffbotOrganization) RETURN o.diffbotId AS id, o.name AS name, o.nbEmployees AS staff, o.parentCompanyId AS parent")
ID=$(printf '%s' "$R" | col id)
case "$ID" in ''|REFUSED*) echo "  FAIL resolving Shazam: $ID"; fail=1;; *)
  TRUTH=$(dql "type:Organization id:\"$ID\"" 1 | py 'import json,sys; e=json.load(sys.stdin)["data"][0]["entity"]
print("%s|%s|%s" % (e.get("name"), e.get("nbEmployees"), (e.get("parentCompany") or {}).get("targetDiffbotId")))')
  check "Shazam's record, name|headcount|parent id" "$TRUTH" "$(printf '%s' "$R" | py 'import json,sys; r=json.load(sys.stdin)["rows"][0]
print("%s|%s|%s" % (r["name"], r["staff"], r["parent"]))')"
  PARENT=$(printf '%s' "$TRUTH" | cut -d'|' -f3)
  check "the PARENT_COMPANY hop lands on Diffbot's parent" "$PARENT" "$(kg "MATCH (:DiffbotCompany {name: 'Shazam'})-[:RESOLVED_TO]->(o:DiffbotOrganization)-[:PARENT_COMPANY]->(p:DiffbotOrganization) RETURN p.diffbotId AS id" | col id)"
esac
# A filtered search is SENT to Diffbot: the same narrow DQL asked directly must name the same
# companies. Were the filter left to the graph, it would be applied to 20 unfiltered mining
# companies and almost certainly keep none of these.
NARROW='WHERE o.country = "Australia" AND o.nbEmployees > 20000'
TRUTH=$(dql 'type:Organization industries:"Mining" location.country.name:"Australia" nbEmployees>20000' 20 \
        | py 'import json,sys; print(",".join(sorted(d["entity"]["id"] for d in json.load(sys.stdin)["data"])))')
R=$(kg "MATCH (:DiffbotIndustry {name: 'Mining'})-[:HAS_COMPANY {ai: {fresh: true}}]->(o:DiffbotOrganization) $NARROW RETURN collect(o.diffbotId) AS ids")
check "large Australian mining companies, realm vs DQL" "$TRUTH" "$(printf '%s' "$R" | py 'import json,sys; d=json.load(sys.stdin)
print("REFUSED: "+str(d["error"])[:160] if d.get("error") else ",".join(sorted(d["rows"][0]["ids"])))')"
at_most "  ...a filtered industry search, cold" 1 "$(calls "$R")"

echo "== L3: what a single-entity read costs =="
Q="MATCH (:DiffbotCompany {name: 'Shazam'})-[:RESOLVED_TO {ai: {fresh: true}}]->(o:DiffbotOrganization) RETURN o.name AS n"
R=$(kg "$Q"); at_most "one company resolved by name, cold" 1 "$(calls "$R")"
R=$(kg "MATCH (:DiffbotCompany {name: 'Shazam'})-[:RESOLVED_TO]->(o:DiffbotOrganization) RETURN o.name AS n")
check "the same company, warm: Diffbot calls" "0" "$(calls "$R")"
R=$(kg "MATCH (:DiffbotCompany {name: 'Shazam'})-[:RESOLVED_TO]->(o:DiffbotOrganization)-[:PARENT_COMPANY {ai: {fresh: true}}]->(p:DiffbotOrganization) RETURN p.name AS n")
at_most "one ownership hop, cold (one id lookup)" 1 "$(calls "$R")"
R=$(kg "MATCH (:DiffbotCompany {name: 'Shazam'})-[:RESOLVED_TO]->(o:DiffbotOrganization)-[:PARENT_COMPANY]->(p:DiffbotOrganization) RETURN p.name AS n")
check "the same hop, warm: Diffbot calls" "0" "$(calls "$R")"

[ $fail -eq 0 ] && echo "ALL CHECKS PASS" || { echo "SOME CHECKS FAILED"; exit 1; }
