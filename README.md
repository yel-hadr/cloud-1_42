# cloud-1_42

Ansible provisioning for the 42 cloud-1 project, targeting an AWS EC2 host.

## Layout

```
ansible.cfg              connection defaults, vault password file, output format
inventory.yaml           the webservers group -> cloud1 (ansible_host = the EC2 IP)
site.yml                 top-level playbook: applies common, then security
vault.yml                ansible-vault encrypted secrets (ciphertext in git)
.vault_pass              vault passphrase - GITIGNORED, never commit
requirements.yml         collections needed by the roles
roles/common/            baseline: packages, timezone, hostname, admin user
roles/security/          ufw, fail2ban, unattended-upgrades, sshd hardening
```

## Usage

```bash
ansible all -m ping                      # connectivity check
ansible all -m setup                     # dump host facts
ansible-playbook site.yml --check --diff # dry run - always do this first
ansible-playbook site.yml                # apply
ansible-lint                             # must stay clean
```

Secrets:

```bash
ansible-vault view vault.yml
ansible-vault edit vault.yml
```

## Notes

- `remote_user` is `ubuntu`; root login is disabled on the box. Tasks that
  need root use `become: true`.
- `server_key.pem` must be mode `0600` or SSH refuses it. Under WSL this
  requires the `metadata` automount option in `/etc/wsl.conf`, otherwise
  every file on `/mnt/c` shows as `0777`.
- The `security` role can lock you out if edited carelessly. The sshd task
  uses `validate: sshd -t -f %s` so a bad config fails the task instead of
  being installed, and the handler *reloads* rather than restarts so
  existing sessions survive. UFW allows OpenSSH before it is enabled.
- Re-running `site.yml` must always report `changed=0`. If it doesn't, a
  task is misreporting its state - usually a `command`/`shell` task that
  needs `changed_when`.
