# cloud-1_42

Automated deployment of an *Inception*-equivalent WordPress stack onto a remote
cloud instance, driven entirely by Ansible. One process per container, TLS
terminated at nginx, name-based routing, no secrets in git.

Target: AWS EC2 (`eu-west-3`), Ubuntu, reached over SSH as `ubuntu`.

## Architecture

```
                      internet
                          |
                  :80  :443   :22
                          |
                  +---------------+
                  |     ufw       |   only 22 / 80 / 443 accepted
                  +---------------+
                          |
                  +---------------+
                  |  nginx :443   |   TLS termination, name-based vhosts
                  |  (frontend)   |   :80 -> 301 https
                  +---------------+
                     |          |
        frontend     |          |     frontend
                     v          v
            +-------------+  +---------------+
            | wordpress   |  |  phpmyadmin   |   php-fpm pools, no published
            |   php-fpm   |  |    php-fpm    |   ports, reachable only from
            +-------------+  +---------------+   nginx
                     |          |
        backend      |          |     backend      (internal: true -
                     v          v                   no route off the host)
                  +-----------------+
                  |    mariadb      |   never exposed to the internet
                  +-----------------+
```

Four containers, one process each. `nginx` is the only service that publishes
ports. `mariadb` sits on a `backend` network declared `internal: true`, so it
has no route off the host even if a port were published by mistake.

## Layout

```
ansible.cfg                    connection defaults, vault password file
inventory.yaml                 the webservers group -> cloud1 (ansible_host = EC2 IP)
site.yml                       top-level playbook: common, security, docker, wordpress
group_vars/webservers/vars.yml non-secret per-group settings (domain, db names, ...)
group_vars/webservers/vault.yml  ansible-vault secrets  <-- the live vault
.vault_pass                    vault passphrase - GITIGNORED, never commit
server_key.pem                 SSH key - GITIGNORED, never commit
requirements.yml               collections needed by the roles

roles/common/     baseline: packages, timezone, hostname, admin user
roles/security/   ufw (22/80/443 only), fail2ban, unattended-upgrades, sshd hardening
roles/docker/     Docker Engine + Compose plugin from Docker's apt repo, enabled at boot
roles/wordpress/  TLS material, the Compose stack, nginx vhosts, first-run WP install
```

### Where is docker-compose.yml?

It is a **template**, `roles/wordpress/templates/docker-compose.yml.j2`, rendered
onto the target at `/opt/cloud1/docker-compose.yml`. It is generated rather than
committed because it interpolates per-host values (domain, image tags, memory
limits) and because the secrets it consumes come from the vault via a `0600`
`.env` that must never exist in git. To read the rendered file:

```bash
ansible webservers -b -a 'cat /opt/cloud1/docker-compose.yml'
```

## Usage

```bash
ansible all -m ping                      # connectivity check
ansible-playbook site.yml --check --diff # dry run
ansible-playbook site.yml                # apply
ansible-lint --profile production        # must stay clean
```

Secrets (the live vault is the one under `group_vars/`):

```bash
ansible-vault view group_vars/webservers/vault.yml
ansible-vault edit group_vars/webservers/vault.yml
```

## Deploying to several servers in parallel

Nothing in the roles is bound to a single host. Add entries to the group and
Ansible fans out across them in one pass:

```yaml
webservers:
  hosts:
    cloud1:
      ansible_host: 15.188.53.129
    cloud2:
      ansible_host: 51.44.0.2
```

The role's own default for `wordpress_domain` is each host's `ansible_host`, so
without further configuration every server gets its own vhost names and its own
certificate. The group_vars here override that with a single real domain,
because that is what this deployment serves; to fan out across several hosts,
either drop the override (each host then uses its IP, with a self-signed cert)
or set `wordpress_domain` per host in `host_vars/`.

## Live URLs

| | |
| --- | --- |
| WordPress | https://youssefelhadraoui.tech/ |
| phpMyAdmin | https://pma.youssefelhadraoui.tech/ |

Both serve a trusted Let's Encrypt certificate, so there is no browser warning.

## Domain and TLS

`wordpress_domain` in `group_vars/webservers/vars.yml` drives everything: the
vhost names, the certificate's SANs, and WordPress's own idea of its URL.
Changing it and re-running is enough to move the site to a different name.

Three A records must point at the instance before a certificate can be issued -
the apex, `www`, and `pma`. All three go on one certificate, and ACME is
all-or-nothing: if any single name fails to validate, none are issued.

```yaml
wordpress_domain: youssefelhadraoui.tech
wordpress_tls_letsencrypt: true
wordpress_tls_le_email: you@example.com
```

