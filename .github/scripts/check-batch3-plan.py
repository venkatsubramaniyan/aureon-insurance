import json
import sys


EVENT_GRID_SUBSCRIPTION = (
    "azurerm_eventgrid_system_topic_event_subscription.insurance_document_created"
)

ALLOWED_CREATES = {
    "azurerm_cognitive_account.openai[0]",
    'azurerm_cognitive_deployment.models["chat"]',
    'azurerm_cognitive_deployment.models["embeddings"]',
    "azurerm_search_service.documents[0]",
}
for endpoint, zone in {
    "openai": "privatelink.openai.azure.com",
    "search": "privatelink.search.windows.net",
}.items():
    ALLOWED_CREATES.update(
        {
            f'azurerm_private_endpoint.workloads["{endpoint}"]',
            f'azurerm_private_dns_zone.workloads["{zone}"]',
            f'azurerm_private_dns_zone_virtual_network_link.workloads["{zone}"]',
        }
    )


def is_event_grid_normalization(resource, planned, changed_fields):
    change = resource["change"]
    before, after = change.get("before"), change.get("after")
    if (
        resource["address"] != EVENT_GRID_SUBSCRIPTION
        or change["actions"] != ["update"]
        or resource.get("previous_address")
        or resource.get("deposed")
        or change.get("importing")
        or planned is None
        or planned["actions"] != ["no-op"]
        or planned.get("before") != after
        or planned.get("after") != after
        or not changed_fields
        or before.keys() != after.keys()
    ):
        return False

    # AzureRM represents these unset Event Grid options as empty labels or false.
    defaults = {"labels": [], "advanced_filtering_on_arrays_enabled": False}
    return all(
        field in defaults
        and (before[field], after[field]) in ((None, defaults[field]), (defaults[field], None))
        for field in changed_fields
    )


def main():
    plan = json.load(sys.stdin)
    if plan.get("complete") is not True or plan.get("errored") is not False:
        sys.exit("Batch 3 blocked: Terraform did not produce a complete, error-free plan.")

    rejected = []
    planned_changes = {}
    for resource in plan.get("resource_changes", []):
        address = resource["address"]
        change = resource["change"]
        actions = change["actions"]
        if (
            resource.get("previous_address")
            or resource.get("deposed")
            or change.get("importing")
            or not (
                actions == ["no-op"]
                or (resource["mode"] == "data" and actions == ["read"])
                or (
                    resource["mode"] == "managed"
                    and actions == ["create"]
                    and address in ALLOWED_CREATES
                )
            )
        ):
            rejected.append(f"{address}: disallowed change ({', '.join(actions)})")
        elif resource["mode"] == "managed":
            planned_changes[address] = change

    for resource in plan.get("resource_drift", []):
        address = resource["address"]
        if resource["mode"] != "managed" or address in ALLOWED_CREATES:
            continue
        change = resource["change"]
        before, after = change.get("before"), change.get("after")
        changed_fields = []
        if isinstance(before, dict) and isinstance(after, dict):
            changed_fields = sorted(
                field
                for field in before.keys() | after.keys()
                if field not in before or field not in after or before[field] != after[field]
            )
        if is_event_grid_normalization(resource, planned_changes.get(address), changed_fields):
            print(f"Warning: {address}: refresh-only normalization ({', '.join(changed_fields)})")
        else:
            details = ", ".join([*change["actions"], *changed_fields])
            rejected.append(f"{address}: drift outside Batch 3 ({details})")

    for name, change in plan.get("output_changes", {}).items():
        if change["actions"] != ["no-op"]:
            rejected.append(f"output.{name}: {', '.join(change['actions'])}")

    if rejected:
        sys.exit("Batch 3 blocked: unexpected plan changes:\n" + "\n".join(rejected))
    print("Batch 3 safety check passed: only permitted creates or no changes.")


if __name__ == "__main__":
    main()
