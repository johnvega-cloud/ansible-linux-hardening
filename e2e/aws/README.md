# End-to-end test on real EC2

Molecule tests the roles in containers. This folder tests the parts that
containers cannot cover:

- the `aws_ec2` dynamic inventory;
- SSH to real instances, which also exercises the lockout guard;
- the official Ubuntu and RHEL AMIs, including EPEL from the Fedora URL on real RHEL;
- the playbook's real `serial: 25%` rollout.

It creates a throwaway environment, runs the playbook, then destroys it.

## What it creates

| Resource | Detail |
|---|---|
| 2 EC2 instances | Ubuntu 24.04 on `t3.micro`, RHEL 9 on `t3.small`. Tags: `Hardening=true`, `OS`, `Environment=e2e`. IMDSv2 only, encrypted gp3 root volume. |
| Security group | SSH from `admin_cidr` only, and SSH between the two hosts (needed by the fail2ban brute-force test) |
| Key pair | Imported from `public_key_path` |

Everything is in the default VPC, tagged `Project=ansible-linux-hardening-e2e`
and `Ephemeral=true`. Cost: a few cents per hour of uptime.

## Run it

```bash
cd e2e/aws
ssh-keygen -t ed25519 -N "" -f /tmp/e2e_key
cat > terraform.tfvars <<EOF        # git-ignored
owner           = "your-name"
admin_cidr      = "$(curl -s https://checkip.amazonaws.com)/32"
public_key_path = "/tmp/e2e_key.pub"
EOF
terraform init && terraform apply

cd ../..
export ANSIBLE_PRIVATE_KEY_FILE=/tmp/e2e_key
ansible-inventory -i e2e/aws/aws_ec2.yml --graph                  # 1. discovery
ansible-playbook  -i e2e/aws/aws_ec2.yml playbooks/site.yml --check --diff   # 2. audit
ansible-playbook  -i e2e/aws/aws_ec2.yml playbooks/site.yml       # 3. apply
ansible-playbook  -i e2e/aws/aws_ec2.yml playbooks/site.yml       # 4. idempotence: changed=0
ANSIBLE_ROLES_PATH=roles \
ansible-playbook  -i e2e/aws/aws_ec2.yml molecule/default/verify.yml        # 5. state + behaviour

cd e2e/aws && terraform destroy
```

Careful with manual login tests from your own machine. The sshd jail runs in
`aggressive` mode, where one failed connection counts as more than one failure.
After a few failed logins, fail2ban bans **your** IP for an hour.

## Results (2026-10-16, us-east-1)

| Step | Result |
|---|---|
| Dynamic inventory | Found both instances by tag; groups `os_ubuntu`, `os_rhel`, `env_e2e`, `region_us_east_1` |
| Lockout guard over real SSH | Ran and passed (not root, key present) |
| Audit (`--check --diff`) on fresh AMIs | Reported pending changes (Ubuntu 8, RHEL 6); changed nothing |
| Apply | OK on Ubuntu 24.04.5 and RHEL 9.6, in two batches (`serial: 25%`); sshd reload kept Ansible's session up |
| Second run | `changed=0` on both hosts |
| `verify.yml` | Passed: effective sshd config, real brute force between the instances banned in nftables, lockout guard, rollback |
| From outside (operator's machine) | Key login OK; root login and password-only login rejected (`Permission denied (publickey)`); the operator's own IP was then banned by fail2ban on both hosts |
| Cleanup | `terraform destroy`: 7 resources; instances `terminated`, volumes and SG rules `NotFound` |

### Bug found only on real EC2

On a 1 GB `t3.micro`, RHEL's `dnf` (run through Ansible's Python) was
OOM-killed. The kernel log showed `Out of memory: Killed process (python3.9)`
at about 500 MB RSS. Ansible only reported `Module result deserialization
failed`. Fixes:

- `roles/common` now fails early on RHEL hosts with less than
  `common_redhat_min_memory_mb` (1500 MB) of RAM plus swap, and the error says why.
- The e2e RHEL instance uses `t3.small` (2 GB).
