# Jenkins MongoDB lab

Separate companion to the MariaDB lab: Jenkins → Terraform → three AWS EC2 nodes → Ansible → MongoDB 8.0 Community replica set `rs0`.

- Exactly three voting, data-bearing members (`mongo1`, `mongo2`, `mongo3`), one elected primary and two secondaries. No arbiter, mongos, MaxScale or sharding.
- Ubuntu 24.04, t3.medium (4 GiB), 40 GiB encrypted gp3 root/data disk per node. WiredTiger cache 1 GiB, oplog 1 GiB. Three nodes incur AWS charges; no free-tier assumption.
- Independent resource names, SSH key and S3 state key. Reuses the existing VPC/subnet/Jenkins security group as read-only references.
- SCRAM admin authentication and shared internal key. MongoDB listens only on loopback and private IPv4. Security group permits 27017 only among members and from the existing AWS Jenkins SG.
- Installs the current patch in the 8.0 series on new machines. Existing installations use `state: present`; this is not an automated upgrade workflow.
- Uses simple gp3 storage rather than copying the MariaDB project's ZFS migrations, monitoring servers or public dashboards. All three members share one subnet/AZ: this is a lab, not production DR. TLS is not configured; keep database access on trusted private networks or SSH tunnels.

## 1. Prepare Jenkins

Create a **separate repository and Pipeline job**, e.g. `mongodb-lab`. Point Pipeline from SCM at that repository's `Jenkinsfile`. Do not put this into the MariaDB repository/workspace. Use a dedicated job; disableConcurrentBuilds only locks this job, not other jobs sharing the state.

Agent needs AWS CLI, Terraform >=1.10 and <2, Python 3, OpenSSH, an AWS identity, and Ansible 2.19. The AWS identity must be available to Terraform and AWS CLI (instance profile or your existing assumed-role setup). A home runner does not inherit an EC2 instance role automatically.

On the Jenkins machine (Debian/Ubuntu example):

```bash
sudo apt-get update
sudo apt-get install -y python3-venv openssh-client
sudo python3 -m venv /opt/jenkins-mongodb-venv
sudo /opt/jenkins-mongodb-venv/bin/pip install -r requirements.txt
sudo install -d -o jenkins -g jenkins -m 700 /var/lib/jenkins/.ssh /var/lib/jenkins/mongodb-lab
sudo -u jenkins ssh-keygen -t ed25519 -N '' -f /var/lib/jenkins/.ssh/mongodb-lab
sudo -u jenkins cp terraform/backend.hcl.example /var/lib/jenkins/mongodb-lab/backend.hcl
sudo -u jenkins cp terraform/terraform.tfvars.example /var/lib/jenkins/mongodb-lab/terraform.tfvars
```

Edit `/var/lib/jenkins/mongodb-lab/terraform.tfvars`: supply your home public IPv4 without `/32`. Check the VPC/subnet/SG defaults in `variables.tf` are still correct. Update the public IPv4 if your ISP changes it.

Edit `backend.hcl`: the example reuses your existing S3 bucket but **must keep the separate key** `mongodb-lab/terraform.tfstate`. Never use the MariaDB state key. The bucket must already exist. Enable bucket versioning. Jenkins needs S3 Get/Put on this state key and Get/Put/Delete on its `.tflock` key, plus ListBucket. Any bucket KMS policy must also allow the runner.

AWS permissions must allow describing EC2/VPC/AMIs, creating/deleting/tagging EC2 instances, security groups and key pairs, ingress/egress updates and volume creation/deletion as used by EC2 root disks. If your existing role restricts resource names or Project tags to MariaDB, extend it to `mongodb-jenkins-lab`. No Route53 permission is needed.

The existing subnet needs an internet gateway route and working DNS/outbound HTTPS for Ubuntu and MongoDB package repositories. Public IPv4 addresses are assigned for home SSH and package downloads. MongoDB is never opened to the public internet. SSH host keys use trust-on-first-use in a per-build known_hosts file.

## 2. Add Jenkins credentials

In the job's credentials scope:

| ID | Kind | Value |
| --- | --- | --- |
| `mongodb-lab-admin` | Username with password | E.g. username `labadmin`; unique password of at least 16 characters |
| `mongodb-lab-keyfile` | Secret text | One persistent single-line base64 key |

Generate the internal key once:

```bash
openssl rand -base64 512 | tr -d '\n'
```