Set `wordpress_tls_letsencrypt: false` to fall back to the self-signed
certificate - which is what you want when deploying against a bare IP, since
Let's Encrypt will not issue for one.

### How the chicken-and-egg is resolved

certbot proves control of the domain over the ACME HTTP-01 challenge, which
needs nginx already answering on port 80. But nginx cannot bind :443 without a
certificate. So:

1. A self-signed certificate is always generated first. nginx boots on it.
2. The stack comes up; `:80` serves `/.well-known/acme-challenge/` over plain
   HTTP (everything else there is redirected to HTTPS - redirecting the
   challenge too would break renewals).
3. certbot runs as a one-shot `tools`-profile container and writes a real
   certificate into `/opt/cloud1/letsencrypt`.
4. The role stats the live directory, sets `wordpress_tls_le_ready`, re-renders
   the vhosts onto the real certificate and reloads nginx.

Before any of that, a preflight resolves every requested name from the target
and fails with a readable message if one does not point here. Let's Encrypt
rate-limits failed authorisations to five per hostname per hour, so a typo in a
DNS record would otherwise cost an hour's wait.

### Renewal

Certificates last 90 days. A systemd timer (`certbot-renew.timer`) runs twice a
day with a randomised delay, renews when inside the 30-day window, and reloads
nginx afterwards - nginx caches certificates in memory at startup, so without
the reload it would happily keep serving an expired one.

```bash
systemctl list-timers certbot-renew.timer
docker compose --profile tools run --rm certbot renew --dry-run   # rehearse
```

### Port 80 is not optional

The ACME challenge arrives on port 80, so it must be reachable from the
internet. On EC2 that means the **security group**, which is a separate
firewall from the host's ufw: the host can be listening and answering locally
while AWS silently drops every inbound packet. If issuance fails, check there
first.

## Requirements checklist

| Subject requirement | Where it is met |
| --- | --- |
| Fully automated deployment | `site.yml` + four roles, one command |
| Restarts automatically after reboot | `restart: unless-stopped` on every service, `docker.service` enabled at boot |
| Data survives reboot | named volumes `db_data`, `wordpress_data`, `pma_data` |
| Deployable to several servers in parallel | group-based inventory, per-host `wordpress_domain` |
| Runs on a fresh Ubuntu with only SSH + Python | `docker` role installs the engine; no manual prep |
| 1 process = 1 container | nginx / wordpress-fpm / phpmyadmin-fpm / mariadb |
| Database unreachable from the internet | `backend` network is `internal: true`; no published DB port |
| WordPress + phpMyAdmin + MariaDB | the four Compose services |
| docker-compose.yml | rendered to `/opt/cloud1/docker-compose.yml` (see above) |
| TLS | trusted Let's Encrypt cert, auto-renewed; self-signed fallback for bare-IP deploys |
| URL-based routing | name-based vhosts; unknown names get `444` |
| Only 80 / 443 / 22 reachable | `security` role's ufw rules + default-deny |
| Organised into roles | `common`, `security`, `docker`, `wordpress` |
| Idempotent | a second `site.yml` run reports `changed=0` |
| No hard-coded secrets | all credentials come from the encrypted vault |

## Notes

- **Ports on the cloud provider are a separate firewall.** ufw on the host is
  not the only thing in the path: the EC2 security group must also allow
  22/80/443, or the port is refused before it ever reaches the instance.
- `remote_user` is `ubuntu`; root login is disabled. Tasks needing root use
  `become: true`.
- `server_key.pem` must be mode `0600` or SSH refuses it. Under WSL this
  requires the `metadata` automount option in `/etc/wsl.conf`, otherwise every
  file on `/mnt/c` shows as `0777`.
- **nginx resolves its PHP upstreams per request**, via
  `set $wp_upstream wordpress:9000; fastcgi_pass $wp_upstream;` plus
  `resolver 127.0.0.11`. With a literal host name nginx resolves once at config
  load, and if it wins the boot race it dies with
  `[emerg] host not found in upstream`; a crash-looping container then loses its
  network sandbox and never recovers. This is not hypothetical - it is what took
  the stack down for 19 hours, and it would recur on every reboot.
- The `security` role can lock you out if edited carelessly. The sshd task uses
  `validate: sshd -t -f %s` so a bad config fails the task instead of being
  installed, and the handler *reloads* rather than restarts so existing sessions
  survive. UFW allows OpenSSH before it is enabled.
- Re-running `site.yml` must always report `changed=0`. If it doesn't, a task is
  misreporting its state - usually a `command`/`shell` task needing
  `changed_when`.
- The `vault.yml` at the repository root is a leftover from week 1 and is not
  loaded by any play. The vault in use is `group_vars/webservers/vault.yml`.
