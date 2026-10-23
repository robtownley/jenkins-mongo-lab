"""Build a secret-free inventory from Terraform's nodes output."""
import argparse
import ipaddress
import json
from pathlib import Path


def build(nodes, mode, key):
    if set(nodes) != {"mongo1", "mongo2", "mongo3"}:
        raise ValueError("Expected exactly mongo1, mongo2 and mongo3")
    hosts = {}
    for name, node in sorted(nodes.items()):
        for field in ("private_ip", "public_ip"):
            ipaddress.IPv4Address(node[field])
        hostname = name + ".mongodb.lab.internal"
        if node["hostname"] != hostname:
            raise ValueError("Unexpected MongoDB hostname")
        hosts[name] = {
            "ansible_host": node[mode + "_ip"],
            "private_ip": node["private_ip"], "mongo_hostname": hostname,
        }
    return {"all": {"vars": {
        "ansible_user": "ubuntu", "ansible_ssh_private_key_file": key,
        "ansible_ssh_common_args": "-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=./known_hosts",
    }, "children": {"mongodb": {"hosts": hosts}}}}


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", choices=["public", "private"], default="public")
    parser.add_argument("--key", default="/var/lib/jenkins/.ssh/mongodb-lab")
    args = parser.parse_args()
    result = build(json.loads(Path("nodes.json").read_text()), args.mode, args.key)
    Path("inventory.json").write_text(json.dumps(result, indent=2) + "\n")
