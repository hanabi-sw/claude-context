# IAM policy restriction — READ-ONLY audit rulebook

SWS machine only (needs the AWS profile). Read when the task asks what an AWS role or user is
allowed to do, what it has actually used, which roles are over-privileged, or whether a policy can
be detached safely. Verified against AWS `546532984119` from the low-priv role on 2026-10-27.

**Read-only from Claude:** `iam get-*/list-*/generate-service-last-accessed-details/simulate-*`,
`cloudtrail lookup-events`, `accessanalyzer list-*/get-*/validate-policy`, Athena `SELECT`.
Every `attach|detach|put|delete|create|update` is handed to the user as a command. Campaign state
(tasks, proposed policies, progress) lives in `~/code/ai-plans/aws-policy-cleanup/`, never here.
Whole-account "what is unused" listings come from the billed analyzer: `access-analyzer-unused.md`.

Account shape (2026-10-27): 215 roles, 24 users, 43 instance profiles, 113 customer-managed
policies. Managed-policies-per-role quota is raised to 20 (AWS default 10), so attach-then-detach
swaps fit; check `aws service-quotas get-service-quota --service-code iam --quota-code L-0DA4ABF3
--region us-east-1` before adding a tenth policy elsewhere.

## Decision order — cheapest signal first

| Question | Recipe | Window |
|---|---|---|
| Is the role used at all? | `aws iam get-role --role-name R --query Role.RoleLastUsed` | 400 d |
| Is the user / key used at all? | credential report (below) | all time |
| Which *services* did it use? | Access Advisor, service level (below) | 400 d |
| Which *actions* in those services? | Access Advisor `ACTION_LEVEL` — actions only for s3, ec2, iam, lambda, ecr, logs, ssm, dynamodb, sqs… (others stay service level) | 400 d |
| Exact calls, errors, callers? | `cloudtrail lookup-events` (below) | 90 d |
| Older than 90 d, per-bucket S3 usage? | Athena over the trail bucket (below) | trail retention |
| Does action X resolve to Allow for role R? | `aws iam simulate-principal-policy --policy-source-arn arn:aws:iam::546532984119:role/R --action-names s3:ListAllMyBuckets --query 'EvaluationResults[].[EvalActionName,EvalDecision]'` | now |

### Access Advisor (per principal)

```bash
J=$(aws iam generate-service-last-accessed-details --arn arn:aws:iam::546532984119:role/R \
      --granularity ACTION_LEVEL --query JobId --output text); sleep 8
aws iam get-service-last-accessed-details --job-id $J --query JobStatus --output text   # COMPLETED
# used services, last use, number of tracked actions
aws iam get-service-last-accessed-details --job-id $J \
  --query 'ServicesLastAccessed[?TotalAuthenticatedEntities>`0`].[ServiceNamespace,LastAuthenticated,length(TrackedActionsLastAccessed||`[]`)]' --output text
# granted but never used in 400 d — the over-privilege list
aws iam get-service-last-accessed-details --job-id $J \
  --query 'ServicesLastAccessed[?TotalAuthenticatedEntities==`0`].ServiceNamespace' --output text | tr '\t' '\n'
# actions actually used inside one service
aws iam get-service-last-accessed-details --job-id $J \
  --query 'ServicesLastAccessed[?ServiceNamespace==`s3`].TrackedActionsLastAccessed[].[ActionName,LastAccessedTime]' --output text
```

Job IDs expire within minutes; fetch right after generating. Data is eventually consistent (hours).

### Credential report (users, keys, passwords, MFA)

```bash
aws iam get-credential-report --query Content --output text | base64 -d > "$S/cred.csv"
# users with an active key unused > 90 d  (col 9 = key1 active, col 11 = key1 last used)
awk -F, 'NR>1 && $9=="true" && ($11=="N/A" || $11 < strftime("%Y-%m-%d", systime()-90*86400)) {print $1, $11}' "$S/cred.csv"
```
`generate-credential-report` is needed only if the report is older than 4 h; it is a write-ish
call that is still safe from the low-priv role but ask first.

### CloudTrail, last 90 days (`eu-central-1` only — the trail is single-region)

`Username` in `lookup-events` is the **role session name, not the role name**: for an EC2 instance
role it is the instance ID, for a human it is their session name. Filtering by the role name
returns only the `AssumeRole` events. Recipe for an instance role:

