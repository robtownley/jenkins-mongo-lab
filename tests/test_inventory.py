import importlib.util
from pathlib import Path
import unittest
spec = importlib.util.spec_from_file_location('inventory', Path(__file__).resolve().parents[1] / 'scripts/make_inventory.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
class InventoryTest(unittest.TestCase):
    def nodes(self):
        return {f'mongo{i}': {'private_ip': f'10.0.0.{i}', 'public_ip': f'203.0.113.{i}',
                'hostname': f'mongo{i}.mongodb.lab.internal'} for i in range(1,4)}
    def test_home_runner_uses_public_ssh_private_replication(self):
        inv = module.build(self.nodes(), 'public', '/key')
        node = inv['all']['children']['mongodb']['hosts']['mongo1']
        self.assertEqual(node['ansible_host'], '203.0.113.1')
        self.assertEqual(node['private_ip'], '10.0.0.1')
    def test_aws_runner_uses_private(self):
        inv = module.build(self.nodes(), 'private', '/key')
        self.assertEqual(inv['all']['children']['mongodb']['hosts']['mongo3']['ansible_host'], '10.0.0.3')
    def test_missing_member_rejected(self):
        nodes = self.nodes(); del nodes['mongo3']
        with self.assertRaises(ValueError): module.build(nodes, 'public', '/key')
    def test_bad_address_rejected(self):
        nodes = self.nodes(); nodes['mongo1']['private_ip'] = '127.0.0.1; shell'
        with self.assertRaises(ValueError): module.build(nodes, 'public', '/key')
    def test_unexpected_hostname_rejected(self):
        nodes = self.nodes(); nodes['mongo1']['hostname'] = 'wrong'
        with self.assertRaises(ValueError): module.build(nodes, 'public', '/key')
if __name__ == '__main__': unittest.main()
