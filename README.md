# cloud-1_42

Automated deployment of an *Inception*-equivalent WordPress stack onto a remote
cloud instance. Terraform provisions the infrastructure, Ansible configures the
host. One process per container, TLS terminated at nginx, name-based routing,
no secrets in git.

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
Makefile                       provision -> regenerate inventory -> configure
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

terraform/        VPC, subnet, IGW, route table, security group, key pair, instance, EIP association
scripts/          update-inventory.sh, run by `make inventory`
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
make up                                  # provision, check DNS, wait for SSH, configure
make dns                                 # verify the A records point at this instance
make check                               # dry run against the current host
make lint                                # ansible-lint + terraform fmt/validate
make down                                # destroy everything (stops the billing)
```

Ansible on its own, against a host that already exists:

```bash
ansible all -m ping                      # connectivity check
ansible-playbook site.yml --check --diff # dry run
ansible-playbook site.yml                # apply
ansible-lint --profile production        # must stay clean
```

Secrets:

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
4. The role reads the certificate back, sets `wordpress_tls_le_ready` only if it
   is both present *and* still inside its validity window, then re-renders the
   vhosts onto it and reloads nginx. Presence alone is not enough: turning
   Let's Encrypt off keeps the lineage on disk, so a certificate can outlive
   its notAfter and must not be served.

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

## Infrastructure

`terraform/` builds everything the playbook then configures: a VPC with one
public subnet, an internet gateway and route table, a security group opening
only 22/80/443, a key pair derived from `server_key.pem`, the instance itself,
and an Elastic IP.

The Elastic IP is the reason `make up` is worth using over a hand-made box. A
stop/start hands back a different public address, which breaks both the DNS
records for the domain and the `ansible_host` in `inventory.yaml` - and a stale
`ansible_host` is not a cosmetic problem, because the Let's Encrypt preflight
asserts that every certificate name resolves to it. Pinning the address removes
that whole class of failure.

The address is pinned harder than that, though. Terraform *attaches* the EIP
but does not own the allocation: `main.tf` reads it with a `data "aws_eip"`
block matching the tag `Name=cloud1-eip`, and only the `aws_eip_association`
is a managed resource. Had the allocation been a resource, `make down` would
release it along with the VPC, and the next `make up` would come back on a
fresh address with all three A records pointing at nothing. As written,
teardown destroys the association and leaves the address allocated, so the
DNS records set up once stay correct across any number of down/up cycles.

If you are carrying a `terraform.tfstate` from before this change, migrate it
**before** the next `make up`. That state still records `aws_eip.web` as a
managed resource, and applying a configuration that no longer declares it is
read as "destroy this" - releasing the very address the A records point at.
Drop it from the state and adopt the association instead:

```sh
cd terraform
ALLOC=$(aws ec2 describe-addresses --region eu-west-3 \
  --filters Name=tag:Name,Values=cloud1-eip \
  --query 'Addresses[0].AllocationId' --output text)
ASSOC=$(aws ec2 describe-addresses --region eu-west-3 \
  --filters Name=tag:Name,Values=cloud1-eip \
  --query 'Addresses[0].AssociationId' --output text)

terraform state rm aws_eip.web            # state only - touches nothing in AWS
terraform import aws_eip_association.web "$ASSOC"
terraform plan                            # must say: No changes
```

`terraform state rm` only forgets the resource; the address itself stays
allocated and attached throughout. A state created fresh from this revision
needs none of the above. Either way, `terraform plan -destroy` is the check
that it worked - `aws_eip_association.web` should appear in the list and the
allocation should not.

The trade is money: AWS bills an allocated IPv4 address whether or not it is
attached, roughly $3.60 a month while the stack is down. On the day the
project is retired, hand it back:

```sh
aws ec2 release-address --region eu-west-3 --allocation-id <id>
```

And if the allocation does not exist yet - a fresh account, or after that
release - create it once before the first `make up`:

```sh
aws ec2 allocate-address --domain vpc --region eu-west-3 \
  --tag-specifications \
  'ResourceType=elastic-ip,Tags=[{Key=Name,Value=cloud1-eip}]'
```

`make inventory` closes the loop: `scripts/update-inventory.sh` rewrites
`inventory.yaml` from `terraform output -raw instance_public_ip`, so Ansible
always targets the instance that actually exists rather than an address typed
in by hand. It is idempotent - a no-op when the file already names the current
address - and refuses to write anything that is not an IPv4 address, since the
DNS gate below and the playbook's TLS preflight both compare that value against
resolved A records. Run it on its own (`./scripts/update-inventory.sh`) when
only the address has changed.

`make dns` then refuses to go further until the A records agree with that
address. The playbook's own preflight catches the same mistake, but only after
the whole stack is already up, which leaves the site running on its self-signed
bootstrap certificate. Checking it here fails before anything is deployed. The
records are not managed in Terraform because the domain is registered outside
AWS, so there is no Route 53 zone to write them into. The check is skipped when
`wordpress_tls_letsencrypt` is not `true`.

### Terraform vs Ansible

Terraform is **stateful**: `terraform.tfstate` is its record of which real
resources it owns, and it diffs desired-against-recorded to decide what to
create, change or destroy. Ansible is **stateless**: it keeps no record between
runs and instead re-asserts the desired state against whatever it finds on the
host each time. That is why Terraform can delete a resource and Ansible cannot.

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
- The only vault is `group_vars/webservers/vault.yml`, loaded by group_vars
  rather than a `vars_files:` entry. The week 1 leftover at the repository root
  was removed; nothing loaded it.