```bash
I=$(aws ec2 describe-instances --region eu-central-1 --filters \
      Name=iam-instance-profile.arn,Values=arn:aws:iam::546532984119:instance-profile/R \
      Name=instance-state-name,Values=running --query 'Reservations[].Instances[].InstanceId' --output text)
for i in $I; do aws cloudtrail lookup-events --region eu-central-1 \
  --lookup-attribute AttributeKey=Username,AttributeValue=$i \
  --start-time "$(date -u -d '24 hours ago' +%FT%TZ)" --max-results 50 --output json; done \
| jq -r '.Events[].CloudTrailEvent|fromjson|"\(.userIdentity.sessionContext.sessionIssuer.userName) \(.eventSource) \(.eventName) \(.errorCode // "ok")"' \
| sort | uniq -c | sort -rn
```
Lines ending in anything but `ok` (`AccessDenied`, `Client.UnauthorizedOperation`) are the
missing-permission signal used after a detach. 50 events per page; add `--next-token` loops or
use Athena for volume. S3 object-level data events are logged for `starweb-longterm-backups` only,
so per-bucket S3 usage of other buckets is **not** in the trail.

### Athena over the trail bucket (older than 90 d) — **Not checked**

Trail `frankfurt-cloudtrail` writes to
`s3://frankfurt-cloudtrail-bucket/AWSLogs/546532984119/CloudTrail/eu-central-1/YYYY/MM/DD/`.
Workgroup `primary` has no result location configured, so the first run needs the user to set one
(`--result-configuration OutputLocation=s3://<bucket>/athena/`). Use the standard CloudTrail table
DDL from the AWS docs with partition projection on `eu-central-1` and the date; then:

```sql
SELECT useridentity.sessioncontext.sessionissuer.username AS role, eventsource, eventname,
       errorcode, count(*) AS n
FROM cloudtrail_logs WHERE date BETWEEN '2026/07/01' AND '2026/10/27'
  AND useridentity.sessioncontext.sessionissuer.username = 'R'
GROUP BY 1,2,3,4 ORDER BY n DESC;
```

## Enumerate everything in one call

One dump replaces hundreds of `list-attached-role-policies` loops (52 MB, ~1 min):

```bash
S=/tmp/claude-1000/-home-user-code/*/scratchpad   # session scratchpad
aws iam get-account-authorization-details --output json > "$S/auth.json"
A="$S/auth.json"
# roles carrying FullAccess / Administrator / PowerUser managed policies
jq -r '.RoleDetailList[] | select(any(.AttachedManagedPolicies[].PolicyName; test("FullAccess|AdministratorAccess|PowerUser")))
  | "\(.RoleName)\t\([.AttachedManagedPolicies[].PolicyName|select(test("FullAccess|AdministratorAccess|PowerUser"))]|join(","))"' $A
# inline policies with Action "*" or Resource "*"
jq -r '.RoleDetailList[] | .RoleName as $r | .RolePolicyList[]? | .PolicyDocument.Statement
  | (if type=="array" then . else [.] end)[] | select(.Effect=="Allow")
  | select((.Action|tostring)=="\"*\"" or ((.Resource|tostring)|test("\"\\*\""))) | $r' $A | sort -u
# who carries a given managed policy (replaces list-entities-for-policy)
jq -r '.RoleDetailList[] | select(any(.AttachedManagedPolicies[].PolicyArn; endswith("AmazonEC2RoleforSSM"))) | .RoleName' $A
# trust policies that allow another account or "*"
jq -r '.RoleDetailList[] | .RoleName as $r | .AssumeRolePolicyDocument.Statement[] | select(.Effect=="Allow")
  | .Principal | (.AWS? // empty) | (if type=="array" then . else [.] end)[] | select(test("546532984119")|not) | "\($r)\t\(.)"' $A
# attached customer policies by age (2015-vintage ones are the usual suspects)
jq -r '.Policies[] | select(.AttachmentCount>0) | "\(.UpdateDate[:10])\t\(.AttachmentCount)\t\(.PolicyName)"' $A | sort
# roles by last use, oldest first
jq -r '.RoleDetailList[] | "\(.RoleLastUsed.LastUsedDate // "never")\t\(.RoleName)"' $A | sort
# instance profile → role
aws iam list-instance-profiles --query 'InstanceProfiles[].[InstanceProfileName,Roles[0].RoleName]' --output text
```

Gotcha: inside a `while read` loop add `</dev/null` to every `aws` call or it eats the loop's stdin.

## Find over-privileged roles — ranked checklist

1. **Dead roles**: `RoleLastUsed` older than 365 d, or never, and no instance profile / launch
   config / launch template referencing them →
   `aws autoscaling describe-auto-scaling-groups --query 'AutoScalingGroups[?DesiredCapacity==`0`].[AutoScalingGroupName,LaunchConfigurationName]'`
   and `aws autoscaling describe-launch-configurations --query 'LaunchConfigurations[].[LaunchConfigurationName,IamInstanceProfile]'`.
   Candidates for `delete-*` tasks, not for scoping.
2. **FullAccess / `*` grants on live roles** (jq above) ranked by exposure: instance role on
   internet-facing EC2/Beanstalk > cross-account trust > user with a long-lived key.
3. **Granted-minus-used**: Access Advisor's unused-services list per role from step 2; the wider
   the gap, the higher the score.
