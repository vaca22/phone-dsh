#!/usr/bin/env python3
# SPDX-License-Identifier: MIT

import copy
import sys
import unittest
from pathlib import Path

TOOLS_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(TOOLS_DIR))

import native_mcp_check as checker
from spec_golden import SpecError, load_json

ROOT = Path(__file__).resolve().parents[3]


class NativeMCPCheckTests(unittest.TestCase):
    def fixture(self, name):
        return load_json(ROOT / "spec/v1/golden/native-mcp" / name)

    def test_all_production_vectors_pass(self):
        self.assertEqual(checker.validate(ROOT), 6)

    def test_volume_policy_requires_confirmation_and_negative_examples(self):
        vector = self.fixture("iphone-agent-volume-policy.json")
        vector["instructions"] = vector["instructions"].replace("fresh screenshot", "screenshot")
        with self.assertRaises(SpecError):
            checker.iphone_agent_volume_policy(vector)
        vector = self.fixture("iphone-agent-volume-policy.json")
        vector["completion_guidance"] = "Report the result."
        with self.assertRaises(SpecError):
            checker.iphone_agent_volume_policy(vector)
        vector = self.fixture("iphone-agent-volume-policy.json")
        vector["invalid_arguments"][-1]["task_utf8_bytes"] = 8192
        with self.assertRaises(SpecError):
            checker.iphone_agent_volume_policy(vector)

    def test_ble_rejects_android_tool_and_response_id(self):
        vector = self.fixture("ble-devices.json")
        vector["request"]["params"]["name"] = "android_status"
        with self.assertRaises(SpecError):
            checker.ble_vector(vector)
        vector = self.fixture("ble-devices.json")
        vector["response"]["id"] = 99
        with self.assertRaises(SpecError):
            checker.ble_vector(vector)

    def test_http_rejects_wrong_endpoint_and_response_id(self):
        vector = self.fixture("tap.json")
        vector["path"] = "/v1/http"
        with self.assertRaises(SpecError):
            checker.http_vector(vector)
        vector = self.fixture("connect.json")
        vector["response"]["id"] = 99
        with self.assertRaises(SpecError):
            checker.http_vector(vector)

    def test_transfer_rejects_worker_write_and_wrong_bounds(self):
        vector = self.fixture("file-transfer.json")
        vector["native_disk_transfer"]["worker_vfs_write"] = True
        with self.assertRaises(SpecError):
            checker.transfer_vector(vector)
        vector = self.fixture("file-transfer.json")
        vector["native_disk_transfer"]["deadline_ms"] = 1
        with self.assertRaises(SpecError):
            checker.transfer_vector(vector)

    def test_package_rejects_non_object_arguments(self):
        vector = copy.deepcopy(self.fixture("package-management.json"))
        vector[0]["request"]["params"]["arguments"] = []
        with self.assertRaises(SpecError):
            checker.package_vector(vector)


if __name__ == "__main__":
    unittest.main()
