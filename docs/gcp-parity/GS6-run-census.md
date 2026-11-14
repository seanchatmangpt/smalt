# GS6 Run and Logging Census

Standing: PARTIAL

Surface census for lane GS6 (Cloud Run Admin v2, Cloud Logging v2).

| Surface | Method | Engine fn | Status |
| :--- | :--- | :--- | :--- |
| run services.create | POST .../services?serviceId | CloudRun.create_service/4 | engine |
| run services.get/list | GET | get_service/3, list_services/2 | engine |
| run services.patch (replace) | PATCH/PUT | replace_service/4 | engine |
| run services.delete | DELETE | delete_service/3 | engine |
| run operations.get | GET | get_operation/1 | engine |
| run revisions get/list | GET | get_revision/4, list_revisions/3 | engine |
| run ingress enum | field | valid_ingress/0 | engine |
| run invoker IAM get/set | :getIamPolicy/:setIamPolicy | get_iam_policy/3, set_iam_policy/4 | engine |
| logging entries.write | POST /v2/entries:write | Logging.write_entries/1 | engine |
| logging entries.list | POST /v2/entries:list | Logging.list_entries/1 | engine |
| run jobs, executions, traffic split, IAM conditions | - | - | MISSING |
| logging sinks, metrics, buckets, filter beyond subset | - | - | MISSING |

Wire routers are not authored (shared files); see GS6.md wiring.
