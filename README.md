# Jenkins MongoDB lab — Rocky Linux 9

Jenkins → Terraform → three EC2 nodes → Ansible → MongoDB 8.0 Community replica set `rs0`.

This version replaces the original Ubuntu deployment with official Rocky Linux 9 Base x86_64 images. It uses Rocky's stock 5.14 kernel, MongoDB's EL9 RPM repository and official SELinux policy. It performs no GRUB changes, kernel downgrades or kernel pinning. A preflight check requires Rocky 9 / x86_64 / kernel 5.14 before installing MongoDB. Normal Rocky kernel updates remain possible; this pipeline does not install OS updates or reboot servers.

## Existing Ubuntu lab: read this first

Changing the AMI replaces all three EC2 instances and **deletes their root/data volumes**. This migration is for the unfinished disposable lab in this conversation, not a populated cluster. Export any data you need before approving the plan. No SSH access to the broken Ubuntu instance is required to replace it through EC2.

1. Copy this project's files over your local `jenkins-mongo-lab` Git checkout, including `.gitignore`. Commit and push to your existing branch.
2. Keep the existing Jenkins job, AWS authentication, SSH key, credentials, S3 bucket and `mongodb-lab/terraform.tfstate` key. Do not reset state or manually terminate nodes.
3. On the home Jenkins runner, use its existing AWS credentials to list official Rocky 9 images in the lab region:

```bash
sudo -u jenkins -H aws ec2 describe-images \
  --region eu-west-2 \
  --owners 792107900819 \
  --filters \
    'Name=name,Values=Rocky-9-EC2-Base-9.*x86_64*' \
    'Name=architecture,Values=x86_64' \
    'Name=virtualization-type,Values=hvm' \
    'Name=root-device-type,Values=ebs' \
    'Name=state,Values=available' \
  --query 'sort_by(Images, &CreationDate)[-1].[ImageId,Name,CreationDate]' \
  --output table
```

4. Edit the persistent variables file:

```bash
sudo nano /var/lib/jenkins/mongodb-lab/terraform.tfvars
```

Keep its existing home public IPv4 and other settings; add exactly one line using the actual AMI ID returned:

```hcl
rocky_ami_id = "ami-YOUR_ACTUAL_ROCKY9_IMAGE_ID"
```

No AMI ID is invented or hardcoded in this project. IDs are region-specific. Terraform checks ownership, Rocky 9 Base name, architecture, virtualization and availability. If no image is returned, stop and check the official Rocky images for your region.

5. Run Jenkins `ACTION=PLAN`, then `ACTION=APPLY`, `SSH_MODE=public`. Review the fresh plan: expect replacement of `aws_instance.node["mongo1"]`, `["mongo2"]`, `["mongo3"]`. This release removes `ignore_changes = [ami]` so the OS migration is actually applied. Future AMI changes are explicit through the pinned `rocky_ami_id` variable; the pipeline does not select newer images automatically.
6. Approve the plan. Fresh machines receive new public/private IPs; Terraform output and inventory provide the new values. Ansible logs in as `rocky`, installs MongoDB, configures every member and verifies replicated writes. Old Ubuntu GRUB changes disappear with the replaced root volume.

## Cluster

- Three voting, data-bearing nodes: `mongo1`, `mongo2`, `mongo3`. One elected primary, two secondaries; no arbiter, sharding or proxy.
- Default `t3.medium`, 4 GiB RAM, 40 GiB encrypted gp3 root/data volume each. WiredTiger cache 1 GiB, oplog 1 GiB. AWS charges apply to instances, disks and public IPv4 addresses.
- Three nodes in the same subnet/AZ: lab topology, not multi-AZ DR.
- Stable member names `mongoN.mongodb.lab.internal` resolved through managed `/etc/hosts` entries on all nodes. Public Route53 A records `mongo1.roblabb.com`, `mongo2.roblabb.com` and `mongo3.roblabb.com` provide SSH names. No Jenkins hosts updater is needed.
- Port 27017 bound only to loopback and private IPv4; security group permits it among members and from the existing AWS Jenkins SG. If firewalld is running, the playbook enables 27017/tcp there; AWS security group rules continue to restrict sources.
- SCRAM admin credentials and persistent internal shared key. RPM user/group `mongod`; data `/var/lib/mongo`; log `/var/log/mongodb/mongod.log`; key `/var/lib/mongo/internal-auth/keyfile`, mode 0400 inside a 0700 directory.
- Official MongoDB SELinux policy, pinned to commit `18181652362a46fd4511a56f20c4055712deb252`; key uses the data path's SELinux type. Existing SELinux enforcement is preserved. No permissive mode or disablement.
- MongoDB RPM installs the available 8.0 patch on fresh nodes; `state: present` preserves existing installations. OS and MongoDB version upgrades are separate operations.
- TLS is not configured. Use trusted private networks or SSH tunnels. This version does not include the MariaDB project's ZFS migrations or monitoring/dashboard servers.

