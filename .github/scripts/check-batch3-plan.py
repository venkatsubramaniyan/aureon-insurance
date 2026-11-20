import json
import sys


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


def main():
    plan = json.load(sys.stdin)
    if plan.get("complete") is not True or plan.get("errored") is not False:
        sys.exit("Batch 3 blocked: Terraform did not produce a complete, error-free plan.")

    rejected = []
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

    for resource in plan.get("resource_drift", []):
        if resource["mode"] == "managed" and resource["address"] not in ALLOWED_CREATES:
            rejected.append(f"{resource['address']}: drift outside Batch 3")

    for name, change in plan.get("output_changes", {}).items():
        if change["actions"] != ["no-op"]:
            rejected.append(f"output.{name}: {', '.join(change['actions'])}")

    if rejected:
        sys.exit("Batch 3 blocked: unexpected plan changes:\n" + "\n".join(rejected))
    print("Batch 3 safety check passed: only permitted creates or no changes.")


if __name__ == "__main__":
    main()
