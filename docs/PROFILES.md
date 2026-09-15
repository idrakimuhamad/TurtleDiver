# TurtleDiver Profile Reference (Surge-Compatible INI)

TurtleDiver profiles are plain-text INI files, compatible with the Surge
profile syntax for the sections TurtleDiver supports. Profiles live in:

```
~/Library/Application Support/TurtleDiver/Profiles/<name>.conf
```

The active profile is chosen in the app and remembered across launches. The
file is watched: edits made in an external editor are reloaded automatically
(~0.3s debounce).

Comments start with `#` or `;`. Inline comments are allowed except inside
double-quoted values. Values containing commas, quotes, `#`, `;`, or leading/
trailing spaces should be wrapped in double quotes (`""` escapes a quote).

A profile has four sections. Order within a section does not matter, except
rules: **the first matching rule wins, and `FINAL` must be the last rule.**

## Full example

```ini
[General]
http-listen = 127.0.0.1:6152
socks5-listen = 127.0.0.1:6153
test-url = http://cp.cloudflare.com/generate_204
test-timeout = 5
test-interval = 600
system-proxy = false
skip-proxy = 127.0.0.1, 192.168.0.0/16, 10.0.0.0/8, 172.16.0.0/12, localhost, *.local
loglevel = info

[Proxy]
Office = http, proxy.office.example.com, 8080, username=alice, password="s3,cret"
OfficeTLS = https, proxy.office.example.com, 443, skip-cert-verify=true
HomeLab = socks5, 192.168.1.50, 1080

[Proxy Group]
Auto = url-test, Office, OfficeTLS, HomeLab, url=http://cp.cloudflare.com/generate_204, interval=600
Fallback = fallback, Office, OfficeTLS
Pick = select, Auto, Office, HomeLab, DIRECT

[Rule]
DOMAIN,exact.example.com,DIRECT
DOMAIN-SUFFIX,corp.example.com,DIRECT
DOMAIN-KEYWORD,github,Pick
IP-CIDR,10.0.0.0/8,DIRECT,no-resolve
IP-CIDR6,fd00::/8,DIRECT
DEST-PORT,443,OfficeTLS
PROCESS-NAME,ssh,DIRECT
USER-AGENT,curl*,DIRECT
URL-REGEX,^https?://ads\.,REJECT
FINAL,Pick
```

## `[General]`

| Option | Default | Meaning |
|---|---|---|
| `http-listen` | `127.0.0.1:6152` | Local HTTP proxy listener (`host:port`). Empty = off. |
| `socks5-listen` | `127.0.0.1:6153` | Local SOCKS5 listener (`host:port`). Empty = off. |
| `test-url` | `http://cp.cloudflare.com/generate_204` | URL for group latency tests. |
| `test-timeout` | `5` | Latency test timeout, seconds. |
| `test-interval` | `600` | Seconds between automatic group tests. |
| `system-proxy` | `false` | Configure the macOS system proxy to the listeners. |
| `skip-proxy` | RFC1918 + loopback list | Hosts/CIDRs that bypass the proxy. |
| `loglevel` | `info` | `info` or `debug`. |

When `system-proxy = true`, enabling the engine snapshots the current proxy
settings of every enabled network service, points HTTP/HTTPS/SOCKS at the
listeners, and applies `skip-proxy` as the bypass list. Disable/quit restores
the snapshot; a crash is repaired on next launch. See
docs/SYSTEM_PROXY.md for the full lifecycle.

Unknown options produce a warning and are ignored — Surge profiles with extra
options still load.

## `[Proxy]`

One upstream proxy per line:

```
Name = http|https|socks5, <host>, <port>[, username=…][, password=…][, tls=true][, skip-cert-verify=true]
```

- `https` implies `tls=true`; add `tls=true` to `http` for TLS-on-plain-proxy.
- `username`/`password` support Basic auth (http/https) and user/pass (socks5).
- Duplicate names: the later entry wins (with a warning).

## `[Proxy Group]`

```
Name = select|url-test|fallback|load-balance, <policy>[, <policy>…][, url=…][, interval=…]
```

Members are other policy **names** (proxies, groups, or `DIRECT`/`REJECT`).

| Type | Behavior |
|---|---|
| `select` | Whatever the user picks in the UI; persisted. |
| `url-test` | Periodic latency test; lowest wins. |
| `fallback` | First candidate in list order that passes the test. |
| `load-balance` | Round-robin across healthy candidates. |

Groups may reference other groups. Cycles are rejected at validation
(`A → B → A` is an error); diamond references (`A → B, A → C, B → D, C → D`)
are fine.

## `[Rule]`

```
TYPE,value,policy[,no-resolve]
FINAL,policy
```

First match wins; `FINAL` catches everything left and must appear at most once,
last. Supported types:

