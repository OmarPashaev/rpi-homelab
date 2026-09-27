# Raspberry Pi 5 homelab

Self-hosted infrastructure on a Raspberry Pi 5, running on Docker. Half of it is services I use every day: files, DNS, dashboards, all reached through a reverse proxy over TLS. The other half watches the first: metrics, logs, and detection rules I wrote and then tested by attacking my own login portal. I built it to learn.

## Hardware

- Raspberry Pi 5, 8 GB, ARM64.
- Kingston NV3 2TB NVMe - root filesystem.
- WD Elements 5TB HDD - local backup encrypted with restic.
- Geekworm X1208 UPS - clean shutdown on power loss.

## Software stack

Traefik terminates TLS and is the only way in to the web services. Authelia sits in front of the
services that have no login worth trusting, and stays off the ones that do.
AdGuard is internal DNS for `*.home.lan` as well as an ad blocker. Forgejo holds the
repo this file lives in.

| Service             | Auth                | Networks                      |
| ------------------- | ------------------- | ----------------------------- |
| Traefik             | Authelia (1FA)      | edge, apps, obs, socket-proxy |
| Authelia            | none                | edge                          |
| AdGuard Home        | own login           | apps                          |
| Forgejo             | own login           | apps                          |
| Nextcloud           | own login + TOTP    | apps, db-net                  |
| Homepage            | Authelia (1FA)      | apps                          |
| Uptime Kuma         | Authelia (1FA)      | edge, apps, obs               |
| whoami              | none (test service) | apps                          |
| Grafana             | Authelia (2FA)      | obs                           |
| ntfy                | own login + ACL     | apps, obs                     |
| Prometheus          | Authelia (1FA)      | obs                           |
| Loki                | not exposed         | obs                           |
| Alloy               | not exposed         | obs, socket-proxy             |
| node-exporter       | not exposed         | obs                           |
| nextcloud-db        | not exposed         | db-net                        |
| nextcloud-redis     | not exposed         | db-net                        |
| docker-socket-proxy | not exposed         | socket-proxy                  |

The observability stack is one pipeline:

- **Alloy** is the agent. It reads container logs off the host and the systemd
  journal, labels each line, and ships it.
- **Loki** stores those logs. It indexes labels.
- **node-exporter** exposes host metrics, CPU, memory, disk, network, as
  numbers Prometheus can scrape every few seconds.
- **Grafana** is the only thing I actually look at. Metrics and logs land in the
  same place, so a spike on a graph and the log lines behind it are one click
  apart.
- **ntfy** takes alerts from Grafana and pushes them to my phone. It sits on
  `obs` so Grafana can reach it, and on `apps` so Traefik can.

---

## Security decisions I have made

**`cap_drop: ALL`**
Dropped every capability, then added back only the ones a service actually
breaks without. Three of the seventeen containers needed anything at all.

**WireGuard for remote access**
One UDP port is forwarded to WireGuard. It runs on the host and the tunnel only reaches the Pi.

**Docker socket proxy**
In front of the two services that need the Docker API, Traefik and Alloy. Five
API sections are enabled: containers, networks, events, ping and version. The
last three are the image defaults; I added the first two. Access through the
proxy is read-only. Nothing else on the host mounts the socket.

**Five isolated networks**
So containers can only reach what they actually need. Grafana, Prometheus, Loki
and node-exporter sit only on `obs`, which is `internal: true`. They have no
route out.

**Internal CA (mkcert)** 
Wildcard for `*.home.lan`, signed by my own CA, so every service is served over HTTPS.

**LUKS encryption**
The NVMe is encrypted, in case of a stolen disk. The Pi is headless, so the passphrase goes in over SSH to a dropbear instance running in the initramfs, on its own port with its own key and a forced `cryptroot-unlock` command.

The cost is that the Pi does not boot unattended. After a power cut it waits for me before anything starts.
It also means a reboot while I am away leaves me with no way in, since WireGuard does not run in the initramfs.
I plan to make remote unlock possible by running WireGuard in the initramfs, so unlocking uses the same port instead of a new one.

---

## Detection rules

### A. Account locked (regulation ban)

The goal here is to surface every case where the authentication portal's own rate limiting
has locked an account. The point is not to add protection, Authelia already blocked the attempt. The point is that a block leaves a trace I see.

```logql
sum(count_over_time({container="authelia"} |= "they are banned until" [5m]))
```

A ban is not its own log message. Authelia appends "and they are banned until
<time>" to the same `Unsuccessful 1FA` line it writes for every failed attempt,
so that phrase is what separates a lockout from an ordinary failure.

Threshold: greater than 0. A ban means the threshold that matters has already been crossed inside Authelia, so there is no reason to put a second one on top. The policy behind it: `max_retries: 4` within `find_time: 120s`, `ban_time: 300s`. When it fires, the alert goes to my phone through ntfy.

I tested this with repeated failed logins against my own account until the lockout got triggered.

The blind spot is that it only covers attacks Authelia itself recognizes, which is repeated
attempts against a single account. Enumeration across many accounts never
triggers a ban and is invisible here. See rule B.

### B. Username enumeration from a single source

The goal here is to catch one source trying many different usernames against the login portal. Authelia's rate limiting counts per account, so an attacker who tries one attempt each against twenty usernames never gets banned, because no single account accumulates enough failures.

```logql
sum by (remote_ip) (count_over_time(
  {container="authelia"} |= "Unsuccessful 1FA authentication attempt"
  | logfmt | error="user not found" [5m]
))
```

Threshold: greater than 10 per source address in five minutes. Unlike rule A, nothing has filtered this for me, because Authelia never acts on this pattern, so the threshold has to do the whole job. Ten is a compromise: high enough that my own mistyped usernames do not fire it, low enough to catch a wordlist. The number might be worth changing in the future after I have found my baseline. Like rule A, it alerts my phone through ntfy.

The `error="user not found"` filter is what separates the two attack shapes. That value means the username does not exist, which is enumeration. Any other error means a wrong password against an account that does exist, which is what rule A ends up catching through the ban.

I confirmed the gap by attacking it both ways from the same machine: four
attempts against my own account got the account banned, while twelve attempts
against twelve invented usernames got nothing at all. 

Blind spots: it only covers the web portal, not SSH on the host. And anyone spreading their attempts over more than five minutes stays under the threshold.
