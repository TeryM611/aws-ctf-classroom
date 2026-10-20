# AWS CTF Classroom Kit

Shell scripts that give every student in a hands-on security course **their own
Kali Linux VM in AWS**, plus an optional **shared target server** running your
intentionally vulnerable challenge apps — all hosted in *your* AWS account.

Students need no AWS account, no credits and no local VM. Each student gets one
SSH key file, and that's it.

Originally built for, and in use in, an undergraduate CTF-style ethical hacking
course with 17 students.

```
                       your AWS account (one region, default VPC)
 ┌──────────────────────────────────────────────────────────────────────┐
 │                                                                      │
 │   Kali VM: student001 ─┐                                             │
 │   Kali VM: student002 ─┼──── HTTP to app ports ───►  Target server   │
 │   Kali VM: ...        ─┘    (allow-listed by IP)    Docker Compose:  │
 │     ▲  own key, own SG, Elastic IP,                  one container   │
 │     │  no IAM role                                   per challenge   │
 └─────┼────────────────────────────────────────────────────────────────┘
       │ ssh -p 48022 -i student001.pem kali@<ip>
   student laptop (anywhere)
```

## What you get

| Folder | Piece | Use it for |
|---|---|---|
| `kali_fleet/` | One Kali VM per student | Every week. Tools pre-installed, runs on a daily schedule |
| `target/` | One shared server running your challenge apps | Weeks with web challenges to attack |
| `kali_fleet/push_files.sh` | Copy a folder onto every VM | Weeks with file-based labs (crypto, forensics, binaries) |

You can use the Kali fleet on its own. The target server is optional.

## Security model

- **Each student's SSH key is the access control.** The official Kali AMI
  only allows public-key SSH (password and keyboard-interactive login are
  disabled), so SSH can be open to the internet and students connect from
  anywhere. sshd also moves to port 48022, which cuts down scanner noise; the
  key is still what keeps people out.
- **One security group and one key pair per student**, so you can cut off
  a single student without touching anyone else.
- **No IAM role on any instance.** A student with root on their VM, or an
  attacker who gets a shell through a challenge on the target, finds no AWS
  credentials. IMDSv2 is required on every instance.
- **The target's app ports are never open to the internet.** Only IPs in
  `target/roster.csv` are allowed, and `sync_roster.sh` makes the security
  group match the file exactly, so removing a row removes access.
- **The scheduler's IAM role** can only start and stop instances tagged with
  this kit's project tag.
- **Students never get your files by accident.** `push_files.sh` copies only
  the folder you name. Keep answer keys and solvers out of it.

## Prerequisites