| Type | Value | Notes |
|---|---|---|
| `DOMAIN` | exact hostname | Case-insensitive exact match. |
| `DOMAIN-SUFFIX` | hostname tail | Label-boundary match: `apple.com` matches `www.apple.com` and `apple.com`, not `notapple.com`. |
| `DOMAIN-KEYWORD` | substring | Case-insensitive match anywhere in the host. |
| `IP-CIDR` | `a.b.c.d/prefix` | Needs DNS resolve when host is a name; `no-resolve` skips such hosts. |
| `IP-CIDR6` | IPv6 CIDR | Same semantics. |
| `GEOIP` | country code | Reserved — parsed but not matched yet. |
| `USER-AGENT` | regex | HTTP requests only (SOCKS5 clients have no UA). ICU regex, case-insensitive, match anywhere. |
| `URL-REGEX` | regex | HTTP requests only. Same regex semantics. |
| `PROCESS-NAME` | process name | Best-effort local peer lookup; compares the executable's last path component, case-insensitive. |
| `DEST-PORT` | port, range, list | e.g. `443`, `5000-6000`, `80,443,8443`. |
| `SRC-IP` | CIDR | Client address. |
| `PROTOCOL` | `http`/`https`/… | Heuristic: well-known ports map to their canonical service until listeners expose the negotiated protocol. |
| `RULE-SET` | rule-set name | Expands to a downloaded remote list (see below). Managed in Settings → Rule Sets; read-only in the Rules editor. |
| `FINAL` | — | `FINAL,policy` only. |

### Remote rule sets

```ini
[Rule Set]
Ads = https://example.com/ads.conf, interval=86400
```

`Name = url[, interval=N]` — the name is referenced from a rule, the URL must be
`https`, and `interval` (seconds, omitted = manual refresh only) is the opt-in
cadence for the automatic refresh. The list itself is a rule list **without** a
section header, one `TYPE,value[,policy][,no-resolve]` per line:

```
# comments (#, ;, //) and blank lines are ignored
DOMAIN-SUFFIX,doubleclick.net
IP-CIDR,203.0.113.0/24,no-resolve
127.0.0.1 localhost
```

- **The reference's policy wins.** `RULE-SET,Ads,REJECT` rejects every host in
  `Ads`, whatever policies the list mentions — but a per-member policy is kept
  when the reference is written without one.
- **Order is preserved.** The list is spliced in at the position of the
  reference, so a rule written above it still shadows it.
- **Unresolved references are inert.** If the list has never been downloaded
  (or its cache was removed), `RULE-SET,Ads,REJECT` matches nothing — it does
  not become a catch-all `REJECT`.
- `FINAL` and nested `RULE-SET` lines inside a downloaded list are skipped and
  counted, as are lines that do not parse.
- Validation rejects duplicate names, non-`https` URLs, and references to
  undeclared sets.

### Matching semantics

- **Evaluation is ordered and stops at the first match.** When no rule matches
  and no `FINAL` exists, traffic goes to `DIRECT` (Surge-compatible default).
- **DNS is resolved lazily and at most once per connection**: only when an
  IP-rule is actually reached and the host is a name (not an IP literal). The
  result is shared by all later IP-rules of that connection.
- **`no-resolve`** skips an IP-rule when matching it would require a DNS
  lookup — the rule is not “failed”, evaluation simply continues with later
  rules. `no-resolve` rules still match IP-literal hosts and pre-resolved
  addresses.
- **Resolution failures** make IP-rules miss (no error); later rules and
  `FINAL` still apply. Resolver results are cached with a TTL (60s positive,
  10s negative) and flushed on profile reload.
- **IPv4/IPv6 interop:** IPv4-mapped IPv6 addresses (`::ffff:10.0.0.1`) match
  the equivalent IPv4 CIDR, and vice versa. A `/32` (or `/128`) CIDR matches
  exactly one host; `/0` matches everything of that family.
- **Domain rules never resolve DNS.** They match the host text as given
  (case-insensitively) or not at all.
- **HTTP-only rules** (`USER-AGENT`, `URL-REGEX`) are skipped for connections
  that carry no HTTP metadata (e.g. SOCKS5 CONNECT). `PROCESS-NAME` is skipped
  when the peer process could not be determined.

> The rule engine ships with Phase 2 and is exercised by the proxy listeners
> landing in Phase 3; until then rules are validated and testable but not yet
> consulted by live traffic.

## Built-in policies

`DIRECT` (connect directly, no proxy) and `REJECT` (drop the connection) always
exist and cannot be redefined. Policy names must be non-empty, contain no
commas, and may not be `FINAL`.

## Validation

Saving a profile runs structural validation; problems surface in the app:

- duplicate or invalid policy names, bad ports/listeners
- group references to unknown policies, empty groups, self- and cross-references (cycles)
- rules referencing unknown policies, duplicate `FINAL`, `FINAL` not last
- shape checks (CIDR format, DEST-PORT format) as parse warnings

## Migration from TurtleDiver ≤ 1.2

Existing PAC-based proxy configurations are migrated once automatically: each
becomes a profile of the same name, with the original PAC preserved as comments
inside. The legacy PAC path keeps working unchanged.