4. **Deprecated AWS-managed policies**: `aws iam get-policy --policy-arn <arn> --query Policy.Description`
   says "will soon be deprecated" (e.g. `AmazonEC2RoleforSSM`).
5. **Stale customer policies** by `UpdateDate` (several date from 2015–2018).
6. Whole-account unused-role / unused-permission listing in one shot: `access-analyzer-unused.md` (billed).

## IAM Access Analyzer — external access (free)

Finds resources shared outside the account: S3 buckets, role trust policies, KMS keys, Lambda,
SQS, SNS, Secrets Manager, EBS/RDS snapshots, ECR, EFS. No analyzer exists today (**Verified**).

**Create — user-run, needs write rights.** Console: IAM → Access analyzer → Analyzer settings →
Create analyzer → External access analysis, zone of trust *Current account*, region `eu-central-1`,
name `sws-external`. CLI:

```bash
aws accessanalyzer create-analyzer --region eu-central-1 --analyzer-name sws-external --type ACCOUNT
```
Creates the service-linked role `AWSServiceRoleForAccessAnalyzer`; first scan in ~30 min, then on
every policy change and daily. One analyzer per region with resources; `eu-central-1` is enough.

**Read findings — Claude, read-only (Not checked until the analyzer exists):**

```bash
ARN=$(aws accessanalyzer list-analyzers --region eu-central-1 --query 'analyzers[?type==`ACCOUNT`].arn' --output text)
aws accessanalyzer list-findings-v2 --region eu-central-1 --analyzer-arn $ARN \
  --filter '{"status":{"eq":["ACTIVE"]}}' --query 'findings[].[resourceType,resource,findingType,createdAt]' --output table
aws accessanalyzer get-finding-v2 --region eu-central-1 --analyzer-arn $ARN --id <finding-id>
```

Triage: intended sharing (backup-manager, CircleCI, DoiT, the k8s-dev account `964680329936`,
public static buckets) → the user archives it with a reason; an archive rule only for a repeating,
documented pattern. Everything else → one `fix-<resource>` task. Archiving (`update-findings`) is
a write; never from Claude. Findings also flow into Security Hub (enabled, no standards) and
EventBridge (`Access Analyzer Finding`) if alerting is wanted.

Free companions that need no analyzer: `aws accessanalyzer validate-policy --policy-type
IDENTITY_POLICY --policy-document file://p.json` (lint before proposing a policy; empty `findings`
= clean, **Verified**) and policy generation from CloudTrail (`start-policy-generation`, user-run,
needs an analyzer and a service role that reads the trail bucket; output is a draft to review).

## Not available here (Verified 2026-10-27)

AWS Config records 0 IAM resources (recorder `default` exists, so `select-resource-config` over
IAM is empty). Security Hub: hub enabled, no standards, no findings. No IAM Identity Center.
Grafana has no IAM data. Do not look there for IAM usage.

## Proving a removal is safe — checklist

1. Diff the grants: old policy minus new policy, statement by statement
   (`get-policy-version --version-id $(get-policy … DefaultVersionId)` for both).
2. For each extra grant: *covered elsewhere* (another attached policy, cite it), *not used*
   (Access Advisor / CloudTrail, cite the window), or *inferred dead* (say why). Unresolved rows
   block the change.
3. Resource scoping comes from the app's own config, not guesses: Beanstalk
   `describe-configuration-settings … aws:elasticbeanstalk:application:environment` env vars,
   `grep` of the repo for hard-coded ARNs.
4. Order: unused/zero-capacity roles → staging → production, one business day between steps.
5. Attach new, then detach old (quota 20 leaves room). Policy changes reach running instances in
   seconds; no redeploy.
6. Watch the CloudTrail `errorCode` recipe above for the role for one business day. Rollback is
   re-attaching the old policy.
7. Done when Access Advisor shows no unused service on the role after 30 days.

Reference incident: `~/code/ai-plans/ssm-policy-cleanup/README.md` (2026-10-23, deprecated
`AmazonEC2RoleforSSM` on five roles; the covered-elsewhere table there is the model).

## From findings to tasks

Tasks are bite-sized: one role × one policy × one environment, audit separate from apply. The
template and backlog live in `~/code/ai-plans/aws-policy-cleanup/` (`TEMPLATE.md`, `in-progress/`,
`done/`). Task kinds: `audit-<role>` (evidence only), `scope-<role>-<policy>` (one replacement
policy JSON, validated and simulated), `apply-<role>-<policy>-<env>` (attach/detach on one
environment), `delete-<role>`, `fix-<role>-<thing>`. Every task carries a done-criterion and a
rollback line. Replace, do not trim in place: a new `<role>-least-priv-<date>` policy next to the
old one, soak, detach, delete the old one after 30 days.

Reference incidents: 2026-10-23 SSM policy audit (`ssm-policy-cleanup`); 2026-10-22 ECS cluster
lockdown (`ecs-cluster-lockdown`), both under `~/code/ai-plans/`.