Keep these values unchanged across builds and replacement nodes. Password rotation and key rotation need a separate deliberate procedure; changing credentials here does not rotate the cluster password. Secrets are passed as environment variables, Ansible secret tasks use `no_log`, and neither secret is put in Terraform or archived artifacts. Trusted Jenkins administrators and root can access process environments.

## 3. Build

1. Run `ACTION=PLAN`. Review the archived `plan.txt`: expect three EC2 instances plus a new MongoDB security group/key pair, and no MariaDB changes.
2. Run `ACTION=APPLY`, `SSH_MODE=public` for home Jenkins (`private` only if the runner can route to the AWS private addresses).
3. Review and approve the saved infrastructure plan. Ansible waits for cloud-init, installs MongoDB, writes private hostname mappings on every node, enables keyfile authentication, and initiates `rs0` once.
4. Pipeline creates the first administrator using MongoDB's localhost exception, then requires exactly one primary/two secondaries, writes a probe with `w:3`, and reads the current build's probe locally from every member. The small `lab_health.replication_probe` document is overwritten each build.

All members have equal election priority. `mongo1` is only the initial bootstrap host; it is not a permanently pinned primary. Subsequent runs discover the elected primary. Reapplying does not reset replica configuration, delete data or reset passwords. Config changes restart members serially; expect brief election/write interruptions when the primary restarts.

For a failed bootstrap, fix the reported issue and rerun APPLY with the same credentials. If two nodes are unavailable the set cannot elect a primary; this project deliberately stops rather than forcing an unsafe recovery. Never destroy/replace two live members together if data matters. A single fresh replacement retains its stable replica hostname, receives updated `/etc/hosts` mappings and automatically initial-syncs from the surviving majority. Replacement testing in AWS has not been performed for this deliverable. Keep changes to addresses/configuration outside active application traffic in this lab.

## 4. Connect and inspect

Use the public IP from the `nodes.json` Jenkins artifact:

```bash
ssh -i /var/lib/jenkins/.ssh/mongodb-lab ubuntu@NODE_PUBLIC_IP
mongosh --host 127.0.0.1 --username labadmin --authenticationDatabase admin --password
```

The password flag prompts securely. Inside mongosh:

```javascript
db.hello()
rs.status()
rs.conf()
```

Repeat on another node or connect to the current primary when a command requires it. To practise failover, stop `mongod` on the current primary, check that one of the other two is elected, then restart it. Keep at least two voting members available.

For Compass from home, create a tunnel:

```bash
ssh -i /var/lib/jenkins/.ssh/mongodb-lab -N -L 27018:127.0.0.1:27017 ubuntu@NODE_PUBLIC_IP
```

Connect to `mongodb://localhost:27018/?directConnection=true&authSource=admin` and enter credentials separately. This is a direct connection to one node, so it does not follow failover. Replica-aware apps inside the VPC must resolve all three `mongoN.mongodb.lab.internal` names to their private addresses and be allowed by the security group. These are managed `/etc/hosts` entries on the members, not real Route53 records. No home Jenkins hosts updater or sudoers change is required.

## 5. Tear down

Run `ACTION=DESTROY`, review the plan and approve. This deletes only resources in the MongoDB state, including all three root/data volumes. Export anything you want to keep first. S3 state bucket/key history, Jenkins credentials, and the local SSH private key are not deleted.

## Local checks and limitations

```bash
python3 -m unittest discover -s tests -v
node tests/test_cluster.js # optional Node.js, only for helper unit checks
/opt/jenkins-mongodb-venv/bin/ansible-playbook -i localhost, ansible/install.yml --syntax-check
/opt/jenkins-mongodb-venv/bin/ansible-playbook -i localhost, ansible/configure.yml --syntax-check
terraform -chdir=terraform fmt -check
```

Terraform formatting, HCL parsing, both Ansible syntax checks, five inventory tests and eight MongoDB helper checks passed during creation. Full Terraform provider validation was attempted but blocked by a checksum/loading failure of the downloaded AWS provider in this environment. Run `terraform validate` and PLAN on your Jenkins runner before provisioning. A real Terraform plan requires initializing your backend. No AWS resources were deployed while creating this project. Review the plan before provisioning. Commit the generated `.terraform.lock.hcl` after the first successful init for repeatable provider resolution; Jenkins also archives it.

References: [MongoDB 8.0 on Ubuntu](https://www.mongodb.com/docs/v8.0/tutorial/install-mongodb-on-ubuntu/), [replica sets](https://www.mongodb.com/docs/v8.0/tutorial/deploy-replica-set/), [localhost exception](https://www.mongodb.com/docs/v8.0/core/localhost-exception/).
