# IAM Access Analyzer, unused access — the billed whole-account listing

SWS machine only, AWS `546532984119`. Read when the task wants a list of unused roles, access
keys, passwords or permissions across the whole account instead of auditing one role by hand.
Verified against the AWS pricing page and docs on 2026-10-27; no analyzer exists in the account
yet, so every query below is **Not checked** until one does.

**Read-only from Claude:** `accessanalyzer list-*` / `get-*` only. Creating, archiving, deleting
is user-run. Per-role manual recipes and the task workflow are in `policy-restriction.md`;
campaign state lives in `~/code/ai-plans/aws-policy-cleanup/`.

## What it is, when to use it

A continuous scan of every role and user that emits one finding per unused thing: `UnusedIAMRole`,
`UnusedIAMUserAccessKey`, `UnusedIAMUserPassword`, `UnusedPermission` (services, and actions for
the services Access Advisor tracks). It reads the same last-accessed data Access Advisor shows,
which AWS keeps for 400 days whether or not an analyzer exists — so an analyzer created today
reports on last week and the last year immediately. Use it at the start of a cleanup campaign:
one listing replaces 215 Access Advisor jobs. For a single role, use Access Advisor instead.

## Cost

| Item | Value |
|---|---|
| Price | $0.20 per role or user analyzed, per analyzer |
| Billed | at creation, then on the 1st of every month; no proration documented (**Not checked**) |
| Here | 215 roles + 24 users ≈ $48 per charge; service-linked roles count |
| Regions | findings are region-independent; one analyzer per account, a second region doubles the bill |
| Delete + recreate | triggers the creation charge again |

A week and a month cost the same; create it right after the 1st and delete it before the next 1st
to pay once.

## Activate — user-run, write, not from the low-priv role

Console: IAM → Access analyzer → Analyzer settings → Create analyzer → *Unused access analysis*,
tracking period 90 days, region `eu-central-1`, name `sws-unused`. CLI:

```bash
aws accessanalyzer create-analyzer --region eu-central-1 \
  --analyzer-name sws-unused --type ACCOUNT_UNUSED_ACCESS \
  --configuration '{"unusedAccess":{"unusedAccessAge":90}}'
```

Threshold 1–365 days; 90 matches the CloudTrail lookup window. Break-glass roles can be excluded
by tag or ARN with an `analysisRule` in the configuration. Write the creation date into
`~/code/ai-plans/aws-policy-cleanup/README.md` so the shutdown date is known.

## Timeline and caveats

- First findings within ~24 h, refreshed daily. Last-accessed data lags by hours.
- A principal younger than the threshold gets no finding at all.
- Action-level detail only for the services Access Advisor tracks (s3, ec2, iam, lambda, ecr,
  logs, ssm, dynamodb, sqs, …); other services are reported as whole-service unused.
- A role used only by a yearly or quarterly job looks unused at 90 days. Cross-check every
  `delete-*` candidate with `RoleLastUsed` (400 d) and CloudTrail/Athena before deleting.
- It judges identity policies only; access granted through resource policies in other accounts or
  through the role's trust policy is not a finding here (that is the external-access analyzer).
- Unused-permission recommendations are a trimmed copy of the current policy, not a least-privilege
  design; resource ARNs still need scoping by hand.

## Query — Claude, read-only

```bash
ARN=$(aws accessanalyzer list-analyzers --region eu-central-1 \
        --query 'analyzers[?type==`ACCOUNT_UNUSED_ACCESS`].arn' --output text)
# counts per finding type
aws accessanalyzer list-findings-v2 --region eu-central-1 --analyzer-arn $ARN \
  --filter '{"status":{"eq":["ACTIVE"]}}' --query 'findings[].findingType' --output text | tr '\t' '\n' | sort | uniq -c
# candidate rows for the campaign README: type, principal, last used / number of unused services
aws accessanalyzer list-findings-v2 --region eu-central-1 --analyzer-arn $ARN \
  --filter '{"status":{"eq":["ACTIVE"]}}' --output json \
| jq -r '.findings[] | "\(.findingType)\t\(.resource|split("/")[-1])\t\(.updatedAt[:10])"' | sort
# one finding in full (unusedPermissionDetails lists the unused services/actions)
aws accessanalyzer get-finding-v2 --region eu-central-1 --analyzer-arn $ARN --id <finding-id>
# the trimmed-policy recommendation for an UnusedPermission finding (user generates, Claude reads)
#   user:   aws accessanalyzer generate-finding-recommendation --analyzer-arn $ARN --id <finding-id>
aws accessanalyzer get-finding-recommendation --region eu-central-1 --analyzer-arn $ARN --id <finding-id>
```

Keep the last full listing as `~/code/ai-plans/aws-policy-cleanup/unused-findings-<date>.json`
so the state survives deleting the analyzer.

## From findings to tasks

| Finding | Task in `in-progress/` |
|---|---|
| `UnusedIAMRole` | `delete-<role>` after the 400 d / CloudTrail cross-check |
| `UnusedPermission` | `scope-<role>-<policy>` with the recommendation JSON as the first draft |
| `UnusedIAMUserAccessKey` / `UnusedIAMUserPassword` | `fix-<user>-key` / `fix-<user>-password` |

Intended exceptions (break-glass, yearly jobs) are archived by the user with a reason; no archive
rule unless the pattern repeats.

## When to shut it down

It is a campaign tool, not a standing control. Delete it when the backlog from one listing is
worked off and a fresh listing is clean, and before the next 1st of the month:

```bash
aws accessanalyzer delete-analyzer --region eu-central-1 --analyzer-name sws-unused   # user-run
```

Re-create it for the next campaign; findings rebuild from the 400-day data within a day.

## Reference

- <https://aws.amazon.com/iam/access-analyzer/pricing/>
- <https://docs.aws.amazon.com/IAM/latest/UserGuide/access-analyzer-create-unused.html>
- <https://docs.aws.amazon.com/IAM/latest/UserGuide/access-analyzer-findings.html>
- <https://aws.amazon.com/blogs/security/monitoring-and-optimizing-the-cost-of-the-unused-access-analyzer-in-iam-access-analyzer/>