## Fresh Jenkins setup

Use a separate Git repository and Pipeline job. Home Jenkins itself can remain Ubuntu/Debian; only EC2 database nodes use Rocky.

Runner needs AWS CLI, Terraform >=1.10 and <2, Git, OpenSSH, Python 3 and Ansible 2.19. Reuse your existing AWS authentication. The pipeline does not contain an assume-role stage; AWS CLI and Terraform must already see the intended AWS identity.

```bash
sudo apt-get update
sudo apt-get install -y python3-venv git openssh-client openssl
sudo python3 -m venv /opt/jenkins-mongodb-venv
sudo /opt/jenkins-mongodb-venv/bin/pip install 'ansible-core>=2.19,<2.20'
sudo install -d -o jenkins -g jenkins -m 700 /var/lib/jenkins/.ssh /var/lib/jenkins/mongodb-lab
sudo -u jenkins bash <<'KEY'
set -eu
if [ ! -f /var/lib/jenkins/.ssh/mongodb-lab ]; then
  ssh-keygen -t ed25519 -N '' -f /var/lib/jenkins/.ssh/mongodb-lab
fi
KEY
```

For a new setup only, copy `terraform/backend.hcl.example` and `terraform/terraform.tfvars.example` into `/var/lib/jenkins/mongodb-lab/` as `backend.hcl` and `terraform.tfvars`. Fill in your real home IPv4 and the Rocky AMI ID using the lookup above. Reuse the existing VPC/subnet/Jenkins SG defaults only after checking them. Subnet needs working outbound HTTPS/DNS and an internet gateway route for public IPv4 connectivity, including access to Rocky mirrors, repo.mongodb.org, pgp.mongodb.com and GitHub for the official SELinux policy.

State example uses your existing S3 bucket with **separate key** `mongodb-lab/terraform.tfstate`. Never use the MariaDB state key. Bucket must already exist; versioning is recommended. Permissions: bucket ListBucket, state GetObject/PutObject, lock `.tflock` GetObject/PutObject/DeleteObject, and any required KMS grants. EC2 permissions must cover creating/describing/tagging/deleting instances, root volumes, key pairs and security groups; ingress/egress Authorize/Revoke and DeleteSecurityGroup must cover the `mongodb-jenkins-lab` Project tag. Keep the IAM additions made while testing the Ubuntu version.

Verify runner access:

```bash
sudo -u jenkins -H aws sts get-caller-identity
```

## Jenkins credentials and job

| ID | Kind | Value |
| --- | --- | --- |
| `mongodb-lab-admin` | Username with password | E.g. `labadmin`; password at least 16 characters |
| `mongodb-lab-keyfile` | Secret text | Persistent single-line base64 key |

Generate the key once using `openssl rand -base64 512 | tr -d '\n'`. Keep both credentials unchanged across builds/replacements. Password/key rotation is not automated. Secret tasks use `no_log`; secrets are passed as process environment variables, not CLI arguments or Terraform values. Root and trusted Jenkins administrators can access process environments.

Create Pipeline job `mongodb-lab`, definition **Pipeline script from SCM**, Git URL `https://github.com/robtownley/jenkins-mongo-lab.git`, branch `*/main`, Script Path `Jenkinsfile`. Use your GitHub credential for a private repository. Run PLAN first; APPLY uses public SSH for home Jenkins, private only for a runner with VPC routing. Use one job per state: disableConcurrentBuilds does not lock other jobs.

## Behaviour and verification

The pipeline waits for cloud-init, checks OS/kernel compatibility, installs packages and SELinux policy, and updates all member host mappings. Configuration restarts proceed serially. On a wholly fresh set it initiates `rs0` once, discovers the primary and creates the initial administrator through the localhost exception. On subsequent runs it uses the existing configuration/credentials; it does not reset passwords or force-reconfigure the set.