1. **AWS CLI v2**, configured for the account that will host everything
   (`aws configure`, or AWS CloudShell, where it's preinstalled). The scripts
   work on macOS's bash 3.2, Linux, and CloudShell.
2. **`python3`** on the machine running the scripts (used for JSON and CSV
   handling).
3. **A default VPC** in your region, with auto-assign public IP on its
   subnets. That's how new accounts are set up.
4. **Subscribe to the official Kali AMI (free, one time per account).** Open
   the [Kali Linux AWS Marketplace page](https://aws.amazon.com/marketplace/pp?sku=7lgvy7mt78lgoi4lant0znp5h),
   choose *Continue to Subscribe* → *Accept Terms*. `provision_students.sh`
   checks this before launching anything.
5. **Raise two default quotas before provisioning a class.** New accounts
   allow only **5 Elastic IPs** per region (you need one per student), and
   often **32 vCPUs** of standard instances (a `t3.small` uses 2, so ~16
   students):
   ```bash
   # Elastic IPs (set to class size + a few)
   aws service-quotas request-service-quota-increase --service-code ec2 \
     --quota-code L-0263D0A3 --desired-value 30
   # Running On-Demand Standard instances, in vCPUs (2 per t3.small)
   aws service-quotas request-service-quota-increase --service-code ec2 \
     --quota-code L-1216C47A --desired-value 64
   ```
   Approval is often automatic, within minutes. **Even after the quota shows
   the new value, EC2 can keep enforcing the old limit for a minute or two.**
   Wait until launching actually works before assuming it's done.

## Quick start

### 1. Configure
Edit `config.env`. At minimum, check `PROJECT` (a prefix for every resource;
use a different one per class sharing an account), `REGION` and `TIMEZONE`.
Trim `KALI_PACKAGES` to the tools your course actually uses.

### 2. Provision the Kali fleet
```bash
cd kali_fleet
cp students.csv.example students.csv     # one student ID per line
./provision_students.sh                  # a few min per student; safe to re-run
./setup_daily_schedule.sh                # VMs run START_HOUR..STOP_HOUR daily
./generate_distribution_checklist.sh     # writes distribution_checklist.md
```
The first boot installs the toolset, so give VMs 10–15 minutes before students
log in. Provision the day before class, not ten minutes before.

### 3. Send each student their key, privately
`distribution_checklist.md` has one entry per student: the `.pem` to attach
and a ready-to-paste message with their own `ssh` command. Send each one as a
**private** message through your LMS (Canvas Inbox, Moodle messages, ...). The
key works like a password: never put keys in a shared folder or announcement.

### 4. (Optional) Deploy the target server
```bash
cd target
# put your challenge apps in apps/, one folder each (see "Adding challenges")
./deploy_target.sh            # prints the URLs; you're allow-listed automatically
./check_status.sh             # wait for every port to answer
./link_kali_to_target.sh      # adds every Kali VM's IP to roster.csv
./sync_roster.sh              # applies roster.csv to the security group
```

### 5. (Optional) Push file-based labs
```bash
cd kali_fleet
./push_files.sh ../../week09/lab week09     # -> ~/week09/ on every VM
EXCLUDES="README.md" ./push_files.sh ../../week09/lab week09   # keep instructions in your LMS instead
```
Re-runs never overwrite a file that already exists on a VM, so students' notes
survive. The flip side is that a corrected file won't replace the old copy.

## Day to day

| Situation | Run |
|---|---|
| Add students | add rows to `students.csv` → `provision_students.sh` → `setup_daily_schedule.sh` → `generate_distribution_checklist.sh` (then `link_kali_to_target.sh` + `sync_roster.sh` if using the target) |
| New tool needed mid-term | add it to `KALI_PACKAGES` → `kali_fleet/upgrade_toolset.sh` |
| Your own IP changed | `target/update_my_ip.sh` |
| Is the target up? | `target/check_status.sh` |
| A student's VM is broken after a restart | Terminate that one instance, then re-run `provision_students.sh`. It rebuilds just that VM with the same key. Usually faster than debugging it. |

Students' VMs are powered off outside the daily window on purpose. Tell
students the hours up front, or you'll get "it's down" messages at 12:05 AM.

## Adding challenges to the target

1. Create `target/apps/<your_challenge>/app.py` defining a Flask object named
   `app`. Put one-time setup (create a database, write a flag file) in a
   function named `setup()`, `init_db()` or `write_flag()`, and the container
   entrypoint calls it. Add a `requirements.txt` if you need more than Flask.
2. Add a service to `target/deploy/docker-compose.yml` (copy the example
   block; change the name, `APP_PATH` and port).
3. Add the port to `APP_PORTS` in `config.env`.

`apps/example_challenge/` is a tiny working example (robots.txt recon).

**Before deploying:** anything a student can read on the target or their VM,
they will read. Don't ship flags in plaintext in source files they can reach.

## Tear down

```bash
target/teardown_target.sh          # the target (asks before deleting SG/key/bucket)
kali_fleet/teardown_students.sh    # every Kali VM + Elastic IPs (asks before the rest)
```
Teardown finds resources by the `PROJECT` tag and name prefix, so it only ever
touches what this kit created.

## Cost

A rough estimate for **us-east-1** on-demand pricing at the time of writing.
Check current prices with the [AWS Pricing Calculator](https://calculator.aws/).

| Item | Rate | Per student, per 30 days |
|---|---|---|
| `t3.small` Kali VM, 15 h/day | ~$0.021/h | ~$9.40 |
| Public IPv4 (Elastic IP), billed 24/7 | ~$0.005/h | ~$3.60 |
| EBS root volume (~25 GB) | ~$0.08/GB-month | ~$2.00 |
| **Total** | | **~$15** |

The target adds ~$12/month (`t3.micro` plus its public IP, running 24/7). **Stopped VMs don't
bill for compute, but Elastic IPs and disks keep billing until teardown.**

## Things that went wrong, so you don't have to find them

- **A `t3.micro` target froze on the first deploy.** Docker Compose builds all
  images in parallel and ran the 1 GB of RAM out, hard enough that EC2's own
  health check failed. `deploy_target.sh` builds one image at a time.
- **Docker's `internal: true` network blocks published ports**, not just
  outbound traffic, so it can't be used to isolate a command-injection
  challenge. Isolation is done at the EC2 level instead (no IAM role; IMDSv2
  with hop limit 1).
- **The base Kali AMI ships nearly empty** — not even `file`, `strings` or
  `gdb`. Everything comes from `KALI_PACKAGES`.
- **pip installs CLI tools to `~/.local/bin`, which isn't on PATH**, and the
  AMI's default shell is zsh. Both `.zshrc` and `.bashrc` get fixed.
- **Spreadsheet apps break CSVs quietly.** Excel/Numbers add a byte-order mark
  and quotes, and a last line with no newline gets skipped by a plain
  `while read`. All three are handled.
- **`ssh` inside a `while read` loop eats the loop's input**, so the script
  stops after the first student with no error. The scripts use `ssh -n` or
  feed ssh its own input.
- **An idle-CPU auto-stop alarm was tried and removed.** It put VMs to sleep
  in the middle of office hours. A fixed daily window is predictable, and
  that was worth more than the savings.

## Layout

```
config.env                 all settings
lib.sh                     shared helpers (sourced by every script)
kali_fleet/
  provision_students.sh    create or repair one VM per student (idempotent)
  setup_daily_schedule.sh  daily start/stop via EventBridge Scheduler
  generate_distribution_checklist.sh
  push_files.sh            copy a lab folder to every VM
  upgrade_toolset.sh       install new packages on running VMs
  teardown_students.sh
  students.csv.example
target/
  deploy_target.sh         one EC2 instance + Docker Compose
  sync_roster.sh           make the security group match roster.csv
  link_kali_to_target.sh   add the Kali fleet's IPs to roster.csv
  update_my_ip.sh  check_status.sh  teardown_target.sh
  roster.csv.example
  deploy/                  Dockerfile, docker-compose.yml, run.py
  apps/example_challenge/
```

`.gitignore` excludes every key, roster and state file. If you fork this,
**never commit `*.pem`, `students.csv` or `kali_roster_output.csv`** — they
identify your students and grant access to their VMs.

## License

MIT — see [LICENSE](LICENSE).
