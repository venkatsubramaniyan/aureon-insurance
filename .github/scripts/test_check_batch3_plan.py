import copy
import json
from pathlib import Path
import subprocess
import sys
import unittest


CHECKER = Path(__file__).with_name("check-batch3-plan.py")
SUBSCRIPTION = "azurerm_eventgrid_system_topic_event_subscription.insurance_document_created"
ACCOUNT = "azurerm_cognitive_account.openai[0]"
ROOT = "/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/rg-test"
EVENT_GRID = {
    "id": f"{ROOT}/providers/Microsoft.EventGrid/systemTopics/topic/eventSubscriptions/documents",
    "name": "documents",
    "system_topic": "topic",
    "resource_group_name": "rg-test",
    "service_bus_queue_endpoint_id": f"{ROOT}/providers/Microsoft.ServiceBus/namespaces/bus/queues/ingestion",
    "event_delivery_schema": "EventGridSchema",
    "included_event_types": ["Microsoft.Storage.BlobCreated"],
    "subject_filter": [{
        "subject_begins_with": "/blobServices/default/containers/insurance-documents/blobs/",
        "subject_ends_with": "",
        "case_sensitive": True,
    }],
    "dead_letter_identity": [{"type": "SystemAssigned", "user_assigned_identity": ""}],
    "storage_blob_dead_letter_destination": [{
        "storage_account_id": f"{ROOT}/providers/Microsoft.Storage/storageAccounts/testaccount",
        "storage_blob_container_name": "eventgrid-deadletters",
    }],
    "retry_policy": [{"max_delivery_attempts": 30, "event_time_to_live": 1440}],
    "labels": None,
    "advanced_filtering_on_arrays_enabled": None,
}


def resource(address, actions, before, after):
    resource_type, name = address.split(".", 1)
    return {
        "address": address,
        "mode": "managed",
        "type": resource_type,
        "name": name.partition("[")[0],
        "provider_name": "registry.terraform.io/hashicorp/azurerm",
        "change": {
            "actions": actions,
            "before": before,
            "after": after,
            "after_unknown": {"id": True} if actions == ["create"] else {},
            "before_sensitive": {},
            "after_sensitive": {},
        },
    }


class Batch3PlanTests(unittest.TestCase):
    def setUp(self):
        self.before = copy.deepcopy(EVENT_GRID)
        self.refreshed = dict(copy.deepcopy(EVENT_GRID), labels=[], advanced_filtering_on_arrays_enabled=False)
        self.drift = resource(SUBSCRIPTION, ["update"], self.before, self.refreshed)
        self.plan = {
            "format_version": "1.2",
            "terraform_version": "1.16.5",
            "complete": True,
            "errored": False,
            "applyable": True,
            "resource_changes": [
                resource(ACCOUNT, ["create"], None, {"name": "aoai-test"}),
                resource(SUBSCRIPTION, ["no-op"], self.refreshed, self.refreshed),
            ],
            "resource_drift": [self.drift],
        }

    def check(self, allowed, message):
        result = subprocess.run(
            [sys.executable, str(CHECKER)],
            input=json.dumps(self.plan),
            text=True,
            capture_output=True,
        )
        self.assertEqual(result.returncode, 0 if allowed else 1, result.stdout + result.stderr)
        self.assertIn(message, result.stdout + result.stderr)
        return result.stdout + result.stderr

    def test_normalization_with_matching_no_op_warns(self):
        self.check(True, "refresh-only normalization")

    def test_no_op_does_not_excuse_changed_delivery_settings(self):
        for field, value in {
            "service_bus_queue_endpoint_id": f"{ROOT}/providers/Microsoft.ServiceBus/namespaces/bus/queues/other",
            "subject_filter": [],
            "dead_letter_identity": [],
            "storage_blob_dead_letter_destination": [],
            "retry_policy": [{"max_delivery_attempts": 1, "event_time_to_live": 30}],
            "labels": ["new-label"],
            "advanced_filtering_on_arrays_enabled": True,
        }.items():
            with self.subTest(field=field):
                self.refreshed[field] = value
                output = self.check(False, field)
                self.assertNotIn("/subscriptions/", output)
                self.refreshed[field] = copy.deepcopy(EVENT_GRID[field])

    def test_unrelated_resource_with_no_op_still_blocks(self):
        address = "azurerm_storage_account.app_storage"
        self.drift["address"] = address
        self.plan["resource_changes"][1]["address"] = address
        self.check(False, address)

    def test_external_delete_still_blocks(self):
        self.drift["change"].update(actions=["delete"], after=None)
        self.check(False, "delete")

    def test_normalization_requires_matching_no_op(self):
        self.plan["resource_changes"].pop()
        self.check(False, "drift")

    def test_normalization_cannot_use_an_unrelated_no_op_snapshot(self):
        self.plan["resource_changes"][1]["change"].update(before=self.before, after=self.before)
        self.check(False, "drift")

    def test_planned_update_delete_replacement_and_import_still_block(self):
        for actions, importing in (
            (["update"], None),
            (["delete"], None),
            (["delete", "create"], None),
            (["create", "delete"], None),
            (["no-op"], {"id": "test-existing-resource"}),
        ):
            with self.subTest(actions=actions, importing=importing):
                change = self.plan["resource_changes"][1]["change"]
                change.update(actions=actions, importing=importing)
                self.check(False, "disallowed change")

    def test_create_allowlist_is_unchanged(self):
        self.plan["resource_changes"][0]["address"] = "azurerm_search_service.documents[1]"
        self.check(False, "azurerm_search_service.documents[1]: disallowed change")


if __name__ == "__main__":
    unittest.main()