Verification requires one primary/two secondaries, a build-token probe written with `w:3`, and that token read locally from all three nodes. A small `lab_health.replication_probe` document is overwritten per build. Failed startup waits show service journal diagnostics.

A single replacement uses its stable name and initial-syncs from the surviving majority. Two unavailable members prevent election; the pipeline stops rather than force-recovering. Never replace multiple members of a populated set together. Config restarts may cause brief write/election interruptions. Runtime bootstrap, SELinux, initial sync and AWS replacement have not been tested on real EC2 nodes for this deliverable.

## Public Route53 records

Terraform looks up the existing public `roblabb.com` hosted zone and manages exactly three A records, each pointing to its corresponding node's public IPv4, with TTL 60. These records are separate from the MariaDB state and names. The hosted zone itself is never created or deleted. On replacement/IP changes, APPLY updates the records; DESTROY deletes these three records. The private replication hostnames remain unchanged.

Before the first DNS APPLY, add `route53-mongodb-policy.json` as an additional inline policy named `MongoDBLabRoute53` on IAM role `JenkinsMariaDBLabPolicy`. Preserve all existing policies. DNS mutation permission is restricted to the three MongoDB A-record names. Alternatively, if the MariaDB Route53 policy is already attached, add those three names to its allowed `route53:ChangeResourceRecordSetsNormalizedRecordNames` list.

Commit/push this update, then run PLAN. With the existing Rocky instance settings unchanged, expect only three new DNS records and an output change; no instance replacement. Then run APPLY. If a record already exists outside this Terraform state, import it deliberately rather than overwriting it (`allow_overwrite = false`). Example after backend initialization, substituting the actual hosted zone ID:

```bash
terraform -chdir=terraform import 'aws_route53_record.lab["mongo1"]' ZONEID_mongo1.roblabb.com_A
```

This uses public IPs like the MariaDB project's records. It does not open MongoDB to the internet; use SSH/tunnels. For example:

```bash
ssh -i /var/lib/jenkins/.ssh/mongodb-lab rocky@mongo1.roblabb.com
```

## Access

Use the new public IP from the archived `nodes.json`:

```bash
ssh -i /var/lib/jenkins/.ssh/mongodb-lab rocky@NODE_PUBLIC_IP
mongosh --host 127.0.0.1 --username labadmin --authenticationDatabase admin --password
```

`--password` prompts. In mongosh, use `db.hello()`, `rs.status()` and `rs.conf()`.

For Compass from home:

```bash
ssh -i /var/lib/jenkins/.ssh/mongodb-lab -N -L 27018:127.0.0.1:27017 rocky@NODE_PUBLIC_IP
```

Connect to `mongodb://localhost:27018/?directConnection=true&authSource=admin`, entering credentials separately. This is a single-node connection, not automatic failover. Replica-aware VPC clients must resolve all three private member names and have security group access.

## Destroy and checks

DESTROY deletes only resources in the MongoDB state, including all data volumes. S3 bucket/history, local SSH key and Jenkins credentials remain. Save data before approving destruction.

```bash
python3 -m unittest discover -s tests -v
node tests/test_cluster.js # optional Node.js for helper checks
/opt/jenkins-mongodb-venv/bin/ansible-playbook -i localhost, ansible/install.yml --syntax-check
/opt/jenkins-mongodb-venv/bin/ansible-playbook -i localhost, ansible/configure.yml --syntax-check
terraform -chdir=terraform fmt -check
```

Terraform formatting/HCL parsing, Ansible syntax and helper/inventory checks are local validation only. AWS provider validation in the original environment failed to load the downloaded provider. No AWS resources were deployed while editing this project. Run init/validate/PLAN on your runner. Commit `.terraform.lock.hcl` after successful init; Jenkins also archives it.

References: [MongoDB EL9 installation/support](https://www.mongodb.com/docs/v8.0/tutorial/install-mongodb-on-red-hat/), [official SELinux policy](https://github.com/mongodb/mongodb-selinux), [Rocky AMI publisher](https://forums.rockylinux.org/t/aws-inf2-instance-types-for-rocky-some-image-clarification/11098), [AWS SSH usernames](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/connection-prereqs-general.html).
