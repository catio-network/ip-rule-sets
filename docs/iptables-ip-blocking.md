# iptables IP Blocking

The `scripts/iptables-ip-blocking.sh` script reads IPv4 and IPv6 prefix lists
from the repository's `artifacts/` directory and installs them as source-address
blocking rules on a Linux host.

The script manages two chains in the `filter` table:

- `IP_BLOCK_V4` for IPv4 prefixes
- `IP_BLOCK_V6` for IPv6 prefixes

Each managed chain is referenced by a jump at the beginning of the corresponding
`INPUT` chain. Traffic whose source address matches a configured prefix is
dropped. Traffic that does not match returns to the remaining rules in `INPUT`.

## Requirements

The script must run on Linux as `root`. It requires:

- Bash
- Git, when using automatic repository updates
- `iptables`
- `ip6tables`
- Standard utilities including `mktemp`, `sort`, `tr`, and `wc`

On Debian or Ubuntu, install the main dependencies with:

```bash
sudo apt-get update
sudo apt-get install git iptables util-linux
```

On Alpine Linux, install them with:

```bash
sudo apk add bash git iptables util-linux
```

## Deploy With Git

Clone the repository once on the Linux host. For example, install it under
`/opt/ip-rule-sets`:

```bash
sudo git clone https://github.com/catio-network/ip-rule-sets.git /opt/ip-rule-sets
```

Install the rules from the cloned repository:

```bash
sudo /opt/ip-rule-sets/scripts/iptables-ip-blocking.sh install
```

To update the repository manually and then import the latest lists and script:

```bash
sudo git -C /opt/ip-rule-sets pull --ff-only
sudo /opt/ip-rule-sets/scripts/iptables-ip-blocking.sh install
```

`--ff-only` prevents Git from creating an automatic merge commit if the local
checkout has diverged from its remote branch. The import command should run only
when the pull succeeds:

```bash
sudo /bin/bash -c 'git -C /opt/ip-rule-sets pull --ff-only && /opt/ip-rule-sets/scripts/iptables-ip-blocking.sh install'
```

## Configure Artifact Files

Edit the `RULE_FILES` array near the beginning of
`scripts/iptables-ip-blocking.sh`:

```bash
RULE_FILES=(
  "artifacts/colocrossing.txt"
)
```

Add additional artifact files as separate entries:

```bash
RULE_FILES=(
  "artifacts/colocrossing.txt"
  "artifacts/alibaba.txt"
)
```

Relative paths are resolved from the repository root, regardless of the current
working directory. Absolute paths are also supported. Each file must contain one
IPv4 or IPv6 CIDR prefix per line. Blank lines and lines beginning with `#` are
ignored. Exact duplicate prefixes are removed before rules are installed.

## Install Rules

Run the script from the repository root:

```bash
sudo ./scripts/iptables-ip-blocking.sh install
```

Installation performs these steps:

1. Reads every configured artifact file.
2. Validates and separates IPv4 and IPv6 prefixes.
3. Removes existing `IP_BLOCK_V4` and `IP_BLOCK_V6` jumps and chains.
4. Creates new managed chains and adds a `DROP` rule for each prefix.
5. Inserts one jump at the beginning of each applicable `INPUT` chain.

File loading and validation happen before existing rules are removed. If rule
installation fails, the script removes any partially installed managed chains.

Running `install` repeatedly is supported. Each execution cleans the previous
managed rules before loading the current lists.

## Verify Rules

Display the IPv4 chain and its counters:

```bash
sudo iptables -t filter -L IP_BLOCK_V4 -n -v
```

Display the IPv6 chain and its counters:

```bash
sudo ip6tables -t filter -L IP_BLOCK_V6 -n -v
```

Verify the jumps from `INPUT`:

```bash
sudo iptables -t filter -C INPUT -j IP_BLOCK_V4
sudo ip6tables -t filter -C INPUT -j IP_BLOCK_V6
```

Each verification command exits successfully when the jump exists.

## Uninstall Rules

Remove all managed rules with:

```bash
sudo ./scripts/iptables-ip-blocking.sh uninstall
```

Uninstall removes every jump from `INPUT` to the managed chain, flushes the
chain, and deletes it. It applies this process to both IPv4 and IPv6. Running
uninstall when the chains do not exist is safe.

The script does not modify unrelated firewall rules.

## Run From Cron

Firewall configuration may be lost when a host reboots. A root crontab can
restore the rules after startup and periodically refresh the Git-managed lists.

Open the root crontab:

```bash
sudo crontab -e
```

Add entries similar to the following, replacing `/opt/ip-rule-sets` with the
absolute path to the Git checkout on the Linux host:

```cron
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

@reboot /bin/sleep 30 && /usr/bin/flock -n /run/ip-block-rules.lock /bin/bash -c 'git -C /opt/ip-rule-sets pull --ff-only && exec /opt/ip-rule-sets/scripts/iptables-ip-blocking.sh install' >>/var/log/ip-block-rules.log 2>&1
0 */6 * * * /usr/bin/flock -n /run/ip-block-rules.lock /bin/bash -c 'git -C /opt/ip-rule-sets pull --ff-only && exec /opt/ip-rule-sets/scripts/iptables-ip-blocking.sh install' >>/var/log/ip-block-rules.log 2>&1
```

The `@reboot` entry waits 30 seconds for networking to become available before
updating the checkout and loading the artifact files. The second entry pulls the
latest repository state and refreshes the rules every six hours. The `&&`
operator prevents installation if `git pull` fails. `flock` prevents two Git or
firewall operations from running simultaneously.

Clone the repository as `root` when using the root crontab, as shown above. This
avoids Git rejecting the checkout because it is owned by another user.

Use the actual location of `flock` on the host. It can be checked with:

```bash
command -v flock
```

Review the installed root crontab with:

```bash
sudo crontab -l
```

Review script output with:

```bash
sudo tail -f /var/log/ip-block-rules.log
```

To stop automatic installation permanently, remove both cron entries first and
then uninstall the rules:

```bash
sudo /opt/ip-rule-sets/scripts/iptables-ip-blocking.sh uninstall
```

If a cron entry remains enabled, its next execution will install the chains
again.

## Operational Notes

- The install command uses files in the local checkout. Only `git clone` and
  `git pull` require network access.
- The rules block packets based on source address in `INPUT`. They do not block
  forwarded traffic or locally generated outbound traffic.
- The rules are not saved through an iptables persistence service. Use the
  `@reboot` cron entry or another service manager to restore them after reboot.
- Large lists create one iptables rule per prefix and may take time to load.
- Prefixes should come from trusted sources. Installing a broad or incorrect
  prefix can block legitimate access, including administrative access.

## Troubleshooting

If the script reports that it must run as root, invoke it with `sudo` or run it
from the root crontab.

If a required command is missing, install the package that provides the command
and run the script again.

If `git pull` fails, verify access to GitHub and inspect the checkout:

```bash
sudo git -C /opt/ip-rule-sets status
sudo git -C /opt/ip-rule-sets pull --ff-only
```

If prefix validation fails, inspect the reported line. Every non-comment line
must contain only one IPv4 or IPv6 CIDR prefix. If a configured file cannot be
read, verify its path and permissions in the checkout.
